import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'dart:io' show Platform, File;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_http_client.dart';
import '../models/artist.dart';
import '../models/album.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import 'app_logger.dart';

class ApiService {
  // The app ships with NO server baked in. On first launch the connect screen
  // asks for one; the answer lives in SharedPreferences so it survives app
  // updates. Desktop builds also try loopback, for a backend on the same box.
  static const String _localHost = 'http://127.0.0.1:5002';
  static const String defaultLanHost = '';
  static const String defaultWanHost = '';

  static String _lanHost = defaultLanHost;
  static String _wanHost = defaultWanHost;

  /// Configured server addresses ('' = not set).
  static String get lanHost => _lanHost;
  static String get wanHost => _wanHost;

  /// Has the user pointed the app at a server yet? Until this is true the
  /// auth gate shows the connect screen instead of login.
  static bool get isConfigured => _lanHost.isNotEmpty || _wanHost.isNotEmpty;

  /// Bumped whenever the server addresses change so the auth gate can
  /// re-evaluate (connect screen → login, or a fresh setup-status check).
  static final ValueNotifier<int> serverConfigChanged = ValueNotifier<int>(0);

  /// Best host to start from before network detection has run.
  static String get _startingHost =>
      _wanHost.isNotEmpty ? _wanHost : (_lanHost.isNotEmpty ? _lanHost : _localHost);

  static const String _prefsLanHostKey = 'server_lan_host';
  static const String _prefsWanHostKey = 'server_wan_host';

  /// Load server-address overrides from SharedPreferences. Called once at
  /// startup, before the first detectNetwork(); missing/empty prefs leave
  /// the build-time defaults in place.
  static Future<void> loadServerConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lan = prefs.getString(_prefsLanHostKey);
      final wan = prefs.getString(_prefsWanHostKey);
      if (lan != null && lan.isNotEmpty) _lanHost = lan;
      if (wan != null && wan.isNotEmpty) _wanHost = wan;
    } catch (_) {
      // Prefs unavailable → nothing configured; the connect screen will ask.
    }
    baseHost = _startingHost;
    baseUrl = '$baseHost/api';
  }

  /// Persist new server addresses and apply them immediately. An empty
  /// string clears that address.
  static Future<void> saveServerConfig({
    required String lanHost,
    required String wanHost,
  }) async {
    final lan = normalizeHost(lanHost);
    final wan = normalizeHost(wanHost);
    final prefs = await SharedPreferences.getInstance();
    if (lan.isEmpty) {
      await prefs.remove(_prefsLanHostKey);
    } else {
      await prefs.setString(_prefsLanHostKey, lan);
    }
    if (wan.isEmpty) {
      await prefs.remove(_prefsWanHostKey);
    } else {
      await prefs.setString(_prefsWanHostKey, wan);
    }
    _lanHost = lan;
    _wanHost = wan;
    baseHost = _startingHost;
    baseUrl = '$baseHost/api';
    // Force an immediate re-probe with the new hosts.
    _lastLanCheck = null;
    _isOnLan = false;
    _lanMissStreak = 0;
    await detectNetwork();
    serverConfigChanged.value++;
  }

  /// Can we reach a NASRadio backend at [host]? Hits the trivial /api/ping
  /// with a short timeout; never throws. Used by the connect screen's Test.
  static Future<bool> probeHost(String host) async {
    final h = normalizeHost(host);
    if (h.isEmpty) return false;
    try {
      final response = await appHttpClient
          .get(Uri.parse('$h/api/ping'))
          .timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) return false;
      final body = json.decode(response.body);
      return body is Map && body['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Server-provided, non-secret client settings (GET /api/client-config),
  /// refreshed after every login. Empty app ID = use the default receiver.
  static String castReceiverAppId = '';
  static String publicBaseUrl = '';

  static Future<void> loadClientConfig() async {
    try {
      final response = await appHttpClient
          .get(Uri.parse('$baseUrl/client-config'))
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return;
      final body = json.decode(response.body);
      if (body is Map) {
        castReceiverAppId = (body['cast_receiver_app_id'] ?? '').toString().trim();
        publicBaseUrl = (body['public_base_url'] ?? '').toString().trim();
      }
    } catch (_) {
      // Keep whatever we had; casting falls back to the default receiver.
    }
  }

  /// Does the configured server still need its first admin account?
  /// null = couldn't tell (server unreachable); the gate then shows login.
  static Future<bool?> needsSetup() async {
    try {
      await detectNetwork();
      final response = await appHttpClient
          .get(Uri.parse('$baseUrl/setup/status'))
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return null;
      final body = json.decode(response.body);
      return body is Map ? body['needs_setup'] == true : null;
    } catch (_) {
      return null;
    }
  }

  /// "192.168.1.5:5002" → "http://192.168.1.5:5002"; trims whitespace and
  /// trailing slashes. Empty stays empty (meaning "use the default").
  static String normalizeHost(String value) {
    var s = value.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.isEmpty) return s;
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'http://$s';
    }
    return s;
  }

  static final bool _isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  // Start with the best configured host, then switch to a local one if detected.
  static String baseHost = _startingHost;
  static String baseUrl = '$baseHost/api';

  // Read-only media token embedded in stream/artwork/artist-image URLs that
  // native players, the image loader, and Chromecast fetch directly and can't
  // attach an auth header to. Set by AuthService after login. It's scoped to
  // media GETs only, so a leaked URL can't reach the mutating API.
  static String? mediaToken;

  static String _withMediaToken(String url, {Object? cacheBuster}) {
    var u = url;
    final t = mediaToken;
    if (t != null && t.isNotEmpty) {
      u = '$u${u.contains('?') ? '&' : '?'}token=$t';
    }
    if (cacheBuster != null) {
      // Correct separator — a cache-buster appended after the token must use &,
      // not ? (a second ? corrupts the token value → 401 / broken image).
      u = '$u${u.contains('?') ? '&' : '?'}v=$cacheBuster';
    }
    return u;
  }

  // Track whether we're on a local host so we don't re-check every request
  static bool _isOnLan = false;
  static DateTime? _lastLanCheck;
  // Consecutive failed local-host checks. Stickiness: one transient miss while
  // already on a local host shouldn't bounce us out to the slow WAN endpoint.
  static int _lanMissStreak = 0;

  /// Pick the fastest reachable backend host: loopback (desktop, co-located
  /// with the backend) → LAN IP → public WAN as last resort. Caches for 30s.
  ///
  /// Detection hits the trivial `/api/ping` (no DB, no Essentia/Transcode
  /// probes) so a hung sidecar or a momentarily-busy backend can't make us
  /// think the local server vanished and bounce streaming out to Cloudflare —
  /// the bug behind flaky stream opens, mid-song read failures, and slow loads.
  static Future<void> detectNetwork() async {
    final now = DateTime.now();
    if (_lastLanCheck != null && now.difference(_lastLanCheck!).inSeconds < 30) {
      return; // Use cached result
    }
    _lastLanCheck = now;

    // Desktop is usually on the same box as the backend, so loopback is the
    // fastest, most reliable route and never touches Cloudflare. Mobile has no
    // local backend, so it only tries the LAN IP.
    final candidates = [
      if (_isDesktop) _localHost,
      if (_lanHost.isNotEmpty) _lanHost,
    ];

    for (final host in candidates) {
      try {
        final response = await appHttpClient
            .get(Uri.parse('$host/api/ping'))
            .timeout(const Duration(seconds: 3));
        if (response.statusCode == 200) {
          _lanMissStreak = 0;
          if (!_isOnLan || baseHost != host) {
            AppLogger.instance.info('📡 [network] using local host $host');
          }
          _isOnLan = true;
          baseHost = host;
          baseUrl = '$baseHost/api';
          return;
        }
      } catch (_) {
        // try the next candidate
      }
    }

    // No local host answered. Be sticky: a single miss while already local is
    // almost always a transient hiccup — require two consecutive misses before
    // falling back to the slow public WAN endpoint.
    _lanMissStreak++;
    if (_isOnLan && _lanMissStreak < 2) {
      return; // keep the current local host this round
    }
    // Fall back to the remote address; with none configured, stay on the
    // best local candidate so requests fail fast instead of hitting nothing.
    final fallback = _wanHost.isNotEmpty ? _wanHost : _startingHost;
    if (_isOnLan) {
      AppLogger.instance.info('📡 [network] local host unreachable → $fallback');
    }
    _isOnLan = false;
    baseHost = fallback;
    baseUrl = '$baseHost/api';
  }

  /// Force an immediate host re-probe, bypassing the 30s cache and the
  /// sticky-LAN miss streak. Call this on a real network-change event
  /// (WiFi↔cellular) — that's exactly when the previous host is likely
  /// gone and the stickiness (meant to ride out transient blips at home)
  /// should NOT delay the switch. Without this, leaving WiFi could keep
  /// hammering the dead LAN IP for up to ~2 cache cycles before failing
  /// over to WAN.
  static Future<void> forceNetworkRecheck() async {
    _lastLanCheck = null;
    _lanMissStreak = 0;
    await detectNetwork();
  }

  /// Whether we're currently connected via LAN
  static bool get isOnLan => _isOnLan;

  // Server health check (short timeout, never throws).
  //
  // Generous timeout because /api/health touches sidecar services
  // (Essentia, Transcode) and we'd rather wait than false-alarm the
  // "Server unreachable" banner over a momentarily slow response.
  // The backend sidecar probes have their own short timeouts to
  // keep the overall response well under this ceiling.
  Future<bool> checkServerHealth() async {
    await detectNetwork();
    try {
      final response = await appHttpClient
          .get(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 8));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // Get all artists
  Future<List<Artist>> getArtists() async {
    final response = await _get('$baseUrl/artists');

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((json) => Artist.fromJson(json)).toList();
    } else {
      throw Exception('Failed to load artists');
    }
  }

  // Get all albums
  Future<List<Album>> getAlbums() async {
    final response = await _get('$baseUrl/albums');

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((json) => Album.fromJson(json)).toList();
    } else {
      throw Exception('Failed to load albums');
    }
  }

  // Browse: Genres
  Future<List<Map<String, dynamic>>> getGenres() async {
    final response = await _get('$baseUrl/browse/genres');
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.cast<Map<String, dynamic>>();
    }
    throw Exception('Failed to load genres');
  }

  Future<Map<String, dynamic>> getGenreSongs(String genre,
      {int limit = 100, int offset = 0}) async {
    final encoded = Uri.encodeComponent(genre);
    final response = await _get(
        '$baseUrl/browse/genre/$encoded/songs?limit=$limit&offset=$offset');
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return {
        'songs': (data['songs'] as List)
            .map((json) => Song.fromJson(json))
            .toList(),
        'total': data['total'],
        'genre': data['genre'],
      };
    }
    throw Exception('Failed to load genre songs');
  }

  // Browse: Years & Decades
  Future<List<Map<String, dynamic>>> getYears() async {
    final response = await _get('$baseUrl/browse/years');
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.cast<Map<String, dynamic>>();
    }
    throw Exception('Failed to load years');
  }

  Future<List<Map<String, dynamic>>> getDecades() async {
    final response = await _get('$baseUrl/browse/decades');
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.cast<Map<String, dynamic>>();
    }
    throw Exception('Failed to load decades');
  }

  Future<List<Album>> getAlbumsByYear(int year) async {
    final response = await _get('$baseUrl/browse/year/$year/albums');
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((json) => Album.fromJson(json)).toList();
    }
    throw Exception('Failed to load albums for year $year');
  }

  Future<List<Album>> getAlbumsByDecade(int decade) async {
    final response = await _get('$baseUrl/browse/decade/$decade/albums');
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((json) => Album.fromJson(json)).toList();
    }
    throw Exception('Failed to load albums for decade ${decade}s');
  }

  // Get songs with pagination
  Future<Map<String, dynamic>> getSongsPaginated({
    int page = 1,
    int perPage = 50,
  }) async {
    final response = await _get('$baseUrl/songs?page=$page&per_page=$perPage');

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return {
        'songs': (data['songs'] as List)
            .map((json) => Song.fromJson(json))
            .toList(),
        'total': data['total'],
        'page': data['page'],
        'per_page': data['per_page'],
        'total_pages': data['total_pages'],
      };
    } else {
      throw Exception('Failed to load songs');
    }
  }

  // Get all songs (legacy - loads all pages)
  Future<List<Song>> getSongs() async {
    final result = await getSongsPaginated(page: 1, perPage: 200);
    return result['songs'] as List<Song>;
  }

  // Get artist details with albums
  Future<Map<String, dynamic>> getArtist(int artistId) async {
    final response = await _get('$baseUrl/artist/$artistId');

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to load artist');
    }
  }

  // Get album details with songs
  Future<Map<String, dynamic>> getAlbum(int albumId) async {
    final response = await _get('$baseUrl/album/$albumId');

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to load album');
    }
  }

  // Get stream URL for a song
  String getStreamUrl(int songId, {String quality = 'lossless'}) {
    if (quality == 'lossless') {
      return _withMediaToken('$baseUrl/stream/$songId');
    }
    return _withMediaToken('$baseUrl/stream/$songId?quality=$quality');
  }

  /// Live radio stations (Icecast/Shoutcast). The player streams station['url']
  /// directly — these are just the catalog/CRUD calls.
  Future<List<Map<String, dynamic>>> getStations() async {
    final response = await _get('$baseUrl/stations');
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.cast<Map<String, dynamic>>();
    }
    throw Exception('Failed to load stations: ${response.statusCode}');
  }

  Future<Map<String, dynamic>> createStation(String name, String url,
      {String? genre,
      String? description,
      String? homepage,
      String? favicon}) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/stations'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'name': name,
        'url': url,
        'genre': genre,
        'description': description,
        'homepage': homepage,
        'favicon': favicon,
      }),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    }
    throw Exception('Failed to create station: ${response.body}');
  }

  /// Search the global radio-browser directory (proxied + alias-expanded by the
  /// backend). Results are playable directly and saveable via createStation.
  Future<List<Map<String, dynamic>>> searchStations(String query,
      {String sort = 'popular'}) async {
    final response = await _get(
        '$baseUrl/stations/search?q=${Uri.encodeQueryComponent(query)}&sort=$sort');
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      if (data is List) return data.cast<Map<String, dynamic>>();
      return [];
    }
    throw Exception('Search failed: ${response.statusCode}');
  }

  Future<void> deleteStation(int stationId) async {
    final response =
        await appHttpClient.delete(Uri.parse('$baseUrl/stations/$stationId'));
    if (response.statusCode != 200) {
      throw Exception('Failed to delete station: ${response.statusCode}');
    }
  }

  /// Favorited stations (full station rows, newest-favorited first).
  Future<List<Map<String, dynamic>>> getFavoriteStations() async {
    final response = await _get('$baseUrl/favorites/stations');
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      if (data is List) return data.cast<Map<String, dynamic>>();
      return [];
    }
    throw Exception('Failed to load favorite stations');
  }

  /// Favorite status for a station by its stream URL — station Songs carry
  /// synthetic negative ids, so the id-based check can't work. Returns
  /// {is_favorite: bool, station_id: int|null}.
  Future<Map<String, dynamic>> stationFavoriteStatus(String url) async {
    final response = await _get(
        '$baseUrl/favorites/station-status?url=${Uri.encodeQueryComponent(url)}');
    if (response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    }
    throw Exception('Failed to check station favorite');
  }

  /// Bump a station's play_count (drives the "most listened" carousel).
  /// Fire-and-forget — a failed beacon shouldn't interrupt playback.
  Future<void> trackStationPlay(int stationId) async {
    try {
      await appHttpClient
          .post(Uri.parse('$baseUrl/stations/$stationId/played'));
    } catch (_) {}
  }

  // Pre-transcode a song in the background so it's cached for instant playback
  Future<void> prefetchSong(int songId, {String quality = 'high'}) async {
    if (quality == 'lossless') return;
    try {
      await appHttpClient.post(Uri.parse('$baseUrl/prefetch/$songId?quality=$quality'));
    } catch (_) {
      // Fire-and-forget — don't care if it fails
    }
  }

  // Get artwork URL for an album (full resolution for detail/fullscreen views)
  String getArtworkUrl(int albumId, {Object? cacheBuster}) {
    return _withMediaToken('$baseUrl/artwork/$albumId', cacheBuster: cacheBuster);
  }

  // Get thumbnail artwork URL (300px, for lists and grids)
  String getArtworkThumbUrl(int albumId) {
    return _withMediaToken('$baseUrl/artwork/$albumId?size=thumb');
  }

  // Search
  Future<Map<String, dynamic>> search(String query) async {
    final response = await _get('$baseUrl/search?q=$query');

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to search');
    }
  }

  // Get library stats
  Future<Map<String, dynamic>> getStats() async {
    final response = await _get('$baseUrl/stats');

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to load stats');
    }
  }

  // Health check (pool info, service status)
  Future<Map<String, dynamic>> getHealth() async {
    final response = await _get('$baseUrl/health');
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    return {};
  }

  // System logs
  Future<Map<String, dynamic>> getLogs({int lines = 200, String? level, String? search}) async {
    var url = '$baseUrl/logs?lines=$lines';
    if (level != null) url += '&level=$level';
    if (search != null && search.isNotEmpty) url += '&search=${Uri.encodeComponent(search)}';
    final response = await _get(url);
    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to load logs');
    }
  }

  // ── Party mode ─────────────────────────────────────────────────────

  /// Full song fetch by id — used when a party guest adds a track and the
  /// host app needs the complete Song to enqueue it.
  Future<Song> getSongById(int songId) async {
    final response = await _get('$baseUrl/song/$songId');
    if (response.statusCode == 200) {
      return Song.fromJson(json.decode(response.body));
    }
    throw Exception('Song $songId not found');
  }

  Future<Map<String, dynamic>> startParty() async {
    final response = await _post('$baseUrl/party/start');
    if (response.statusCode == 200) return json.decode(response.body);
    throw Exception('Failed to start party: ${response.body}');
  }

  Future<Map<String, dynamic>> endParty() async {
    final response = await _post('$baseUrl/party/end');
    if (response.statusCode == 200) return json.decode(response.body);
    throw Exception('Failed to end party: ${response.body}');
  }

  Future<Map<String, dynamic>> getPartyState() async {
    final response = await _get('$baseUrl/party/state');
    if (response.statusCode == 200) return json.decode(response.body);
    throw Exception('Failed to get party state');
  }

  // Rescan library
  Future<Map<String, dynamic>> rescanLibrary() async {
    final response = await _post('$baseUrl/rescan');

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to rescan library');
    }
  }

  // Download artwork from MusicBrainz
  Future<Map<String, dynamic>> downloadArtwork() async {
    final response = await _post('$baseUrl/download-artwork');

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to download artwork');
    }
  }

  // Download artist images from Last.fm
  Future<Map<String, dynamic>> downloadArtistImages() async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/download-artist-images'),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to download artist images');
    }
  }

  // Get artist image URL
  String getArtistImageUrl(int artistId, {Object? cacheBuster}) {
    return _withMediaToken('$baseUrl/artist-image/$artistId', cacheBuster: cacheBuster);
  }

  // Download artist image from Fanart.tv
  Future<Map<String, dynamic>> downloadArtistImage(int artistId) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/artist/$artistId/download-image'),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else if (response.statusCode == 404) {
      final data = json.decode(response.body);
      throw Exception(data['message'] ?? 'Could not find image for artist');
    } else {
      throw Exception('Failed to download artist image');
    }
  }

  // Search for artist images from multiple sources
  Future<Map<String, dynamic>> searchArtistImages(int artistId) async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/artist/$artistId/image-search'),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to search artist images');
    }
  }

  // Select an artist image by URL
  Future<Map<String, dynamic>> selectArtistImage(int artistId, String imageUrl) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/artist/$artistId/set-image'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'url': imageUrl}),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to save artist image');
    }
  }

  // Upload a custom artist image
  Future<Map<String, dynamic>> uploadArtistImage(int artistId, List<int> bytes, String filename) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/artist/$artistId/upload-image'),
    );
    request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));

    final streamedResponse = await appHttpClient.send(request);
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to upload artist image');
    }
  }

  // Edit artist name
  Future<Map<String, dynamic>> editArtist(
    dynamic artistId,
    String newName,
  ) async {
    final response = await appHttpClient.put(
      Uri.parse('$baseUrl/edit/artist/$artistId'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'name': newName}),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to edit artist: ${response.body}');
    }
  }

  // Merge multiple artists into one
  Future<Map<String, dynamic>> mergeArtists(
    int targetArtistId,
    List<int> sourceArtistIds,
  ) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/edit/merge-artists'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'target_artist_id': targetArtistId,
        'source_artist_ids': sourceArtistIds,
      }),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to merge artists: ${response.body}');
    }
  }

  // Find similar artists for merge suggestions
  Future<List<List<Artist>>> findSimilarArtists() async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/edit/find-similar-artists'),
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final suggestions = data['suggestions'] as List;

      return suggestions.map((group) {
        return (group as List).map((json) => Artist.fromJson(json)).toList();
      }).toList();
    } else {
      throw Exception('Failed to find similar artists');
    }
  }

  // Edit song metadata (title, track_number, disc_number)
  Future<Map<String, dynamic>> editSong(
    int songId, {
    String? title,
    int? trackNumber,
    int? discNumber,
  }) async {
    final body = <String, dynamic>{};
    if (title != null) body['title'] = title;
    if (trackNumber != null) body['track_number'] = trackNumber;
    if (discNumber != null) body['disc_number'] = discNumber;

    final response = await appHttpClient.put(
      Uri.parse('$baseUrl/edit/song/$songId'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to edit song: ${response.body}');
    }
  }

  // Edit song artist
  Future<Map<String, dynamic>> editSongArtist(
    int songId,
    dynamic artistId,
  ) async {
    final response = await appHttpClient.put(
      Uri.parse('$baseUrl/edit/song/$songId'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'artist_id': artistId}),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to edit song artist: ${response.body}');
    }
  }

  // Bulk edit song artists
  Future<Map<String, dynamic>> editSongsArtist(
    List<int> songIds,
    dynamic artistId,
  ) async {
    final response = await appHttpClient.put(
      Uri.parse('$baseUrl/edit/songs/artist'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'song_ids': songIds, 'artist_id': artistId}),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to edit song artists: ${response.body}');
    }
  }

  // Edit album title
  Future<Map<String, dynamic>> editAlbum(int albumId, String newTitle) async {
    final response = await appHttpClient.put(
      Uri.parse('$baseUrl/edit/album/$albumId'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'title': newTitle}),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to edit album: ${response.body}');
    }
  }

  // Edit album year
  Future<Map<String, dynamic>> editAlbumYear(int albumId, int? year) async {
    final response = await appHttpClient.put(
      Uri.parse('$baseUrl/edit/album/$albumId/year'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'year': year}),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to edit album year: ${response.body}');
    }
  }

  // Strip (Album Version) from all songs in an album
  Future<Map<String, dynamic>> stripAlbumVersion(int albumId) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/edit/strip-album-version/$albumId'),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to strip album version: ${response.body}');
    }
  }

  // Get song details including file path
  Future<Map<String, dynamic>> getSongDetails(int songId) async {
    final response = await _get('$baseUrl/song/$songId');

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to load song details');
    }
  }

  /// Fetch the saved Essentia analysis for a song.
  /// Returns `null` if no analysis exists yet (404 from backend).
  /// All other failures throw so the UI can show a real error.
  Future<Map<String, dynamic>?> getSongAnalysis(int songId) async {
    final response = await _get('$baseUrl/analysis/song/$songId');

    if (response.statusCode == 200) {
      return json.decode(response.body) as Map<String, dynamic>;
    } else if (response.statusCode == 404) {
      return null;
    } else {
      throw Exception(
        'Failed to load song analysis (HTTP ${response.statusCode})',
      );
    }
  }

  // Delete song from database
  Future<Map<String, dynamic>> deleteSong(int songId) async {
    final response = await appHttpClient.delete(Uri.parse('$baseUrl/song/$songId'));

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to delete song: ${response.body}');
    }
  }

  // Delete album from database
  Future<Map<String, dynamic>> deleteAlbum(
    int albumId, {
    bool deleteFiles = false,
  }) async {
    final response = await appHttpClient.delete(
      Uri.parse('$baseUrl/album/$albumId?delete_files=$deleteFiles'),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to delete album: ${response.body}');
    }
  }

  // Delete artist from database
  Future<Map<String, dynamic>> deleteArtist(
    int artistId, {
    bool deleteFiles = false,
  }) async {
    final response = await appHttpClient.delete(
      Uri.parse('$baseUrl/artist/$artistId?delete_files=$deleteFiles'),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to delete artist: ${response.body}');
    }
  }

  // Renumber tracks in a disc
  Future<Map<String, dynamic>> renumberDiscTracks(
    int albumId,
    int discNumber,
    int startNumber,
  ) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/album/$albumId/renumber-disc'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'disc_number': discNumber,
        'start_number': startNumber,
      }),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to renumber tracks: ${response.body}');
    }
  }

  // Get waveform data for a song. Pass [client] for cancellation
  // when the current song changes.
  Future<List<double>> getWaveform(int songId, {http.Client? client}) async {
    // Default to the shared token-injecting client; it is never closed here.
    // A caller-supplied client is owned (and closed) by that caller.
    final c = client ?? appHttpClient;
    try {
      final response = await c
          .get(Uri.parse('$baseUrl/waveform/$songId'))
          .timeout(const Duration(seconds: 60));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        // API returns {"status": "ready|generating|error", "waveform": [...]}
        final waveformField = data['waveform'];
        if (waveformField is List) {
          return waveformField.map((e) => (e as num).toDouble()).toList();
        }
        return List.filled(1000, 0.5);
      } else {
        return List.filled(1000, 0.5);
      }
    } finally {
      if (c != appHttpClient) c.close();
    }
  }

  // Status-aware waveform fetch. The backend answers 'generating' with a
  // flat 0.5×1000 placeholder while the real waveform is still being
  // decoded — getWaveform() above returns that placeholder as if it were
  // real data, which is fine for the phone UI (it re-fetches on rebuild)
  // but left the cast receiver stuck with the flat bar forever. Callers
  // that need to know whether to re-poll use this variant.
  Future<({String status, List<double> waveform})> getWaveformStatus(
    int songId, {
    http.Client? client,
  }) async {
    final c = client ?? appHttpClient;
    try {
      final response = await c
          .get(Uri.parse('$baseUrl/waveform/$songId'))
          .timeout(const Duration(seconds: 60));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final status = (data['status'] as String?) ?? 'ready';
        final waveformField = data['waveform'];
        final waveform = waveformField is List
            ? waveformField.map((e) => (e as num).toDouble()).toList()
            : List.filled(1000, 0.5);
        return (status: status, waveform: waveform);
      }
      return (status: 'error', waveform: List.filled(1000, 0.5));
    } finally {
      if (c != appHttpClient) c.close();
    }
  }

  // Find similar albums for merging
  Future<List<List<Album>>> findSimilarAlbums() async {
    final response = await _get('$baseUrl/find-similar-albums');

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data
          .map(
            (group) =>
                (group as List).map((json) => Album.fromJson(json)).toList(),
          )
          .toList();
    } else {
      throw Exception('Failed to find similar albums');
    }
  }

  // Merge albums
  Future<Map<String, dynamic>> mergeAlbums(
    int targetAlbumId,
    List<int> sourceAlbumIds,
    Map<int, int> discNumbers,
    String newAlbumName, {
    dynamic
    albumArtistId, // int for specific artist, "various_artists" string, or null to keep target's artist
    String? mbid,
    Map<int, String>? discNames,
    bool updateSongArtists = false,
  }) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/merge-albums'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'target_album_id': targetAlbumId,
        'source_album_ids': sourceAlbumIds,
        'disc_numbers': discNumbers.map((k, v) => MapEntry(k.toString(), v)),
        'new_album_name': newAlbumName,
        if (albumArtistId != null) 'album_artist_id': albumArtistId,
        if (mbid != null) 'mbid': mbid,
        if (discNames != null)
          'disc_names': discNames.map((k, v) => MapEntry(k.toString(), v)),
        'update_song_artists': updateSongArtists,
      }),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to merge albums: ${response.body}');
    }
  }

  // Analytics endpoints
  Future<Map<String, dynamic>> trackPlay(int songId) async {
    if (songId < 0) return {'success': true}; // Virtual podcast song, skip tracking
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/track-play'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'song_id': songId}),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to track play');
    }
  }

  Future<Map<String, dynamic>> trackComplete(
    int songId,
    int completionPercentage,
  ) async {
    if (songId < 0) return {'success': true}; // Virtual podcast song, skip tracking
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/track-complete'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'song_id': songId,
        'completion_percentage': completionPercentage,
      }),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to track completion');
    }
  }

  Future<Map<String, dynamic>> trackSkip(int songId) async {
    if (songId < 0) return {'success': true}; // Virtual podcast song, skip tracking
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/track-skip'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'song_id': songId}),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to track skip');
    }
  }

  Future<List<Song>> getRecentlyPlayed({int limit = 50}) async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/recently-played?limit=$limit'),
    );

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((json) => Song.fromJson(json)).toList();
    } else {
      throw Exception('Failed to load recently played');
    }
  }

  Future<List<Song>> getMostPlayed({int limit = 50}) async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/most-played?limit=$limit'),
    );

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((json) => Song.fromJson(json)).toList();
    } else {
      throw Exception('Failed to load most played');
    }
  }

  Future<Map<String, dynamic>> getAnalyticsStats() async {
    final response = await _get('$baseUrl/analytics-stats');

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to load analytics stats');
    }
  }

  // Favorites endpoints
  Future<Map<String, dynamic>> addFavorite(String itemType, int itemId) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/favorites/add'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'item_type': itemType, 'item_id': itemId}),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to add favorite');
    }
  }

  Future<Map<String, dynamic>> removeFavorite(
    String itemType,
    int itemId,
  ) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/favorites/remove'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'item_type': itemType, 'item_id': itemId}),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to remove favorite');
    }
  }

  Future<bool> checkFavorite(String itemType, int itemId) async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/favorites/check?item_type=$itemType&item_id=$itemId'),
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return data['is_favorite'] ?? false;
    } else {
      throw Exception('Failed to check favorite');
    }
  }

  /// Check favorite status for many ids in ONE request. Used by
  /// FavoritesBatcher to collapse the per-button /favorites/check storm
  /// (which exhausts the DB pool) into a single query. Returns {id: bool}.
  Future<Map<int, bool>> checkFavoritesBatch(
    String itemType,
    List<int> ids,
  ) async {
    if (ids.isEmpty) return {};
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/favorites/check-batch'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'item_type': itemType, 'ids': ids}),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final favs = (data['favorites'] as Map?) ?? {};
      return favs.map(
        (k, v) => MapEntry(int.parse(k.toString()), v == true),
      );
    }
    throw Exception('Failed to batch-check favorites: ${response.statusCode}');
  }

  Future<List<Song>> getFavoriteSongs() async {
    final response = await _get('$baseUrl/favorites/songs');

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((json) => Song.fromJson(json)).toList();
    } else {
      throw Exception('Failed to load favorite songs');
    }
  }

  Future<List<Album>> getFavoriteAlbums() async {
    final response = await _get('$baseUrl/favorites/albums');

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((json) => Album.fromJson(json)).toList();
    } else {
      throw Exception('Failed to load favorite albums');
    }
  }

  Future<List<Artist>> getFavoriteArtists() async {
    final response = await _get('$baseUrl/favorites/artists');

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((json) => Artist.fromJson(json)).toList();
    } else {
      throw Exception('Failed to load favorite artists');
    }
  }

  Future<Map<String, dynamic>> getFavoritesCounts() async {
    final response = await _get('$baseUrl/favorites/counts');

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to load favorites counts');
    }
  }

  // Search for artwork options for an album
  Future<Map<String, dynamic>> searchArtwork(int albumId) async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/artwork/search/$albumId'),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to search artwork');
    }
  }

  // Save selected artwork for an album
  Future<Map<String, dynamic>> selectArtwork(
    int albumId,
    String releaseId,
  ) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/artwork/select'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'album_id': albumId, 'release_id': releaseId}),
    ).timeout(const Duration(seconds: 90));

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to save artwork');
    }
  }

  // Set an album's release type (primary Album/Single/EP + optional
  // secondary tags like "Compilation,Live").
  Future<Map<String, dynamic>> setAlbumType(
    int albumId,
    String albumType,
    String? secondaryTypes,
  ) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/album/$albumId/type'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'album_type': albumType,
        'secondary_types': secondaryTypes,
      }),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to set album type (${response.statusCode})');
  }

  // Toggle whether an album's plays scrobble to Last.fm.
  Future<void> setAlbumScrobbleExclude(int albumId, bool excluded) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/album/$albumId/scrobble-exclude'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'excluded': excluded}),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to update scrobble setting (${response.statusCode})');
    }
  }

  // Toggle whether an artist's plays scrobble to Last.fm.
  Future<void> setArtistScrobbleExclude(int artistId, bool excluded) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/artist/$artistId/scrobble-exclude'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'excluded': excluded}),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to update scrobble setting (${response.statusCode})');
    }
  }

  // Get artwork by MusicBrainz release ID
  Future<Map<String, dynamic>> getArtworkByMbid(String releaseId) async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/artwork/mbid/$releaseId'),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Release not found');
    }
  }

  // Upload custom artwork for an album
  Future<Map<String, dynamic>> uploadArtwork(
    int albumId,
    List<int> imageBytes,
    String filename,
  ) async {
    var request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/artwork/upload/$albumId'),
    );

    request.files.add(
      http.MultipartFile.fromBytes('file', imageBytes, filename: filename),
    );

    final streamedResponse = await appHttpClient.send(request).timeout(
      const Duration(seconds: 30),
    );
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to upload artwork');
    }
  }

  // Playlist endpoints
  Future<List<Playlist>> getPlaylists() async {
    final response = await _get('$baseUrl/playlists');

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((json) => Playlist.fromJson(json)).toList();
    } else {
      throw Exception('Failed to load playlists');
    }
  }

  Future<Map<String, dynamic>> getPlaylist(int playlistId) async {
    final response = await _get('$baseUrl/playlist/$playlistId');

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to load playlist');
    }
  }

  Future<Map<String, dynamic>> createPlaylist(
    String name,
    String? description,
  ) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/playlist'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'name': name, 'description': description}),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to create playlist: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> updatePlaylist(
    int playlistId,
    String? name,
    String? description,
  ) async {
    final response = await appHttpClient.put(
      Uri.parse('$baseUrl/playlist/$playlistId'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'name': name, 'description': description}),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to update playlist: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> deletePlaylist(int playlistId) async {
    final response = await appHttpClient.delete(
      Uri.parse('$baseUrl/playlist/$playlistId'),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to delete playlist: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> addSongToPlaylist(
    int playlistId,
    int songId, {
    int? position,
  }) async {
    final body = {'song_id': songId};
    if (position != null) {
      body['position'] = position;
    }

    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/playlist/$playlistId/add'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to add song to playlist: ${response.body}');
    }
  }

  /// Returns the OPML export URL. Open in a browser to download the
  /// file; the backend serves it with Content-Disposition: attachment.
  String get opmlExportUrl => '$baseUrl/rss/opml/export';

  /// Bulk-subscribe from an OPML document. Pass either `opmlText`
  /// (paste) or `opmlUrl` (fetch server-side). Returns a structured
  /// result with `added`, `skipped_already_subscribed`, and `failed`.
  Future<Map<String, dynamic>> importOpml({String? opmlText, String? opmlUrl}) async {
    final body = <String, dynamic>{};
    if (opmlText != null && opmlText.isNotEmpty) body['opml_text'] = opmlText;
    if (opmlUrl != null && opmlUrl.isNotEmpty) body['opml_url'] = opmlUrl;
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/rss/opml/import'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );
    final data = json.decode(response.body);
    if (response.statusCode != 200) {
      throw Exception(data['error'] ?? 'OPML import failed');
    }
    return data as Map<String, dynamic>;
  }

  /// Add a podcast episode to a playlist. The backend resolves the
  /// episode to its mirrored `songs` row and inserts by song_id.
  Future<Map<String, dynamic>> addEpisodeToPlaylist(
    int playlistId,
    int episodeId, {
    int? position,
  }) async {
    final body = <String, dynamic>{'episode_id': episodeId};
    if (position != null) body['position'] = position;
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/playlist/$playlistId/add-episode'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to add episode to playlist: ${response.body}');
  }

  Future<Map<String, dynamic>> removeSongFromPlaylist(
    int playlistId,
    int songId,
  ) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/playlist/$playlistId/remove'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'song_id': songId}),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to remove song from playlist: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> reorderPlaylistSong(
    int playlistId,
    int songId,
    int newPosition,
  ) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/playlist/$playlistId/reorder'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'song_id': songId, 'new_position': newPosition}),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to reorder song: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> addSongsToPlaylist(
    int playlistId,
    List<int> songIds, {
    int? position,
  }) async {
    final body = <String, dynamic>{'song_ids': songIds};
    if (position != null) {
      body['position'] = position;
    }

    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/playlist/$playlistId/add-songs'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to add songs to playlist: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> bulkReorderPlaylistSongs(
    int playlistId,
    List<int> songIds,
    int newPosition,
  ) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/playlist/$playlistId/bulk-reorder'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'song_ids': songIds, 'new_position': newPosition}),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to bulk reorder songs: ${response.body}');
    }
  }

  // Import playlist from Spotify
  Future<Map<String, dynamic>> importSpotifyPlaylist(
    String playlistUrl,
    bool createPlaylist, {
    int? existingPlaylistId,
    bool skipExisting = false,
  }) async {
    final response = await appHttpClient
        .post(
          Uri.parse('$baseUrl/spotify/import'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'playlist_url': playlistUrl,
            'create_playlist': createPlaylist,
            if (existingPlaylistId != null)
              'existing_playlist_id': existingPlaylistId,
            'skip_existing': skipExisting,
          }),
        )
        .timeout(const Duration(minutes: 15));

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to import playlist: ${response.body}');
    }
  }

  // Cancel an in-progress Spotify import
  Future<void> cancelSpotifyImport() async {
    await _post('$baseUrl/spotify/import/cancel');
  }

  // List the albums (release-groups) a track appears on, tagged by category
  // (Studio Album / Compilation / Live / ...), for the missing-track picker.
  Future<List<Map<String, dynamic>>> getTrackReleases(
    String artist,
    String track,
  ) async {
    final uri = Uri.parse('$baseUrl/musicbrainz/track-releases').replace(
      queryParameters: {'artist': artist, 'track': track},
    );
    final response = await appHttpClient.get(uri).timeout(const Duration(seconds: 30));
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return List<Map<String, dynamic>>.from(data['candidates'] ?? []);
    }
    throw Exception('Failed to load releases: ${response.body}');
  }

  // ---- Admin: user management (admin-only on the backend) ----

  Future<List<Map<String, dynamic>>> getUsers() async {
    final response = await appHttpClient.get(Uri.parse('$baseUrl/users'));
    if (response.statusCode == 200) {
      return List<Map<String, dynamic>>.from(
        json.decode(response.body)['users'] ?? [],
      );
    }
    throw Exception('Failed to load users: ${response.body}');
  }

  Future<Map<String, dynamic>> createUser(
    String username,
    String password,
    String role,
  ) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/users'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(
        {'username': username, 'password': password, 'role': role},
      ),
    );
    return json.decode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> setUserPassword(int userId, String password) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/users/$userId/password'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'password': password}),
    );
    return json.decode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> setUserRole(int userId, String role) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/users/$userId/role'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'role': role}),
    );
    return json.decode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> revokeUser(int userId) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/users/$userId/revoke'),
    );
    return json.decode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> deleteUser(int userId) async {
    final response = await appHttpClient.delete(
      Uri.parse('$baseUrl/users/$userId'),
    );
    return json.decode(response.body) as Map<String, dynamic>;
  }

  // Import a playlist from a custom .m3u8 file's text content
  Future<Map<String, dynamic>> importM3u8Playlist(
    String content, {
    String? filename,
    bool createPlaylist = true,
    int? existingPlaylistId,
    bool skipExisting = false,
  }) async {
    final response = await appHttpClient
        .post(
          Uri.parse('$baseUrl/playlist/import-m3u8'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'content': content,
            if (filename != null) 'filename': filename,
            'create_playlist': createPlaylist,
            if (existingPlaylistId != null)
              'existing_playlist_id': existingPlaylistId,
            'skip_existing': skipExisting,
          }),
        )
        .timeout(const Duration(minutes: 15));

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to import playlist: ${response.body}');
    }
  }

  // Link an unmatched playlist entry to a local song
  Future<Map<String, dynamic>> linkPlaylistSong(
    int playlistId,
    String spotifyTrackId,
    int songId,
  ) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/playlist/$playlistId/link'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'spotify_track_id': spotifyTrackId,
        'song_id': songId,
      }),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to link song: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> getArtistTopTracks(int artistId) async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/artist/$artistId/top-tracks'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load top tracks');
  }

  Future<Map<String, dynamic>> getArtistLastfmTopTracks(int artistId) async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/artist/$artistId/lastfm-top-tracks'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load Last.fm top tracks');
  }

  // Pass a [client] if you need to cancel an in-flight request
  // (e.g. when the artist screen is disposed before the MusicBrainz
  // + Spotify calls return). Closing the client aborts the pending
  // HTTP call so the backend releases its resources immediately.
  Future<Map<String, dynamic>> getArtistSpotifyTopTracks(
    int artistId, {
    http.Client? client,
  }) async {
    // Default to the shared token-injecting client; it is never closed here.
    // A caller-supplied client is owned (and closed) by that caller.
    final c = client ?? appHttpClient;
    try {
      final response = await c.get(
        Uri.parse('$baseUrl/artist/$artistId/spotify-top-tracks'),
      );
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
      throw Exception('Failed to load Spotify top tracks');
    } finally {
      if (c != appHttpClient) c.close();
    }
  }

  // Get artist discography from MusicBrainz
  Future<Map<String, dynamic>> getArtistDiscography(
    int artistId, {
    bool refresh = false,
  }) async {
    final response = await appHttpClient.get(
      Uri.parse(
        '$baseUrl/artist/$artistId/discography${refresh ? '?refresh=1' : ''}',
      ),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load discography');
  }

  // ========================
  // Playback State Endpoints
  // ========================

  Future<Map<String, dynamic>> getPlaybackState(String deviceId) async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/playback-state/$deviceId'),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to load playback state');
    }
  }

  Future<Map<String, dynamic>> savePlaybackState(
    String deviceId,
    Map<String, dynamic> state,
  ) async {
    final response = await appHttpClient.put(
      Uri.parse('$baseUrl/playback-state/$deviceId'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(state),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to save playback state');
    }
  }

  Future<List<Map<String, dynamic>>> getDevices() async {
    final response = await _get('$baseUrl/devices');

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.cast<Map<String, dynamic>>();
    } else {
      throw Exception('Failed to load devices');
    }
  }

  Future<void> deleteDevice(String deviceId) async {
    final response = await appHttpClient.delete(
      Uri.parse('$baseUrl/devices/$deviceId'),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to delete device');
    }
  }

  Future<List<Map<String, dynamic>>> getSongsBatch(List<int> songIds) async {
    if (songIds.isEmpty) return [];
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/songs/batch'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'ids': songIds}),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.cast<Map<String, dynamic>>();
    } else {
      throw Exception('Failed to load songs batch');
    }
  }

  // Get lyrics for a song.
  //
  // Pass a [client] if you need to cancel an in-flight request
  // (e.g. when the current song/screen changes). Closing the client
  // aborts the pending HTTP call — important because the backend
  // may spend up to 10s hitting LRCLIB, and a stale request holds
  // a DB connection the whole time.
  Future<Map<String, dynamic>> getLyrics(int songId, {http.Client? client}) async {
    // Default to the shared token-injecting client; it is never closed here.
    // A caller-supplied client is owned (and closed) by that caller.
    final c = client ?? appHttpClient;
    try {
      final response = await c
          .get(Uri.parse('$baseUrl/lyrics/$songId'))
          .timeout(const Duration(seconds: 60));
      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('Failed to load lyrics');
      }
    } finally {
      if (c != appHttpClient) c.close();
    }
  }

  // Get recently added albums
  Future<Map<String, dynamic>> getRecentlyAdded({
    int days = 30,
    int limit = 50,
  }) async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/recently-added?days=$days&limit=$limit'),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to load recently added');
    }
  }

  // Get song stats
  Future<Map<String, dynamic>> getSongStats(int songId) async {
    final response = await _get('$baseUrl/song/$songId/stats');

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to load song stats');
    }
  }

  // ========================
  // Spotify History Methods
  // ========================

  Future<Map<String, dynamic>> getSpotifyStats() async {
    final response = await _get('$baseUrl/spotify/stats');
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load Spotify stats');
  }

  Future<Map<String, dynamic>> getMissingAlbums({
    int page = 1,
    int perPage = 20,
  }) async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/spotify/missing?page=$page&per_page=$perPage'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load missing albums');
  }

  // Link a Spotify album to a library album
  Future<Map<String, dynamic>> linkSpotifyAlbum({
    required String spotifyArtist,
    String? spotifyAlbum,
    required int libraryAlbumId,
  }) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/spotify/link-album'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'spotify_artist': spotifyArtist,
        'spotify_album': spotifyAlbum,
        'library_album_id': libraryAlbumId,
      }),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to link album');
  }

  // Dismiss a missing Spotify album
  Future<Map<String, dynamic>> dismissSpotifyAlbum({
    required String spotifyArtist,
    String? spotifyAlbum,
  }) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/spotify/dismiss-album'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'spotify_artist': spotifyArtist,
        'spotify_album': spotifyAlbum,
      }),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to dismiss album');
  }

  Future<List<dynamic>> getSpotifyHistory({
    int limit = 50,
    String? year,
  }) async {
    String url = '$baseUrl/spotify/history?limit=$limit';
    if (year != null) {
      url += '&year=$year';
    }
    final response = await _get(url);
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load Spotify history');
  }

  Future<Map<String, dynamic>> searchMusicBrainz(
    String artist,
    String album,
  ) async {
    final response = await appHttpClient.get(
      Uri.parse(
        '$baseUrl/musicbrainz/search?artist=${Uri.encodeComponent(artist)}&album=${Uri.encodeComponent(album)}',
      ),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('MusicBrainz search failed');
  }

  // MusicBrainz submission (release-editor seeding, spec §10):
  // structured prefill read from the actual files...
  Future<Map<String, dynamic>> getMbSeedData({
    String? path,
    int? albumId,
  }) async {
    final qp = <String, String>{};
    if (path != null) qp['path'] = path;
    if (albumId != null) qp['album_id'] = albumId.toString();
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/musicbrainz/seed-data').replace(queryParameters: qp),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Could not read release data from the files');
  }

  // Release-group drill-down: the actual releases inside one MB
  // release group (format/date/tracks/disambiguation), so the import
  // screen can show what editions already exist.
  Future<List<Map<String, dynamic>>> getMbRgReleases(String rgMbid) async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/musicbrainz/rg-releases?rgid=$rgMbid'),
    );
    if (response.statusCode == 200) {
      final body = json.decode(response.body);
      if (body['success'] == true) {
        return List<Map<String, dynamic>>.from(body['releases'] ?? []);
      }
    }
    throw Exception('Failed to load the release list');
  }

  // ...and the handoff: post the user-edited fields, get back the URL
  // that opens MusicBrainz's release editor pre-filled with them.
  Future<String> createMbHandoff(
    Map<String, dynamic> data,
    Map<String, dynamic> target,
    String comment,
  ) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/musicbrainz/handoff'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'data': data, 'target': target, 'comment': comment}),
    );
    if (response.statusCode == 200) {
      final body = json.decode(response.body);
      if (body['success'] == true && body['url'] != null) {
        return body['url'];
      }
    }
    throw Exception('Failed to stage the MusicBrainz handoff');
  }

  // ========================
  // Spotify Preview Methods
  // ========================

  Future<Map<String, dynamic>> getSpotifyAlbumTracks(
    String artist,
    String album,
  ) async {
    final response = await appHttpClient.get(
      Uri.parse(
        '$baseUrl/spotify/album-tracks?artist=${Uri.encodeComponent(artist)}&album=${Uri.encodeComponent(album)}',
      ),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load album tracks');
  }

  Future<Map<String, dynamic>> getSpotifyPreview(
    String artist,
    String track,
  ) async {
    final response = await appHttpClient.get(
      Uri.parse(
        '$baseUrl/spotify/preview?artist=${Uri.encodeComponent(artist)}&track=${Uri.encodeComponent(track)}',
      ),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to get preview URL');
  }

  // Get Spotify preview URL by track ID
  Future<Map<String, dynamic>> getSpotifyPreviewById(String trackId) async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/spotify/preview-by-id/$trackId'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to get preview URL');
  }

  // Add album to Lidarr
  Future<Map<String, dynamic>> addToLidarr(
    String artist,
    String album, {
    String? albumMbid,
  }) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/lidarr/add-album'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'artist': artist,
        'album': album,
        if (albumMbid != null) 'album_mbid': albumMbid,
      }),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      final error = json.decode(response.body);
      throw Exception(error['error'] ?? 'Failed to add to Lidarr');
    }
  }

  // Incremental scan - only import new files
  Future<Map<String, dynamic>> scanNewFiles() async {
    final response = await _post('$baseUrl/scan-new');

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to start incremental scan');
    }
  }

  // Get all excluded paths (manually deleted items)
  Future<List<Map<String, dynamic>>> getExcludedPaths() async {
    final response = await _get('$baseUrl/excluded-paths');

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.cast<Map<String, dynamic>>();
    } else {
      throw Exception('Failed to load excluded paths');
    }
  }

  // Restore an excluded path (remove from exclusions)
  Future<Map<String, dynamic>> restoreExcludedPath(int exclusionId) async {
    final response = await appHttpClient.delete(
      Uri.parse('$baseUrl/excluded-paths/$exclusionId'),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to restore excluded path');
    }
  }

  // Clear all exclusions
  Future<Map<String, dynamic>> clearAllExclusions() async {
    final response = await appHttpClient.delete(
      Uri.parse('$baseUrl/excluded-paths/clear'),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to clear exclusions');
    }
  }

  // Get aggregated missing albums from all Spotify playlists
  Future<Map<String, dynamic>> getAggregatedMissingAlbums() async {
    final response = await _get('$baseUrl/missing-albums');
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to load missing albums');
  }

  // Re-link missing playlist songs to library tracks
  Future<Map<String, dynamic>> relinkMissingPlaylistSongs() async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/playlists/relink-missing'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to relink missing songs');
  }

  // Search library for a song by title
  Future<Map<String, dynamic>> searchLibrarySong(
    String title, {
    String? artist,
    String? album,
  }) async {
    String url =
        '$baseUrl/library/search-song?title=${Uri.encodeComponent(title)}';
    if (artist != null && artist.isNotEmpty) {
      url += '&artist=${Uri.encodeComponent(artist)}';
    }
    if (album != null && album.isNotEmpty) {
      url += '&album=${Uri.encodeComponent(album)}';
    }
    final response = await _get(url);
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to search library');
  }

  // Manually link a playlist song to a library song
  Future<Map<String, dynamic>> linkPlaylistSongToLibrary({
    required String spotifyArtist,
    required String spotifyTrack,
    String? spotifyAlbum,
    required int librarySongId,
  }) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/playlist-song/link'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'spotify_artist': spotifyArtist,
        'spotify_track': spotifyTrack,
        if (spotifyAlbum != null) 'spotify_album': spotifyAlbum,
        'library_song_id': librarySongId,
      }),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    final error = json.decode(response.body);
    throw Exception(error['error'] ?? 'Failed to link song');
  }

  // Search artists by name
  Future<List<Map<String, dynamic>>> searchArtists(String query) async {
    if (query.length < 2) return [];

    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/artists/search?q=${Uri.encodeComponent(query)}'),
    );

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.cast<Map<String, dynamic>>();
    } else {
      throw Exception('Failed to search artists');
    }
  }

  // Change album artist
  Future<Map<String, dynamic>> editAlbumArtist(
    int albumId,
    dynamic artistId, {
    bool updateSongArtists = false,
  }) async {
    final response = await appHttpClient.put(
      Uri.parse('$baseUrl/edit/album/$albumId/artist'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'artist_id': artistId,
        'update_song_artists': updateSongArtists,
      }),
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to change album artist: ${response.body}');
    }
  }

  // ==========================================================================
  // PROWLARR / TRANSMISSION
  // ==========================================================================

  // Search Prowlarr indexers
  Future<Map<String, dynamic>> searchProwlarr(String query, {bool deep = false, bool deepOnly = false}) async {
    final extraParam = deepOnly ? '&deep_only=true' : (deep ? '&deep=true' : '');
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/prowlarr/search?query=${Uri.encodeComponent(query)}$extraParam'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    // Surface the actual error from the backend
    try {
      final body = json.decode(response.body);
      throw Exception(body['error'] ?? 'Search failed (${response.statusCode})');
    } catch (e) {
      if (e is Exception && e.toString().contains('Search failed')) rethrow;
      throw Exception('Search failed (${response.statusCode})');
    }
  }

  // Get Prowlarr indexers
  Future<Map<String, dynamic>> getProwlarrIndexers() async {
    final response = await _get('$baseUrl/prowlarr/indexers');
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to get indexers');
  }

  // Add torrent to Transmission
  Future<Map<String, dynamic>> addTorrent(String url) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/transmission/add'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'url': url}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    // Parse the backend's error detail out of the response body
    // instead of throwing a useless generic message. The backend
    // includes `error` on 4xx/5xx responses — "Failed to fetch
    // torrent: …", "Indexer error", RPC error strings, etc. —
    // which the user actually needs to fix the underlying problem.
    String detail = 'HTTP ${response.statusCode}';
    try {
      final body = json.decode(response.body);
      if (body is Map && body['error'] is String) {
        detail = body['error'] as String;
      }
    } catch (_) {
      // Body wasn't JSON — fall back to the raw status code.
    }
    throw Exception('Failed to add torrent: $detail');
  }

  // Get Transmission torrents
  // Ask the backend to scrape a torrent's trackers right now. Indexer
  // seeder counts are stale scrapes; this returns the real max-across-
  // trackers count plus a verdict (alive / dead / unknown).
  Future<Map<String, dynamic>> probeTorrent(String url) async {
    final response = await appHttpClient
        .post(
          Uri.parse('$baseUrl/transmission/probe'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({'url': url}),
        )
        .timeout(const Duration(seconds: 45));
    final body = json.decode(response.body);
    if (response.statusCode == 200 && body is Map<String, dynamic>) {
      return body;
    }
    throw Exception(
      (body is Map && body['error'] is String)
          ? body['error'] as String
          : 'Probe failed (HTTP ${response.statusCode})',
    );
  }

  /// Skip on a headless (backend-driven) cast. The backend owns that queue,
  /// so the phone asks it to jump rather than LOADing anything itself.
  Future<void> castJump({required bool next}) async {
    final response = await appHttpClient
        .post(
          Uri.parse('$baseUrl/cast/${next ? "next" : "previous"}'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({}),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      String detail = 'HTTP ${response.statusCode}';
      try {
        final body = json.decode(response.body);
        if (body is Map && body['error'] is String) detail = body['error'];
      } catch (_) {}
      throw Exception('Cast ${next ? "next" : "previous"} failed: $detail');
    }
  }

  Future<Map<String, dynamic>> getTransmissionTorrents() async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/transmission/torrents'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to get torrents');
  }

  // Check if albums exist in library
  Future<Map<String, dynamic>> checkLibraryExists(List<String> queries) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/library/check-exists'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'queries': queries}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to check library');
  }

  // Stop a torrent
  Future<Map<String, dynamic>> stopTorrent(int torrentId) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/transmission/stop/$torrentId'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to stop torrent');
  }

  // Remove a torrent
  Future<Map<String, dynamic>> removeTorrent(
    int torrentId, {
    bool deleteData = false,
  }) async {
    final response = await appHttpClient.delete(
      Uri.parse(
        '$baseUrl/transmission/remove/$torrentId?delete_data=$deleteData',
      ),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to remove torrent');
  }

  // Check for duplicates in import queue
  Future<Map<String, dynamic>> checkImportDuplicates(
    List<Map<String, dynamic>> folders,
  ) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/imports/check-duplicates'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'folders': folders}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to check duplicates');
  }

  // Bulk delete import folders
  Future<Map<String, dynamic>> bulkDeleteImportFolders(
    List<String> paths,
  ) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/imports/bulk-delete'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'paths': paths}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to bulk delete');
  }

  // Parse CUE file
  Future<Map<String, dynamic>> parseCueFile(
    String folderPath, {
    String? cueFile,
  }) async {
    final body = <String, dynamic>{'path': folderPath};
    if (cueFile != null) {
      body['cue_file'] = cueFile;
    }
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/imports/parse-cue'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    final error = json.decode(response.body);
    throw Exception(error['error'] ?? 'Failed to parse CUE file');
  }

  // Split CUE file
  Future<Map<String, dynamic>> splitCueFile(String folderPath) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/imports/split-cue'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'path': folderPath}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    // Handle non-JSON error responses (e.g. HTML error pages from server errors)
    try {
      final error = json.decode(response.body);
      throw Exception(error['error'] ?? 'Failed to split CUE file (${response.statusCode})');
    } catch (e) {
      if (e is Exception && e.toString().contains('Failed to split')) rethrow;
      throw Exception('Server error (${response.statusCode}). Check backend logs for details.');
    }
  }

  Future<void> cancelCueSplit() async {
    await appHttpClient.post(
      Uri.parse('$baseUrl/imports/cancel-cue-split'),
      headers: {'Content-Type': 'application/json'},
    );
  }

  // Analyze a folder for splitting into disc folders
  Future<Map<String, dynamic>> analyzeImportSplit(String folderPath) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/imports/analyze-split'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'path': folderPath}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    final error = json.decode(response.body);
    throw Exception(error['error'] ?? 'Failed to analyze folder');
  }

  // Perform the split - move files into disc folders
  Future<Map<String, dynamic>> performImportSplit(
    String basePath,
    List<Map<String, dynamic>> folders,
  ) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/imports/perform-split'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'path': basePath, 'folders': folders}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    final error = json.decode(response.body);
    throw Exception(error['error'] ?? 'Failed to split folder');
  }

  // Move a subfolder up one level with optional rename
  Future<Map<String, dynamic>> moveFolderUp(
    String folderPath, {
    String? newName,
  }) async {
    final body = <String, dynamic>{'folder_path': folderPath};
    if (newName != null) {
      body['new_name'] = newName;
    }
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/imports/move-folder-up'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    final error = json.decode(response.body);
    throw Exception(error['error'] ?? 'Failed to move folder');
  }

  // List subfolders within an import folder
  Future<Map<String, dynamic>> listImportSubfolders(String basePath) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/imports/list-subfolders'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'path': basePath}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    final error = json.decode(response.body);
    throw Exception(error['error'] ?? 'Failed to list subfolders');
  }

  // Rename subfolders within an import folder
  Future<Map<String, dynamic>> renameImportSubfolders(
    String basePath,
    List<Map<String, String>> renames,
  ) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/imports/rename-subfolders'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'path': basePath, 'renames': renames}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    final error = json.decode(response.body);
    throw Exception(error['error'] ?? 'Failed to rename subfolders');
  }

  // Delete import folder
  Future<Map<String, dynamic>> deleteImportFolder(String path) async {
    final response = await appHttpClient.delete(
      Uri.parse('$baseUrl/imports/folder'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'path': path}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to delete folder');
  }

  // Import album
  Future<Map<String, dynamic>> importAlbum({
    required String sourcePath,
    required String artistName,
    required String albumTitle,
    int? year,
    String? artistMbid,
    String? albumMbid,
    List<String>? selectedFiles,
    int? attachToAlbumId,
    String? editionLabel,
  }) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/imports/import'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'source_path': sourcePath,
        'artist_name': artistName,
        'album_title': albumTitle,
        'year': year,
        'artist_mbid': artistMbid,
        'album_mbid': albumMbid,
        if (selectedFiles != null) 'selected_files': selectedFiles,
        if (attachToAlbumId != null) 'attach_to_album_id': attachToAlbumId,
        if (editionLabel != null) 'edition_label': editionLabel,
      }),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    final error = json.decode(response.body);
    throw Exception(error['error'] ?? 'Failed to import album');
  }

  // Get pending imports
  /// Push files picked on this device into the NASRadio downloads folder
  /// (a new subfolder named [folder]) so the normal import route can take
  /// them from there. Returns an /api/imports/pending-shaped entry.
  /// [onProgress] reports bytes sent so far against the total.
  Future<Map<String, dynamic>> uploadImportFiles({
    required String folder,
    required List<String> paths,
    void Function(int sent, int total)? onProgress,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/imports/upload'),
    );
    request.fields['folder'] = folder;
    int total = 0;
    int sent = 0;
    for (final path in paths) {
      final file = File(path);
      final length = await file.length();
      total += length;
      final counted = file.openRead().transform<List<int>>(
        StreamTransformer.fromHandlers(
          handleData: (chunk, sink) {
            sent += chunk.length;
            onProgress?.call(sent, total);
            sink.add(chunk);
          },
        ),
      );
      request.files.add(
        http.MultipartFile(
          'files',
          counted,
          length,
          filename: path.split(RegExp(r'[\\/]')).last,
        ),
      );
    }
    final streamed = await appHttpClient.send(request);
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    String detail = '';
    try {
      detail = json.decode(response.body)['error'] ?? '';
    } catch (_) {}
    throw Exception('Upload failed (${response.statusCode}) $detail');
  }

  Future<Map<String, dynamic>> getPendingImports() async {
    final response = await _get('$baseUrl/imports/pending');
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to get pending imports');
  }

  // Stop old seeders
  Future<Map<String, dynamic>> stopOldSeeders(int maxSeedMinutes) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/transmission/stop-old-seeders'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'max_seed_minutes': maxSeedMinutes}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to stop old seeders');
  }

  // Clear completed torrents from Transmission
  Future<Map<String, dynamic>> clearCompletedTorrents({
    bool deleteData = false,
  }) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/transmission/clear-completed'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'delete_data': deleteData}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to clear completed torrents');
  }

  // Get folder contents for import preview
  Future<Map<String, dynamic>> getFolderContents(String path) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/imports/folder-contents'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'path': path}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to get folder contents');
  }

  // Read metadata tags from audio files in import folder
  Future<Map<String, dynamic>> readFolderTags(String path) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/imports/read-tags'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'path': path}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to read tags');
  }

  Future<Map<String, dynamic>> getMusicBrainzTracks(
    String releaseGroupId,
  ) async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/musicbrainz/tracks/$releaseGroupId'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to get tracks: ${response.body}');
  }

  // Search albums by name
  Future<List<Album>> searchAlbums(String query) async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/albums/search?q=${Uri.encodeComponent(query)}'),
    );
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return (data['albums'] as List)
          .map((json) => Album.fromJson(json))
          .toList();
    }
    throw Exception('Failed to search albums');
  }

  // Mark albums as not duplicates of each other
  Future<void> markNotDuplicates(List<int> albumIds) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/not-duplicate-albums'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'album_ids': albumIds}),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to mark as not duplicates');
    }
  }

  Future<Map<String, dynamic>> splitBoxSet(int albumId) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/api/split-box-set/$albumId'),
      headers: {'Content-Type': 'application/json'},
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      final error = json.decode(response.body);
      throw Exception(error['error'] ?? 'Failed to split box set');
    }
  }

  Future<Map<int, String>> getDiscNames(int albumId) async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/album/$albumId/disc-names'),
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body) as Map<String, dynamic>;
      return data.map((k, v) => MapEntry(int.parse(k), v as String));
    }
    return {};
  }

  // ===================
  // YouTube Download API
  // ===================

  Future<Map<String, dynamic>> validateYouTubeUrl(String url) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/youtube/validate'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'url': url}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to validate URL');
  }

  Future<Map<String, dynamic>> getYouTubeInfo(String url) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/youtube/info'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'url': url}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to get video info');
  }

  // Check yt-dlp version and update availability
  Future<Map<String, dynamic>> getYtDlpVersion() async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/youtube/yt-dlp-version'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to check yt-dlp version');
  }

  // Update yt-dlp to latest version
  Future<Map<String, dynamic>> updateYtDlp() async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/youtube/yt-dlp-update'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to update yt-dlp');
  }

  // --- YouTube album search + curation (youtube_curate.py) ---

  /// Playlist-only YouTube search, so the album hunt happens in the app.
  Future<Map<String, dynamic>> searchYouTubeAlbums(String query) async {
    final response = await appHttpClient
        .post(
          Uri.parse('$baseUrl/youtube/search-albums'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({'query': query}),
        )
        .timeout(const Duration(seconds: 90));
    final body = json.decode(response.body);
    if (response.statusCode == 200 && body is Map<String, dynamic>) {
      return body;
    }
    throw Exception(
      (body is Map && body['error'] is String)
          ? body['error'] as String
          : 'Album search failed (HTTP ${response.statusCode})',
    );
  }

  /// Expand a playlist and grade every video against the album's
  /// MusicBrainz track lengths; suspects come back with a replacement
  /// (a Topic-channel upload of matching length) already picked.
  Future<Map<String, dynamic>> curateYouTubePlaylist(
    String url, {
    String? artist,
    String? album,
    int? tolerance,
  }) async {
    final response = await appHttpClient
        .post(
          Uri.parse('$baseUrl/youtube/curate-playlist'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'url': url,
            if (artist != null && artist.isNotEmpty) 'artist': artist,
            if (album != null && album.isNotEmpty) 'album': album,
            if (tolerance != null) 'tolerance': tolerance,
          }),
        )
        .timeout(const Duration(minutes: 4));
    final body = json.decode(response.body);
    if (response.statusCode == 200 && body is Map<String, dynamic>) {
      return body;
    }
    throw Exception(
      (body is Map && body['error'] is String)
          ? body['error'] as String
          : 'Playlist curation failed (HTTP ${response.statusCode})',
    );
  }

  /// Replacement candidates for one track (the alternatives sheet).
  Future<Map<String, dynamic>> findCleanYouTubeUpload({
    required String artist,
    required String title,
    int? targetDuration,
    String? excludeId,
  }) async {
    final response = await appHttpClient
        .post(
          Uri.parse('$baseUrl/youtube/find-clean'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'artist': artist,
            'title': title,
            if (targetDuration != null) 'target_duration': targetDuration,
            if (excludeId != null) 'exclude_id': excludeId,
          }),
        )
        .timeout(const Duration(seconds: 90));
    final body = json.decode(response.body);
    if (response.statusCode == 200 && body is Map<String, dynamic>) {
      return body;
    }
    throw Exception(
      (body is Map && body['error'] is String)
          ? body['error'] as String
          : 'Replacement search failed (HTTP ${response.statusCode})',
    );
  }

  Future<Map<String, dynamic>> getYouTubePlaylistInfo(String url) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/youtube/playlist-info'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'url': url}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to get playlist info');
  }

  /// Preview a YouTube video as a chapter-split album. Returns the video
  /// header (title/channel/duration/thumbnail) plus a chapter list sourced
  /// from native YouTube markers when present or parsed from the description
  /// timestamps otherwise. `chapter_source` is `'native'`, `'parsed'`, or
  /// `'none'`; on `'none'` the UI should offer single-track import instead.
  Future<Map<String, dynamic>> getYouTubeChapters(String url) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/youtube/preview-chapters'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'url': url}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to preview chapters: ${response.statusCode}');
  }

  /// Download a YouTube video, split it into tracks by [chapters], and
  /// import as a single album. [chapters] must be a list of maps with at
  /// minimum {start_seconds, title}; entries with skip=true are excluded.
  /// [album] requires {title, artist} and optionally {year}. When [albumId]
  /// is non-null the songs are routed into that existing album (folder +
  /// album_id reused; existing cover preserved). Progress is reported on
  /// the existing `youtube_progress` websocket keyed by [operationId];
  /// cancel via [cancelYouTubeDownload(operationId)].
  Future<Map<String, dynamic>> importYouTubeAsAlbum({
    required String url,
    required List<Map<String, dynamic>> chapters,
    required Map<String, dynamic> album,
    String? operationId,
    int? albumId,
  }) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/youtube/import-as-album'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'url': url,
        'chapters': chapters,
        'album': album,
        'operation_id': operationId,
        if (albumId != null) 'album_id': albumId,
      }),
    );
    final body = json.decode(response.body);
    if (response.statusCode == 200) {
      return body;
    }
    // Surface the backend error message rather than a generic string —
    // matches the importYouTubeDownload pattern above.
    final err = (body is Map ? body['error'] : null) ?? 'Import failed';
    throw Exception(err.toString());
  }

  Future<Map<String, dynamic>> downloadYouTube(
    String url, {
    String? operationId,
  }) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/youtube/download'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'url': url, 'operation_id': operationId}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to download');
  }

  Future<Map<String, dynamic>> downloadYouTubePlaylist(
    String url, {
    String? operationId,
  }) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/youtube/download-playlist'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'url': url, 'operation_id': operationId}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to download playlist');
  }

  Future<Map<String, dynamic>> tagYouTubeDownload(
    String filename,
    Map<String, dynamic> tags,
  ) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/youtube/tag'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'filename': filename, 'tags': tags}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to apply tags');
  }

  Future<Map<String, dynamic>> importYouTubeDownload(
    String filename,
    String artistName,
    String albumName, {
    int? albumId,
  }) async {
    final body = <String, dynamic>{
      'filename': filename,
      'artist_name': artistName,
      'album_name': albumName,
    };
    if (albumId != null) {
      body['album_id'] = albumId;
    }
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/youtube/import'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    // Surface the backend's actual error if present. The previous hardcoded
    // 'Failed to import' message hid useful diagnostics — e.g., during the
    // 2026-05-22 Sammy Hagar incident the backend was returning a 404 with
    // "Album directory not found: \\nas\Music\..." but the UI
    // only showed the generic message.
    String detail = 'Failed to import (HTTP ${response.statusCode})';
    try {
      final body = json.decode(response.body);
      if (body is Map && body['error'] is String) {
        detail = body['error'] as String;
      }
    } catch (_) {
      // Body wasn't JSON — keep the generic message with status code.
    }
    throw Exception(detail);
  }

  Future<Map<String, dynamic>> getYouTubeStaging() async {
    final response = await _get('$baseUrl/youtube/staging');
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to get staging files');
  }

  Future<void> deleteYouTubeStagingFile(String filename) async {
    final response = await appHttpClient.delete(
      Uri.parse('$baseUrl/youtube/staging/$filename'),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to delete staging file');
    }
  }

  Future<void> clearYouTubeStaging() async {
    final response = await appHttpClient.delete(
      Uri.parse('$baseUrl/youtube/staging/clear'),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to clear staging');
    }
  }

  // Read CUE file contents
  Future<Map<String, dynamic>> readCueContents(String path) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/imports/read-cue'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'path': path}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to read CUE file');
  }

  // Set local image as album artwork
  Future<Map<String, dynamic>> setLocalArtwork(
    int albumId,
    String filename,
  ) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/album/$albumId/set-local-artwork'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'filename': filename}),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to set artwork');
  }

  // Mark playlist as played
  Future<void> markPlaylistPlayed(int playlistId) async {
    await _post('$baseUrl/playlist/$playlistId/played');
  }

  // Toggle playlist pin
  Future<bool> togglePlaylistPin(int playlistId) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/playlist/$playlistId/pin'),
    );
    if (response.statusCode == 200) {
      return json.decode(response.body)['pinned'] ?? false;
    }
    return false;
  }

  Future<Map<String, dynamic>> cancelYouTubeDownload(String operationId) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/youtube/cancel'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'operation_id': operationId}),
    );
    return jsonDecode(response.body);
  }

  /// List YouTube download jobs the backend is currently tracking
  /// (running + recently finished, within the server-side retire
  /// grace window). Used by YouTubeDownloadScreen on open to rejoin a
  /// job the user navigated away from.
  Future<List<Map<String, dynamic>>> getActiveYouTubeJobs() async {
    try {
      final response = await _get('$baseUrl/youtube/active-jobs');
      if (response.statusCode != 200) return [];
      final data = jsonDecode(response.body);
      final raw = data['jobs'];
      if (raw is List) {
        return raw
            .whereType<Map>()
            .map((j) => Map<String, dynamic>.from(j))
            .toList();
      }
    } catch (_) {
      // Non-fatal — screen behaves like there's no active job.
    }
    return [];
  }

  // What's Happening - upcoming/recent releases
  Future<Map<String, dynamic>> getWhatsHappening() async {
    final response = await _get('$baseUrl/whats-happening');
    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to load releases');
    }
  }

  Future<Map<String, dynamic>> refreshWhatsHappening() async {
    final response = await _post(
      '$baseUrl/whats-happening/refresh',
      headers: {'Content-Type': 'application/json'},
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to refresh releases');
    }
  }

  // --- Last.fm integration ---

  Future<Map<String, dynamic>> getLastfmStatus() async {
    final response = await _get('$baseUrl/lastfm/status');
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to get Last.fm status');
  }

  // Profile totals + top artists/tracks (by period) + recent scrobbles.
  // period: 7day | 1month | 3month | 6month | 12month | overall
  Future<Map<String, dynamic>> getLastfmStats({String period = 'overall'}) async {
    final response = await _get('$baseUrl/lastfm/stats?period=$period')
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to get Last.fm stats (${response.statusCode})');
  }

  Future<Map<String, dynamic>> configureLastfm(String apiKey, String apiSecret) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/lastfm/configure'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'api_key': apiKey, 'api_secret': apiSecret}),
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode == 200) {
      return json.decode(response.body);
    }
    throw Exception('Failed to configure Last.fm');
  }

  Future<String?> getLastfmAuthUrl() async {
    final response = await _get('$baseUrl/lastfm/auth-url');
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return data['url'];
    }
    return null;
  }

  Future<Map<String, dynamic>> completeLastfmAuth() async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/lastfm/callback'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({}),
    ).timeout(const Duration(seconds: 15));
    return json.decode(response.body);
  }

  Future<void> toggleLastfmScrobbling(bool enabled) async {
    await appHttpClient.post(
      Uri.parse('$baseUrl/lastfm/toggle'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'enabled': enabled}),
    ).timeout(const Duration(seconds: 15));
  }

  Future<void> disconnectLastfm() async {
    await appHttpClient.post(
      Uri.parse('$baseUrl/lastfm/disconnect'),
    ).timeout(const Duration(seconds: 15));
  }

  Future<http.Response> _get(String url) async {
    return await appHttpClient
        .get(Uri.parse(url))
        .timeout(
          const Duration(seconds: 60),
          onTimeout: () {
            throw TimeoutException('Request to $url timed out');
          },
        );
  }

  /// Live now-playing track for a radio station (the backend polls the
  /// broadcaster out-of-band). Returns {title, artist, artwork_url, source,
  /// is_live}, or {} on any error — callers treat an empty map as "no data,
  /// just show the station name".
  Future<Map<String, dynamic>> getStationNowPlaying(int stationId) async {
    try {
      final response = await _get('$baseUrl/stations/$stationId/now-playing');
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {
      // Polling is best-effort; a failed tick keeps the last known track.
    }
    return {};
  }

  /// Play history for a radio station, newest first. Each row is
  /// {title, artist, played_at, artwork_url, source, song_id} where song_id
  /// is non-null when the track fuzzy-matched the local library. Empty list
  /// means the broadcaster doesn't publish history (or the fetch failed —
  /// the history view is best-effort like now-playing).
  Future<List<Map<String, dynamic>>> getStationRecentlyPlayed(
    int stationId,
  ) async {
    try {
      final response =
          await _get('$baseUrl/stations/$stationId/recently-played');
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        return (data['tracks'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    return [];
  }

  Future<http.Response> _post(
    String url, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    return await appHttpClient
        .post(Uri.parse(url), headers: headers, body: body)
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw TimeoutException('Request timed out'),
        );
  }

  // ========================================================================
  // RSS Podcast Feeds
  // ========================================================================

  Future<Map<String, dynamic>> addRssFeed(String url) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/rss/feeds'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'url': url}),
    );
    return json.decode(response.body);
  }

  Future<List<dynamic>> getRssFeeds() async {
    final response = await appHttpClient.get(Uri.parse('$baseUrl/rss/feeds'));
    final data = json.decode(response.body);
    return data['feeds'] ?? [];
  }

  Future<Map<String, dynamic>> getRssFeed(int feedId) async {
    final response = await appHttpClient.get(Uri.parse('$baseUrl/rss/feeds/$feedId'));
    return json.decode(response.body);
  }

  Future<void> deleteRssFeed(int feedId) async {
    await appHttpClient.delete(Uri.parse('$baseUrl/rss/feeds/$feedId'));
  }

  /// Fetch chapters for a song. Returns an empty list on network error
  /// or if the song has no chapters. First call on a podcast song may
  /// take a few seconds — the backend primes the cache by parsing ID3
  /// CHAP frames from the MP3. Subsequent calls are fast.
  Future<List<Map<String, dynamic>>> getSongChapters(int songId) async {
    try {
      final response = await appHttpClient.get(
        Uri.parse('$baseUrl/songs/$songId/chapters'),
      ).timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) return const [];
      final data = json.decode(response.body) as Map<String, dynamic>;
      final list = data['chapters'];
      if (list is! List) return const [];
      return list.cast<Map<String, dynamic>>();
    } catch (e) {
      AppLogger.instance.warning('getSongChapters($songId) failed: $e');
      return const [];
    }
  }

  /// Return the "current" episode in a feed — the most-recently-progressed
  /// non-completed one — or null if the feed has nothing in progress.
  /// Used by restore/resume paths to redirect off a stale completed
  /// episode onto whatever the user has actually moved on to.
  Future<Map<String, dynamic>?> getFeedCurrentEpisode(int feedId) async {
    try {
      final response = await appHttpClient
          .get(Uri.parse('$baseUrl/rss/feeds/$feedId/current-episode'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        if (data['exists'] == true && data['episode'] is Map) {
          return Map<String, dynamic>.from(data['episode']);
        }
      }
      return null;
    } catch (e) {
      AppLogger.instance.warning('getFeedCurrentEpisode($feedId) failed: $e');
      return null;
    }
  }

  /// Fetch chapters for a podcast episode by RssEpisode.id. Backend resolves
  /// to the songs row internally. Use this from the podcast playback path
  /// where the current Song is a virtual one with a negative song.id.
  Future<List<Map<String, dynamic>>> getEpisodeChapters(int episodeId) async {
    try {
      final response = await appHttpClient.get(
        Uri.parse('$baseUrl/rss/episodes/$episodeId/chapters'),
      ).timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) return const [];
      final data = json.decode(response.body) as Map<String, dynamic>;
      final list = data['chapters'];
      if (list is! List) return const [];
      return list.cast<Map<String, dynamic>>();
    } catch (e) {
      AppLogger.instance.warning('getEpisodeChapters($episodeId) failed: $e');
      return const [];
    }
  }

  Future<void> updateRssFeed(
    int feedId, {
    bool? autoDownload,
    String? playOrder, // 'newest_first' | 'oldest_first'
    int? introSkipSeconds, // 0 = disable
    int? outroSkipSeconds, // 0 = disable
    int? retentionDays, // 0 = keep forever
  }) async {
    final body = <String, dynamic>{};
    if (autoDownload != null) body['auto_download'] = autoDownload;
    if (playOrder != null) body['play_order'] = playOrder;
    if (introSkipSeconds != null) body['intro_skip_seconds'] = introSkipSeconds;
    if (outroSkipSeconds != null) body['outro_skip_seconds'] = outroSkipSeconds;
    if (retentionDays != null) body['retention_days'] = retentionDays;
    await appHttpClient.put(
      Uri.parse('$baseUrl/rss/feeds/$feedId'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );
  }

  Future<Map<String, dynamic>> refreshRssFeed(int feedId) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/rss/feeds/$feedId/refresh'),
      headers: {'Content-Type': 'application/json'},
    );
    return json.decode(response.body);
  }

  /// Mark every unplayed episode in a feed as completed. Returns the
  /// number of rows actually updated.
  Future<int> markAllEpisodesPlayed(int feedId) async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/rss/feeds/$feedId/mark-all-played'),
      headers: {'Content-Type': 'application/json'},
    );
    if (response.statusCode != 200) return 0;
    final data = json.decode(response.body) as Map<String, dynamic>;
    return (data['marked'] as num?)?.toInt() ?? 0;
  }

  Future<Map<String, dynamic>> refreshAllRssFeeds() async {
    final response = await appHttpClient.post(
      Uri.parse('$baseUrl/rss/feeds/refresh-all'),
      headers: {'Content-Type': 'application/json'},
    );
    return json.decode(response.body);
  }

  Future<Map<String, dynamic>> getRssEpisodes(
    int feedId, {
    int page = 1,
    int perPage = 50,
    String sort = 'desc',
    String? search,
  }) async {
    final params = <String, String>{
      'page': page.toString(),
      'per_page': perPage.toString(),
      'sort': sort,
    };
    if (search != null && search.isNotEmpty) {
      params['search'] = search;
    }
    final uri = Uri.parse('$baseUrl/rss/feeds/$feedId/episodes')
        .replace(queryParameters: params);
    final response = await appHttpClient.get(uri);
    return json.decode(response.body);
  }

  Future<Map<String, dynamic>> getRssEpisode(int episodeId) async {
    final response = await appHttpClient.get(Uri.parse('$baseUrl/rss/episodes/$episodeId'));
    return json.decode(response.body);
  }

  Future<void> updateEpisodeProgress(int episodeId, int position, {bool? isCompleted}) async {
    final body = <String, dynamic>{'position': position};
    if (isCompleted != null) body['is_completed'] = isCompleted;
    await appHttpClient.put(
      Uri.parse('$baseUrl/rss/episodes/$episodeId/progress'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );
  }

  Future<void> downloadEpisode(int episodeId) async {
    await appHttpClient.post(
      Uri.parse('$baseUrl/rss/episodes/$episodeId/download'),
      headers: {'Content-Type': 'application/json'},
    );
  }

  String getRssStreamUrl(int episodeId) =>
      _withMediaToken('$baseUrl/rss/stream/$episodeId');

  // ─── Podcast Discovery ───────────────────────

  Future<List<dynamic>> getPodcastTrending({int max = 20, String? category}) async {
    var url = '$baseUrl/podcasts/trending?max=$max';
    if (category != null) url += '&cat=$category';
    final response = await appHttpClient.get(Uri.parse(url));
    final data = json.decode(response.body);
    return data['feeds'] ?? [];
  }

  Future<List<dynamic>> searchPodcasts(String query, {int max = 20}) async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/podcasts/search?q=${Uri.encodeQueryComponent(query)}&max=$max'),
    );
    final data = json.decode(response.body);
    return data['feeds'] ?? [];
  }

  Future<List<dynamic>> getPodcastCategories() async {
    final response = await appHttpClient.get(Uri.parse('$baseUrl/podcasts/categories'));
    final data = json.decode(response.body);
    return data['categories'] ?? [];
  }

  Future<List<dynamic>> getSimilarPodcasts(String title, {int n = 10}) async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/podcasts/similar?title=${Uri.encodeQueryComponent(title)}&n=$n'),
    ).timeout(const Duration(seconds: 30));
    final data = json.decode(response.body);
    return data['feeds'] ?? [];
  }

  Future<Map<String, dynamic>> getPodcastRating(String title) async {
    final response = await appHttpClient.get(
      Uri.parse('$baseUrl/podcasts/rating?title=${Uri.encodeQueryComponent(title)}'),
    ).timeout(const Duration(seconds: 15));
    return json.decode(response.body);
  }

  Future<Map<String, dynamic>> getRecommenderStatus() async {
    final response = await appHttpClient.get(Uri.parse('$baseUrl/podcasts/recommender-status'));
    return json.decode(response.body);
  }

  Future<Map<String, dynamic>> getPodcastRecommendations() async {
    final response = await appHttpClient.get(Uri.parse('$baseUrl/podcasts/recommendations'));
    return json.decode(response.body);
  }

  Future<List<Map<String, dynamic>>> getRecentEpisodes({int limit = 20}) async {
    final response = await appHttpClient.get(Uri.parse('$baseUrl/rss/recent-episodes?limit=$limit'));
    final data = json.decode(response.body);
    return List<Map<String, dynamic>>.from(data['episodes'] ?? []);
  }

  Future<List<Map<String, dynamic>>> getRecentlyPlayedEpisodes({int limit = 20}) async {
    final response = await appHttpClient.get(Uri.parse('$baseUrl/rss/recently-played?limit=$limit'));
    final data = json.decode(response.body);
    return List<Map<String, dynamic>>.from(data['episodes'] ?? []);
  }
}
