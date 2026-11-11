import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import 'api_service.dart';
import 'app_logger.dart';
import 'audio_player_service.dart';

/// Offline listening (Android), so a dead zone on the road isn't silence.
///
/// * Downloads: playlists and albums you pick, kept until you remove them.
///   A downloaded playlist re-syncs (new songs download, removed ones go) at
///   start-up and every 30 minutes.
/// * Rolling cache: the next hour of the queue is pre-loaded, and songs you
///   played are KEPT (oldest dropped first past [cacheCapBytes], ~3-4 hours)
///   so you can go back and replay something with no signal.
/// * The player asks [localFileFor] before streaming; a local copy wins.
///
/// Downloads use [downloadFormat] (Opus 160 by default: ~4.8 MB a song, half
/// of AAC 320). The cache uses AAC 320, which the server has pre-made for
/// most of the library, so pre-loading never waits on a conversion.
/// Everything lives in the app's private storage under offline/.
class OfflineService extends ChangeNotifier {
  OfflineService._();
  static final OfflineService instance = OfflineService._();

  // ---------------------------------------------------------------- settings
  static const _kPreload = 'offline_preload';
  static const _kCellular = 'offline_cellular';
  static const _kFormat = 'offline_format';
  static const _kCapGb = 'offline_cap_gb';

  bool preloadEnabled = true;
  bool useCellular = true;
  String downloadFormat = 'opus160'; // opus160 | high | lossless
  int capGb = 20;

  static const cacheCapBytes = 600 * 1024 * 1024;
  static const _cacheQuality = 'high';
  static const _lookAhead = Duration(minutes: 60);
  static const _maxParallel = 2;
  static const _gb = 1024 * 1024 * 1024;
  // Speed caps. Unpaced, 24 pre-loads went back to back at full Wi-Fi
  // speed on Nov 9: the phone's UI stalled (shuffle didn't toggle) and the
  // server answered everything else in ~2 s. An hour of music is ~145 MB,
  // so 3 MB/s still has it within a minute.
  static const _cacheRate = 3 * 1024 * 1024;
  static const _downloadRate = 8 * 1024 * 1024;

  // ---------------------------------------------------------------- state
  final ApiService _api = ApiService();
  AudioPlayerService? _player;
  Directory? _root;
  bool _ready = false;
  bool get isReady => _ready;

  final Map<int, _OfflineFile> _downloads = {};
  final Map<int, _OfflineFile> _cache = {};
  final Map<String, OfflineCollection> _collections = {};

  final List<_Job> _jobs = [];
  // Downloads held back by the storage cap. Kept apart so a full cap never
  // stalls the pre-load (the next hour on the road matters more).
  final List<_Job> _parked = [];
  final Set<String> _queued = {};
  int _running = 0;
  int _runningCache = 0; // pre-loads run one at a time
  bool _waiting = false; // no usable network / server busy: retry timer set
  Set<int> _protected = {}; // upcoming songs the cache must not evict
  String _lastPreloadKey = '';
  Timer? _syncTimer;
  Timer? _saveTimer;
  Timer? _retryTimer;

  /// Why downloads are stalled, for Settings (null = fine).
  String? problem;

  int get downloadBytes => _downloads.values.fold(0, (a, f) => a + f.bytes);
  int get cacheBytes => _cache.values.fold(0, (a, f) => a + f.bytes);
  int get downloadedSongCount => _downloads.length;
  List<OfflineCollection> get collections => _collections.values.toList();

  // ---------------------------------------------------------------- start-up
  Future<void> init(AudioPlayerService player) async {
    if (_ready) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      preloadEnabled = prefs.getBool(_kPreload) ?? true;
      useCellular = prefs.getBool(_kCellular) ?? true;
      downloadFormat = prefs.getString(_kFormat) ?? 'opus160';
      capGb = prefs.getInt(_kCapGb) ?? 20;

      final support = await getApplicationSupportDirectory();
      _root = Directory('${support.path}/offline');
      await Directory('${_root!.path}/downloads').create(recursive: true);
      await Directory('${_root!.path}/cache').create(recursive: true);
      await _load();
      _ready = true;
      _player = player;
      player.addListener(_onPlayerChanged);
      _syncTimer = Timer.periodic(const Duration(minutes: 30), (_) => sync());
      AppLogger.instance.info(
          '⬇️ [offline] ready: ${_downloads.length} downloaded songs '
          '(${_mb(downloadBytes)}), cache ${_cache.length} (${_mb(cacheBytes)}), '
          '${_collections.length} collections');
      notifyListeners();
      unawaited(sync());
      _onPlayerChanged();
    } catch (e) {
      AppLogger.instance.info('⬇️ [offline] init failed: $e');
    }
  }

  // ---------------------------------------------------------------- player
  /// A local file for [song] (download first, then cache), or null.
  String? localFileFor(Song song) {
    if (!_ready || song.isStation) return null;
    final d = _downloads[song.id];
    if (d != null) {
      final path = _pathOf('downloads', d);
      if (File(path).existsSync()) return path;
      _downloads.remove(song.id);
      _scheduleSave();
    }
    final c = _cache[song.id];
    if (c != null) {
      final path = _pathOf('cache', c);
      if (File(path).existsSync()) {
        c.used = DateTime.now().millisecondsSinceEpoch; // played = keep longer
        _scheduleSave();
        return path;
      }
      _cache.remove(song.id);
      _scheduleSave();
    }
    return null;
  }

  /// Pre-load: keep the next hour of the queue (from the current song) on
  /// the phone. Runs on every player notification, but only does work when
  /// the queue or the position in it changed.
  void _onPlayerChanged() {
    final p = _player;
    if (!_ready || p == null || !preloadEnabled) return;
    final q = p.queue;
    final i = p.currentIndex;
    if (q.isEmpty || i < 0 || i >= q.length) return;
    final key = '${identityHashCode(q)}:$i:${q.length}:${q[i].id}';
    if (key == _lastPreloadKey) return;
    _lastPreloadKey = key;

    final upcoming = <int>{};
    final fresh = <_Job>[];
    _Job? playingNow;
    var ahead = Duration.zero;
    for (var k = i; k < q.length && ahead < _lookAhead; k++) {
      final s = q[k];
      if (s.isStation) continue;
      if (s.isPodcast && k != i) break; // just the episode you're in
      upcoming.add(s.id);
      ahead += Duration(seconds: s.duration > 0 ? s.duration : 240);
      if (_downloads.containsKey(s.id) || _cache.containsKey(s.id)) continue;
      final job = _Job(s, forCache: true);
      if (_queued.contains(job.key)) continue;
      if (k == i && !s.isPodcast) {
        playingNow = job; // already streaming: fetch it last (for replays)
      } else {
        fresh.add(job); // in play order: the next song first
      }
    }
    if (playingNow != null) fresh.add(playingNow);
    // A new queue (or a jump) drops pre-loads for songs no longer coming up;
    // a restored queue followed by a new playlist used to fetch an hour of
    // both.
    _jobs.removeWhere((j) {
      final stale = j.forCache && !upcoming.contains(j.song.id);
      if (stale) _queued.remove(j.key);
      return stale;
    });
    for (final j in fresh) {
      _queued.add(j.key);
    }
    _jobs.insertAll(0, fresh);
    _protected = upcoming;
    _pump();
  }

  // ---------------------------------------------------------------- downloads
  OfflineCollection? collection(String key) => _collections[key];

  static String keyFor(String kind, int id) => switch (kind) {
        'album' => 'al:$id',
        'episode' => 'ep:$id',
        _ => 'pl:$id',
      };

  // ---------------------------------------------------------------- offline browsing
  // What the car / phone show when the server can't be reached.

  /// The last server copy of a song list (car's Favorites, Most Played):
  /// ids only. Offline, the ones on the phone are shown.
  final Map<String, List<int>> _lists = {};

  bool hasLocal(int songId) =>
      _downloads.containsKey(songId) || _cache.containsKey(songId);

  Song? _songFor(int id) {
    final f = _downloads[id] ?? _cache[id];
    if (f == null || f.song.isEmpty) return null;
    try {
      return Song.fromJson(f.song);
    } catch (_) {
      return null;
    }
  }

  int _usedOf(int id) {
    final a = _downloads[id]?.used ?? 0;
    final b = _cache[id]?.used ?? 0;
    return a > b ? a : b;
  }

  /// Every song with a local copy (downloads + cache), most recently played
  /// first.
  List<Song> localSongs() {
    final ids = {..._downloads.keys, ..._cache.keys}.toList()
      ..sort((a, b) => _usedOf(b).compareTo(_usedOf(a)));
    return [
      for (final id in ids)
        if (_songFor(id) case final s?) s,
    ];
  }

  void rememberList(String key, List<Song> songs) {
    final ids = songs.map((s) => s.id).toList();
    if (listEquals(_lists[key], ids)) return;
    _lists[key] = ids;
    _scheduleSave();
  }

  /// A remembered list, only the songs on the phone, in the list's order.
  List<Song> rememberedLocal(String key) => [
        for (final id in _lists[key] ?? const <int>[])
          if (hasLocal(id))
            if (_songFor(id) case final s?) s,
      ];

  /// A downloaded playlist's / album's songs that are on the phone, in order.
  List<Song> collectionSongs(String kind, int id) {
    final c = _collections[keyFor(kind, id)];
    if (c == null) return [];
    return [
      for (final sid in c.songIds)
        if (_downloads.containsKey(sid))
          if (_songFor(sid) case final s?) s,
    ];
  }

  /// Downloads of one kind ('playlist' / 'album' / 'episode'), by name.
  List<OfflineCollection> collectionsOf(String kind) =>
      _collections.values.where((c) => c.kind == kind).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  /// Download one podcast episode, kept until removed. [song] is the
  /// player's Song for it (id = -episodeId, streamed from the backend's
  /// podcast proxy); [episode] is its server row, kept so the car can start
  /// it with no signal.
  Future<void> downloadEpisode(Song song, Map<String, dynamic> episode) async {
    if (!_ready) return;
    final id = song.podcastEpisodeId ?? -song.id;
    final key = keyFor('episode', id);
    _collections.putIfAbsent(
        key,
        () => OfflineCollection(key, 'episode', id, song.title, [song.id], _now(),
            song: song.toJson(), extra: episode));
    _enqueue(_Job(song, forCache: false));
    _scheduleSave();
    notifyListeners();
    _pump();
    AppLogger.instance.info('⬇️ [offline] download episode "${song.title}"');
  }

  /// How far along a playlist / album download is.
  OfflineStatus statusOf(String kind, int id) {
    final c = _collections[keyFor(kind, id)];
    if (c == null) return const OfflineStatus(OfflineState.none, 0, 0);
    final done = c.songIds.where(_downloads.containsKey).length;
    final total = c.songIds.length;
    if (total > 0 && done >= total) {
      return OfflineStatus(OfflineState.done, done, total);
    }
    final active = c.songIds.any((id) => _queued.contains('d:$id'));
    return OfflineStatus(
        active && problem == null ? OfflineState.downloading : OfflineState.waiting,
        done,
        total);
  }

  Future<void> download(String kind, int id) async {
    if (!_ready) return;
    final key = keyFor(kind, id);
    final c = _collections.putIfAbsent(
        key, () => OfflineCollection(key, kind, id, '', [], _now()));
    notifyListeners();
    await _refresh(c);
    _scheduleSave();
    _pump();
    AppLogger.instance.info(
        '⬇️ [offline] download $kind "${c.name}" (${c.songIds.length} songs)');
  }

  /// Remove a playlist / album download (songs another download still uses
  /// stay).
  Future<void> remove(String kind, int id) async {
    final c = _collections.remove(keyFor(kind, id));
    if (c == null) return;
    bool orphan(_Job j) {
      final drop = !j.forCache && !_referenced(j.song.id);
      if (drop) _queued.remove(j.key);
      return drop;
    }
    _jobs.removeWhere(orphan);
    _parked.removeWhere(orphan);
    await _deleteUnreferenced();
    _unpark(); // space freed
    _scheduleSave();
    notifyListeners();
    AppLogger.instance.info('⬇️ [offline] removed $kind "${c.name}"');
  }

  /// Re-sync every download with the server (new songs in a playlist get
  /// downloaded, removed ones deleted). Offline = keep what we have.
  Future<void> sync() async {
    if (!_ready) return;
    var allOk = true;
    for (final c in _collections.values.toList()) {
      if (!await _refresh(c)) allOk = false;
    }
    if (allOk) await _deleteUnreferenced();
    _scheduleSave();
    _pump();
    notifyListeners();
  }

  Future<bool> _refresh(OfflineCollection c) async {
    if (c.kind == 'episode') {
      // Nothing to re-sync: just make sure it's (still) queued.
      if (!_downloads.containsKey(c.songIds.first) && c.song != null) {
        try {
          _enqueue(_Job(Song.fromJson(c.song!), forCache: false));
        } catch (_) {}
      }
      return true;
    }
    try {
      final List<Song> songs;
      if (c.kind == 'album') {
        final data = await _api.getAlbum(c.id);
        c.name = '${data['title'] ?? c.name}';
        songs = ((data['songs'] as List?) ?? [])
            .map((s) => Song.fromJson(Map<String, dynamic>.from(s)))
            .toList();
      } else {
        final data = await _api.getPlaylist(c.id);
        c.name = '${data['name'] ?? c.name}';
        songs = ((data['songs'] as List?) ?? [])
            .where((s) => s['available'] == 1) // in the library
            .map((s) => Song.fromJson(Map<String, dynamic>.from(s)))
            .toList();
      }
      c.songIds = songs.map((s) => s.id).toList();
      for (final s in songs) {
        if (!_downloads.containsKey(s.id)) _enqueue(_Job(s, forCache: false));
      }
      return true;
    } catch (e) {
      return false; // no signal / server down: keep the old list
    }
  }

  bool _referenced(int songId) =>
      _collections.values.any((c) => c.songIds.contains(songId));

  Future<void> _deleteUnreferenced() async {
    for (final id in _downloads.keys.toList()) {
      if (_referenced(id)) continue;
      final f = _downloads.remove(id)!;
      await _deleteFile(_pathOf('downloads', f));
    }
  }

  // ---------------------------------------------------------------- settings
  Future<void> setPreload(bool v) async {
    preloadEnabled = v;
    (await SharedPreferences.getInstance()).setBool(_kPreload, v);
    if (v) {
      _lastPreloadKey = '';
      _onPlayerChanged();
    }
    notifyListeners();
  }

  Future<void> setUseCellular(bool v) async {
    useCellular = v;
    (await SharedPreferences.getInstance()).setBool(_kCellular, v);
    _kick();
    notifyListeners();
  }

  /// New downloads use the new format (existing files are kept as they are).
  Future<void> setDownloadFormat(String v) async {
    downloadFormat = v;
    (await SharedPreferences.getInstance()).setString(_kFormat, v);
    notifyListeners();
  }

  Future<void> setCapGb(int v) async {
    capGb = v;
    (await SharedPreferences.getInstance()).setInt(_kCapGb, v);
    _unpark();
    notifyListeners();
  }

  /// Give downloads held back by the cap another go (cap raised or space
  /// freed); they park again if it's still full.
  void _unpark() {
    if (_parked.isEmpty) return;
    _jobs.addAll(_parked);
    _parked.clear();
    problem = null;
    _kick();
  }

  /// Empty the replay cache (downloads untouched).
  Future<void> clearCache() async {
    for (final f in _cache.values.toList()) {
      await _deleteFile(_pathOf('cache', f));
    }
    _cache.clear();
    _scheduleSave();
    notifyListeners();
  }

  // ---------------------------------------------------------------- worker
  void _enqueue(_Job j, {bool urgent = false}) {
    if (!_queued.add(j.key)) return;
    if (urgent) {
      _jobs.insert(0, j); // the next hour of the queue goes first
    } else {
      _jobs.add(j);
    }
  }

  void _kick() {
    _retryTimer?.cancel();
    _waiting = false;
    _pump();
  }

  void _pump() {
    while (!_waiting && _running < _maxParallel) {
      // At most one pre-load at a time; your own downloads can use the
      // other slot.
      final i = _jobs.indexWhere((j) => !j.forCache || _runningCache == 0);
      if (i < 0) break;
      final j = _jobs.removeAt(i);
      _running++;
      if (j.forCache) _runningCache++;
      _run(j).whenComplete(() {
        _running--;
        if (j.forCache) _runningCache--;
        _pump();
      });
    }
  }

  Future<void> _run(_Job j) async {
    try {
      await _fetch(j);
      _queued.remove(j.key);
      problem = null;
      notifyListeners();
    } on _Full {
      _parked.add(j);
      if (problem == null) {
        problem = 'Storage limit reached ($capGb GB)';
        notifyListeners();
      }
    } on _Wait catch (w) {
      // No usable network / server busy: put it back and try in a minute.
      _jobs.add(j);
      if (!_waiting) {
        _waiting = true;
        _retryTimer?.cancel();
        _retryTimer = Timer(const Duration(seconds: 60), _kick);
      }
      if (w.reason != null && problem != w.reason) {
        problem = w.reason;
        notifyListeners();
      }
    } catch (e) {
      _queued.remove(j.key);
      AppLogger.instance.info('⬇️ [offline] ${j.song.id} "${j.song.title}" failed: $e');
    }
  }

  Future<void> _fetch(_Job j) async {
    final s = j.song;
    if (_downloads.containsKey(s.id)) return;
    if (j.forCache && _cache.containsKey(s.id)) return;
    if (!j.forCache && !_referenced(s.id)) return; // download removed meanwhile
    if (!await _networkAllowed()) {
      throw _Wait(useCellular ? 'Waiting for a connection' : 'Waiting for Wi-Fi');
    }
    if (!j.forCache && downloadBytes >= capGb * _gb) throw _Full();

    String url;
    String format;
    String ext;
    if (s.isPodcast) {
      url = _api.getRssStreamUrl(s.podcastEpisodeId ?? -s.id);
      format = 'podcast';
      ext = 'audio';
    } else {
      final want = j.forCache ? _cacheQuality : downloadFormat;
      var quality = want;
      if (want != 'lossless') {
        final r = await _api.prepareDownload(s.id, want);
        if (r == null) throw _Wait();
        if (r['status'] == 'missing') throw Exception('not in the library');
        quality = '${r['quality'] ?? want}';
      }
      url = _api.getStreamUrl(s.id, quality: quality);
      format = quality;
      ext = switch (quality) {
        'opus160' => 'opus',
        'high' || 'medium' => 'm4a',
        _ => _extOf(s.filePath),
      };
    }

    final dir = j.forCache ? 'cache' : 'downloads';
    final name = '${s.id}.$ext';
    final file = File('${_root!.path}/$dir/$name');
    final part = File('${file.path}.part');
    final List<int> got;
    try {
      got = await _downloadOffThread(
          url, part.path, j.forCache ? _cacheRate : _downloadRate);
    } catch (_) {
      await _deleteFile(part.path); // signal gone mid-file: retry later
      throw _Wait();
    }
    if (got[0] != 200) {
      await _deleteFile(part.path);
      throw _Wait();
    }
    final bytes = got[1];
    final expected = got[2];
    if (bytes == 0 || (expected > 0 && bytes != expected)) {
      await _deleteFile(part.path);
      throw _Wait();
    }
    await part.rename(file.path);

    final entry = _OfflineFile(name, bytes, format, _now(), s.toJson());
    if (j.forCache) {
      _cache[s.id] = entry;
      await _trimCache();
    } else {
      _downloads[s.id] = entry;
      final c = _cache.remove(s.id); // a download replaces its cached copy
      if (c != null) await _deleteFile(_pathOf('cache', c));
    }
    _scheduleSave();
  }

  /// Drop the least recently used cached songs past the cap, never the
  /// current song or the hour ahead.
  Future<void> _trimCache() async {
    final current = _player?.currentSong?.id;
    final byAge = _cache.entries.toList()
      ..sort((a, b) => a.value.used.compareTo(b.value.used));
    var total = cacheBytes;
    for (final e in byAge) {
      if (total <= cacheCapBytes) break;
      if (e.key == current || _protected.contains(e.key)) continue;
      _cache.remove(e.key);
      total -= e.value.bytes;
      await _deleteFile(_pathOf('cache', e.value));
    }
  }

  Future<bool> _networkAllowed() async {
    final r = await Connectivity().checkConnectivity();
    if (r.contains(ConnectivityResult.wifi) ||
        r.contains(ConnectivityResult.ethernet)) {
      return true;
    }
    if (r.contains(ConnectivityResult.mobile)) return useCellular;
    return r.contains(ConnectivityResult.vpn); // VPN over something
  }

  // ---------------------------------------------------------------- index
  File get _indexFile => File('${_root!.path}/index.json');

  Future<void> _load() async {
    try {
      if (!await _indexFile.exists()) return;
      final d = json.decode(await _indexFile.readAsString()) as Map;
      Map<int, _OfflineFile> files(dynamic m) => {
            for (final e in ((m as Map?) ?? {}).entries)
              int.parse('${e.key}'):
                  _OfflineFile.fromJson(Map<String, dynamic>.from(e.value)),
          };
      _downloads.addAll(files(d['downloads']));
      _cache.addAll(files(d['cache']));
      for (final e in ((d['collections'] as Map?) ?? {}).entries) {
        _collections['${e.key}'] =
            OfflineCollection.fromJson(Map<String, dynamic>.from(e.value));
      }
      for (final e in ((d['lists'] as Map?) ?? {}).entries) {
        _lists['${e.key}'] = [for (final v in (e.value as List)) (v as num).toInt()];
      }
    } catch (e) {
      AppLogger.instance.info('⬇️ [offline] index unreadable, starting fresh: $e');
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _save);
  }

  Future<void> _save() async {
    if (_root == null) return;
    final d = {
      'v': 1,
      'downloads': {for (final e in _downloads.entries) '${e.key}': e.value.toJson()},
      'cache': {for (final e in _cache.entries) '${e.key}': e.value.toJson()},
      'collections': {for (final e in _collections.entries) e.key: e.value.toJson()},
      'lists': _lists,
    };
    final tmp = File('${_indexFile.path}.tmp');
    await tmp.writeAsString(json.encode(d));
    await tmp.rename(_indexFile.path);
  }

  // ---------------------------------------------------------------- helpers
  String _pathOf(String dir, _OfflineFile f) => '${_root!.path}/$dir/${f.file}';

  static Future<void> _deleteFile(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  static String _extOf(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot >= 0 ? path.substring(dot + 1).toLowerCase() : '';
    return ext.isEmpty || ext.length > 5 ? 'audio' : ext;
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  static String _mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(0)} MB';

  /// "1.2 GB" / "340 MB" for Settings.
  static String formatBytes(int bytes) => bytes >= _gb
      ? '${(bytes / _gb).toStringAsFixed(1)} GB'
      : '${(bytes / 1048576).toStringAsFixed(0)} MB';
}

enum OfflineState { none, downloading, waiting, done }

class OfflineStatus {
  const OfflineStatus(this.state, this.done, this.total);
  final OfflineState state;
  final int done;
  final int total;
}

/// A downloaded playlist, album or podcast episode.
class OfflineCollection {
  OfflineCollection(this.key, this.kind, this.id, this.name, this.songIds, this.added,
      {this.song, this.extra});
  final String key; // 'pl:20' / 'al:89' / 'ep:14428995'
  final String kind; // 'playlist' / 'album' / 'episode'
  final int id;
  String name;
  List<int> songIds;
  final int added;
  final Map<String, dynamic>? song; // episode: the player's Song
  final Map<String, dynamic>? extra; // episode: its server row

  Map<String, dynamic> toJson() => {
        'key': key,
        'kind': kind,
        'id': id,
        'name': name,
        'songs': songIds,
        'added': added,
        if (song != null) 'song': song,
        if (extra != null) 'extra': extra,
      };

  factory OfflineCollection.fromJson(Map<String, dynamic> j) => OfflineCollection(
        '${j['key']}',
        '${j['kind']}',
        (j['id'] as num).toInt(),
        '${j['name'] ?? ''}',
        [for (final s in (j['songs'] as List? ?? [])) (s as num).toInt()],
        (j['added'] as num?)?.toInt() ?? 0,
        song: j['song'] is Map ? Map<String, dynamic>.from(j['song'] as Map) : null,
        extra: j['extra'] is Map ? Map<String, dynamic>.from(j['extra'] as Map) : null,
      );
}

class _OfflineFile {
  _OfflineFile(this.file, this.bytes, this.format, this.used, this.song);
  final String file;
  final int bytes;
  final String format;
  int used;
  final Map<String, dynamic> song; // for offline browsing

  Map<String, dynamic> toJson() =>
      {'file': file, 'bytes': bytes, 'format': format, 'used': used, 'song': song};

  factory _OfflineFile.fromJson(Map<String, dynamic> j) => _OfflineFile(
        '${j['file']}',
        (j['bytes'] as num).toInt(),
        '${j['format'] ?? ''}',
        (j['used'] as num?)?.toInt() ?? 0,
        Map<String, dynamic>.from((j['song'] as Map?) ?? const {}),
      );
}

class _Job {
  _Job(this.song, {required this.forCache});
  final Song song;
  final bool forCache;
  String get key => '${forCache ? 'c' : 'd'}:${song.id}';
}

class _Full implements Exception {}

/// Download [url] into [path] on a background isolate, so the bytes never
/// touch the UI thread (Nov 9: full-speed downloads on the main isolate left
/// Now Playing's buttons unresponsive). Top-level on purpose: the closure
/// Isolate.run sends may only capture these three plain values.
Future<List<int>> _downloadOffThread(String url, String path, int maxBytesPerSec) =>
    Isolate.run(() => _downloadInIsolate(url, path, maxBytesPerSec));

/// [status, bytes written, Content-Length (0 if unknown)]. Paced to
/// [maxBytesPerSec]; a 60 s stall (signal gone) throws.
Future<List<int>> _downloadInIsolate(String url, String path, int maxBytesPerSec) async {
  final client = http.Client();
  IOSink? sink;
  try {
    final resp = await client
        .send(http.Request('GET', Uri.parse(url)))
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) return [resp.statusCode, 0, 0];
    sink = File(path).openWrite();
    final clock = Stopwatch()..start();
    var bytes = 0;
    await for (final chunk in resp.stream.timeout(const Duration(seconds: 60))) {
      sink.add(chunk);
      bytes += chunk.length;
      if (maxBytesPerSec > 0) {
        final aheadMs = bytes * 1000 ~/ maxBytesPerSec - clock.elapsedMilliseconds;
        if (aheadMs > 20) await Future<void>.delayed(Duration(milliseconds: aheadMs));
      }
    }
    await sink.flush();
    await sink.close();
    sink = null;
    return [200, bytes, resp.contentLength ?? 0];
  } finally {
    try {
      await sink?.close();
    } catch (_) {}
    client.close();
  }
}

class _Wait implements Exception {
  _Wait([this.reason]);
  final String? reason;
}
