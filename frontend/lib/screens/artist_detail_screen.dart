import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui';
import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
import '../models/artist.dart';
import '../models/album.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import '../services/auth_http_client.dart';
import 'album_detail_screen.dart';
import 'now_playing_screen.dart';
import '../widgets/favorite_button.dart';
import '../widgets/music_context_menu.dart';
import '../widgets/mouse_back_button_wrapper.dart';
import '../widgets/breadcrumb_bar.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';
import 'prowlarr_search_screen.dart';
import 'ghost_album_screen.dart';

class ArtistDetailScreen extends StatefulWidget {
  /// Live artist routes by artist id, so an album's breadcrumb can pop back
  /// to the artist page if it is on the stack (or push it if it isn't)
  /// instead of guessing how many routes sit underneath.
  static final Map<ModalRoute<dynamic>, int> liveRoutes = {};
  static bool isOnStack(BuildContext context, int artistId) {
    return liveRoutes.values.contains(artistId);
  }

  final int artistId;
  final AudioPlayerService audioPlayerService;
  final String? parentLabel; // e.g., "Library" or "Search"

  const ArtistDetailScreen({
    super.key,
    required this.artistId,
    required this.audioPlayerService,
    this.parentLabel,
  });

  @override
  State<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends State<ArtistDetailScreen> {
  ModalRoute<dynamic>? _ownRoute;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final r = ModalRoute.of(context);
    if (r != null && r != _ownRoute) {
      if (_ownRoute != null) ArtistDetailScreen.liveRoutes.remove(_ownRoute);
      _ownRoute = r;
      ArtistDetailScreen.liveRoutes[r] = widget.artistId;
    }
  }

  final ApiService _apiService = ApiService();
  Artist? _artist;
  int _imageCacheBuster = 0;
  List<Album> _albums = [];
  List<Song> _featuredSongs = [];
  List<Map<String, dynamic>> _topTracks = [];
  List<Map<String, dynamic>> _spotifyTracks = [];
  bool _isLoadingSpotifyTracks = true;
  int _popularTabIndex = 0;
  int? _monthlyListeners;
  int? _followerCount;
  Color _dominantColor = const Color(0xFF00d4ff);
  bool _isLoading = true;
  String? _error;

  bool get _isVanHalen =>
      _artist != null && _artist!.name.toLowerCase().contains('van halen');

  // Discography state (MusicBrainz release groups merged with the local
  // library; see backend app/discography.py). Loaded with the artist and
  // polled every few seconds while the backend is still fetching.
  Map<String, dynamic>? _discography;
  bool _isLoadingDiscography = false;
  String _discographyTab = 'Album';
  Timer? _discographyPoll;
  static const _discographyTabs = [
    'Album', 'EP', 'Single', 'Compilation', 'Live', 'Bootleg', 'Other',
  ];
  static const _discographyTabLabels = {
    'Album': 'Albums',
    'EP': 'EPs',
    'Single': 'Singles',
    'Compilation': 'Compilations',
    'Live': 'Live',
    'Bootleg': 'Bootlegs',
    'Other': 'Other',
  };

  bool get _discographyReady =>
      _discography != null &&
      (_discography!['status'] == 'ready' ||
          _discography!['status'] == 'refreshing');

  List<Map<String, dynamic>> _discographyEntries(String tab) =>
      List<Map<String, dynamic>>.from(
        (_discography?['discography']?[tab] as List?) ?? const [],
      );

  Map<int, Album> get _albumsById => {for (final a in _albums) a.id: a};
  // Local-library type filter chip: 'All' or a category (Album/Single/EP/...).
  String _libraryTab = 'All';

  // Local albums filtered by the selected type chip.
  List<Album> get _libraryAlbums => _libraryTab == 'All'
      ? _albums
      : _albums.where((a) => a.category == _libraryTab).toList();

  // Ordered categories present in this artist's local library, each with its
  // count, for the filter-chip row. Only non-empty categories are returned.
  List<MapEntry<String, int>> get _libraryCategoryCounts {
    const order = ['Album', 'Single', 'EP', 'Compilation', 'Live'];
    final counts = <String, int>{};
    for (final a in _albums) {
      counts[a.category] = (counts[a.category] ?? 0) + 1;
    }
    return order
        .where((c) => (counts[c] ?? 0) > 0)
        .map((c) => MapEntry(c, counts[c]!))
        .toList();
  }

  Widget _buildLibraryChip(String category, int count) {
    final isSelected = _libraryTab == category;
    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: FilterChip(
        label: Text('$category ($count)'),
        selected: isSelected,
        onSelected: (_) => setState(() => _libraryTab = category),
        selectedColor: const Color(0xFF00d4ff),
        checkmarkColor: Colors.black,
        backgroundColor: const Color(0xFF1a2332),
        labelStyle: TextStyle(
          color: isSelected ? Colors.black : Colors.white70,
        ),
      ),
    );
  }

  // Selection mode state
  bool _selectionMode = false;
  Set<int> _selectedAlbumIds = {};

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  // Preview playback state
  int? _currentlyPlayingIndex;
  VoidCallback? _stopCurrentPreview;
  bool _disposed = false;

  // Cancellable HTTP client for the Spotify top-tracks fetch. The
  // backend does 10s+ MusicBrainz/Spotify calls; closing the client
  // on dispose aborts them so the server releases its resources
  // instead of finishing work for a screen that's already gone.
  http.Client? _spotifyTracksClient;

  @override
  void initState() {
    super.initState();
    _loadArtist();
    widget.audioPlayerService.addListener(_onMainPlayerChanged);
  }

  void _onMainPlayerChanged() {
    if (_disposed) return;
    if (widget.audioPlayerService.isPlaying && _currentlyPlayingIndex != null) {
      _stopAllPreviews();
    }
  }

  void _onPreviewStarted(int index, VoidCallback stopCallback) {
    _stopCurrentPreview?.call();
    setState(() {
      _currentlyPlayingIndex = index;
      _stopCurrentPreview = stopCallback;
    });
  }

  void _stopAllPreviews() {
    _stopCurrentPreview?.call();
    setState(() {
      _currentlyPlayingIndex = null;
      _stopCurrentPreview = null;
    });
  }

  void _onPreviewStopped() {
    setState(() {
      _currentlyPlayingIndex = null;
    });
  }

  @override
  void dispose() {
    if (_ownRoute != null) ArtistDetailScreen.liveRoutes.remove(_ownRoute);
    _disposed = true;
    widget.audioPlayerService.removeListener(_onMainPlayerChanged);
    _spotifyTracksClient?.close();
    _spotifyTracksClient = null;
    _discographyPoll?.cancel();
    super.dispose();
  }

  Future<void> _loadArtist() async {
    try {
      final data = await _apiService.getArtist(widget.artistId);

      // setState-after-dispose guard: see favorite_button.dart for the
      // pattern. Caught a 2026-05-23 crash.
      if (!mounted) return;
      setState(() {
        _artist = Artist.fromJson(data);

        // Parse albums and add artist_name to each
        final albumsData = data['albums'] as List;
        _albums = albumsData.map((json) {
          json['artist_name'] = data['name'];
          return Album.fromJson(json);
        }).toList();

        // Parse featured songs
        final featuredData = data['featured_songs'] as List? ?? [];
        _featuredSongs = featuredData
            .map((json) => Song.fromJson(json))
            .toList();

        _isLoading = false;
      });

      // Load top tracks separately
      _loadTopTracks();
      _loadSpotifyTracks();
      _loadDiscography();

      // Extract dominant color from artist image
      if (_artist!.imagePath != null && _artist!.imagePath!.isNotEmpty) {
        _extractDominantColor();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _loadTopTracks() async {
    try {
      final response = await _apiService.getArtistTopTracks(widget.artistId);
      if (!mounted) return;
      setState(() {
        _topTracks = List<Map<String, dynamic>>.from(response['tracks']);
      });
    } catch (e) {
      print('Error loading top tracks: $e');
    }
  }

  Future<void> _loadSpotifyTracks() async {
    _spotifyTracksClient?.close();
    // Auth-injecting per-fetch client so the (auth-gated) spotify-top-tracks
    // call carries the bearer token; still independently closeable. A bare
    // http.Client() gets 401'd by the auth gate.
    final client = AuthHttpClient()..setToken(appHttpClient.token);
    _spotifyTracksClient = client;
    try {
      final response = await _apiService.getArtistSpotifyTopTracks(
        widget.artistId,
        client: client,
      );
      if (!mounted || !identical(_spotifyTracksClient, client)) return;
      final tracks = List<Map<String, dynamic>>.from(response['tracks'] ?? []);

      // Map Pathfinder fields to expected frontend fields
      for (final track in tracks) {
        track['title'] = track['name'] ?? 'Unknown';
        track['playcount'] = track['playcount'] ?? 0;
      }

      // Compute relative popularity (0-100) from play counts for the bar
      if (tracks.isNotEmpty) {
        final maxPlaycount = tracks
            .map((t) => (t['playcount'] as num?) ?? 0)
            .reduce((a, b) => a > b ? a : b);
        if (maxPlaycount > 0) {
          for (final track in tracks) {
            track['popularity'] =
                (((track['playcount'] as num?) ?? 0) / maxPlaycount * 100)
                    .round();
          }
        }
      }

      // Sort by play count descending
      tracks.sort(
        (a, b) => ((b['playcount'] as num?) ?? 0).compareTo(
          (a['playcount'] as num?) ?? 0,
        ),
      );

      setState(() {
        _spotifyTracks = tracks;
        _isLoadingSpotifyTracks = false;
        _monthlyListeners = response['monthly_listeners'] as int?;
        _followerCount = response['follower_count'] as int?;
      });
    } catch (e) {
      if (!mounted || !identical(_spotifyTracksClient, client)) return;
      print('Error loading Spotify tracks: $e');
      setState(() {
        _isLoadingSpotifyTracks = false;
      });
    } finally {
      if (identical(_spotifyTracksClient, client)) {
        client.close();
        _spotifyTracksClient = null;
      }
    }
  }

  Future<void> _loadDiscography({bool refresh = false}) async {
    if (_isLoadingDiscography) return;
    _discographyPoll?.cancel();
    setState(() => _isLoadingDiscography = true);

    try {
      final response = await _apiService.getArtistDiscography(
        widget.artistId,
        refresh: refresh,
      );
      if (!mounted) return;
      setState(() {
        _discography = response;
        _isLoadingDiscography = false;
        // Land on the first tab that has something in it.
        if (_discographyEntries(_discographyTab).isEmpty) {
          for (final t in _discographyTabs) {
            if (_discographyEntries(t).isNotEmpty) {
              _discographyTab = t;
              break;
            }
          }
        }
      });
      final status = response['status'];
      if (status == 'fetching' || status == 'refreshing') {
        _discographyPoll = Timer(const Duration(seconds: 3), () {
          if (mounted) _loadDiscography();
        });
      }
    } catch (e) {
      print('Error loading discography: $e');
      if (!mounted) return;
      setState(() => _isLoadingDiscography = false);
    }
  }

  void _openGhostAlbum(Map<String, dynamic> entry) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GhostAlbumScreen(
          release: entry,
          artistName: _artist!.name,
          artistId: widget.artistId,
          artistMbid: _discography?['artist_mbid'] as String?,
          audioPlayerService: widget.audioPlayerService,
          onImported: _loadArtist,
        ),
      ),
    ).then((_) => _loadArtist());
  }

  Widget _buildGhostTile(Map<String, dynamic> entry) {
    final types = List<String>.from(entry['secondary_types'] ?? const []);
    final sub = [
      entry['year']?.toString() ?? 'Unknown year',
      if (entry['is_bootleg'] == true) 'Bootleg' else ...types,
    ].join(' • ');
    return ListTile(
      leading: Opacity(
        opacity: 0.45,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: CachedNetworkImage(
            imageUrl: entry['cover_url'] ?? '',
            width: 50,
            height: 50,
            fit: BoxFit.cover,
            placeholder: (context, url) => Container(
              width: 50,
              height: 50,
              color: const Color(0xFF1a2332),
            ),
            errorWidget: (context, url, error) => Container(
              width: 50,
              height: 50,
              color: const Color(0xFF1a2332),
              child: const Icon(Icons.album, color: Colors.white30),
            ),
          ),
        ),
      ),
      title: Text(
        entry['title'] ?? 'Unknown',
        style: const TextStyle(color: Colors.white38),
      ),
      subtitle: Text(sub, style: TextStyle(color: Colors.grey[700])),
      trailing: const Icon(
        Icons.download_for_offline_outlined,
        color: Colors.white24,
      ),
      onTap: () => _openGhostAlbum(entry),
    );
  }

  void _toggleAlbumSelection(int albumId) {
    setState(() {
      if (_selectedAlbumIds.contains(albumId)) {
        _selectedAlbumIds.remove(albumId);
        if (_selectedAlbumIds.isEmpty) {
          _selectionMode = false;
        }
      } else {
        _selectedAlbumIds.add(albumId);
      }
    });
  }

  void _enterSelectionMode(int albumId) {
    setState(() {
      _selectionMode = true;
      _selectedAlbumIds = {albumId};
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedAlbumIds.clear();
    });
  }

  Future<void> _showMergeAlbumsDialog() async {
    if (_selectedAlbumIds.length < 2) return;

    final TextEditingController controller = TextEditingController();
    List<Album> searchResults = [];
    bool isSearching = false;
    bool updateSongArtists = true; // Default true for YouTube merges

    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1a2332),
          title: Text('Merge ${_selectedAlbumIds.length} Albums'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Enter album name (or search existing):',
                  style: TextStyle(color: Colors.grey, fontSize: 14),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Album name...',
                    border: const OutlineInputBorder(),
                    suffixIcon: isSearching
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : null,
                  ),
                  onChanged: (value) async {
                    if (value.length < 2) {
                      setDialogState(() => searchResults = []);
                      return;
                    }
                    setDialogState(() => isSearching = true);
                    try {
                      final results = await _apiService.searchAlbums(value);
                      // Filter to only this artist's albums
                      final filtered = results
                          .where((a) => a.artistId == widget.artistId)
                          .toList();
                      setDialogState(() {
                        searchResults = filtered;
                        isSearching = false;
                      });
                    } catch (e) {
                      setDialogState(() => isSearching = false);
                    }
                  },
                ),
                if (searchResults.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 150),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0d1b2a),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.grey.shade700),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: searchResults.length,
                      itemBuilder: (context, index) {
                        final album = searchResults[index];
                        final isSelected = _selectedAlbumIds.contains(album.id);
                        return ListTile(
                          dense: true,
                          enabled: !isSelected,
                          leading: Icon(
                            isSelected ? Icons.check_circle : Icons.album,
                            color: isSelected
                                ? Colors.grey
                                : const Color(0xFF00d4ff),
                            size: 20,
                          ),
                          title: Text(
                            album.title,
                            style: TextStyle(
                              fontSize: 13,
                              color: isSelected ? Colors.grey : Colors.white,
                            ),
                          ),
                          subtitle: isSelected
                              ? const Text(
                                  'Already selected',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey,
                                  ),
                                )
                              : null,
                          onTap: isSelected
                              ? null
                              : () {
                                  controller.text = album.title;
                                  setDialogState(() => searchResults = []);
                                },
                        );
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                CheckboxListTile(
                  value: updateSongArtists,
                  onChanged: (v) =>
                      setDialogState(() => updateSongArtists = v ?? false),
                  title: const Text('Also update track artists'),
                  subtitle: Text(
                    'Set all ${_selectedAlbumIds.length} albums\' tracks to this artist',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: const Color(0xFF00d4ff),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: controller.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, controller.text.trim()),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00d4ff),
                foregroundColor: Colors.black,
              ),
              child: const Text('Merge'),
            ),
          ],
        ),
      ),
    );

    if (result == null || result.isEmpty) return;

    // Perform the merge
    try {
      final selectedList = _selectedAlbumIds.toList();
      final targetAlbumId = selectedList.first;
      final sourceAlbumIds = selectedList.sublist(1);

      // Create disc_numbers map - all set to 1 for simple merge
      final discNumbers = <int, int>{};
      for (final id in selectedList) {
        discNumbers[id] = 1;
      }

      await _apiService.mergeAlbums(
        targetAlbumId,
        sourceAlbumIds,
        discNumbers,
        result,
        albumArtistId: widget.artistId,
        updateSongArtists: updateSongArtists,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Merged ${selectedList.length} albums into "$result"',
            ),
            backgroundColor: Colors.green,
          ),
        );
        _exitSelectionMode();
        _loadArtist(); // Refresh the page
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _showEditYearDialog(Album album) async {
    final controller = TextEditingController(
      text: album.year?.toString() ?? '',
    );

    final result = await showDialog<int?>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a1f3c),
        title: const Text('Edit Album Year'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              album.title,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Year',
                hintText: 'e.g. 1984',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, -1), // -1 means clear year
            child: const Text('Clear'),
          ),
          ElevatedButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isEmpty) {
                Navigator.pop(context);
                return;
              }
              final year = int.tryParse(text);
              if (year != null && year >= 1900 && year <= 2100) {
                Navigator.pop(context, year);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Please enter a valid year (1900-2100)'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00d4ff),
              foregroundColor: Colors.black,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result == null) return;

    try {
      final yearToSave = result == -1 ? null : result;
      await _apiService.editAlbumYear(album.id, yearToSave);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              yearToSave == null
                  ? 'Year cleared for "${album.title}"'
                  : 'Year updated to $yearToSave for "${album.title}"',
            ),
            backgroundColor: Colors.green,
          ),
        );
        _loadArtist(); // Refresh the page
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update year: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildOwnedAlbumTile(Album album) {
                final isSelected = _selectedAlbumIds.contains(album.id);

                return GestureDetector(
                  onLongPress: _isMobile && !_selectionMode
                      ? () => _enterSelectionMode(album.id)
                      : null,
                  child: ListTile(
                    leading: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_selectionMode)
                          Checkbox(
                            value: isSelected,
                            onChanged: (_) => _toggleAlbumSelection(album.id),
                            activeColor: const Color(0xFF00d4ff),
                          ),
                        album.artworkPath != null &&
                                album.artworkPath!.isNotEmpty
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: CachedNetworkImage(
                                  imageUrl: _apiService.getArtworkUrl(album.id),
                                  width: 50,
                                  height: 50,
                                  fit: BoxFit.cover,
                                  placeholder: (context, url) => Container(
                                    width: 50,
                                    height: 50,
                                    color: const Color(0xFF1a2332),
                                  ),
                                  errorWidget: (context, url, error) =>
                                      const Icon(
                                        Icons.album,
                                        size: 40,
                                        color: Color(0xFF00d4ff),
                                      ),
                                ),
                              )
                            : const Icon(
                                Icons.album,
                                size: 40,
                                color: Color(0xFF00d4ff),
                              ),
                      ],
                    ),
                    title: Text(album.title),
                    selected: isSelected,
                    selectedTileColor: const Color(0xFF00d4ff).withOpacity(0.1),
                    subtitle: Text(
                      '${album.year ?? "Unknown"} • ${album.songCount} songs',
                    ),
                    trailing: !_isMobile
                        ? PopupMenuButton<String>(
                            icon: const Icon(
                              Icons.more_vert,
                              color: Colors.white54,
                            ),
                            onSelected: (value) {
                              if (value == 'select') {
                                if (_selectionMode) {
                                  _toggleAlbumSelection(album.id);
                                } else {
                                  _enterSelectionMode(album.id);
                                }
                              } else if (value == 'edit_year') {
                                _showEditYearDialog(album);
                              }
                            },
                            itemBuilder: (context) => [
                              PopupMenuItem(
                                value: 'select',
                                child: Row(
                                  children: [
                                    Icon(
                                      isSelected
                                          ? Icons.check_box
                                          : Icons.check_box_outline_blank,
                                      size: 20,
                                      color: const Color(0xFF00d4ff),
                                    ),
                                    const SizedBox(width: 12),
                                    Text(
                                      isSelected
                                          ? 'Deselect for merge'
                                          : 'Select for merge',
                                    ),
                                  ],
                                ),
                              ),
                              PopupMenuItem(
                                value: 'edit_year',
                                child: const Row(
                                  children: [
                                    Icon(
                                      Icons.calendar_today,
                                      size: 20,
                                      color: Color(0xFF00d4ff),
                                    ),
                                    SizedBox(width: 12),
                                    Text('Edit Year'),
                                  ],
                                ),
                              ),
                            ],
                          )
                        : null,
                    onTap: _selectionMode
                        ? () => _toggleAlbumSelection(album.id)
                        : () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => AlbumDetailScreen(
                                  albumId: album.id,
                                  audioPlayerService: widget.audioPlayerService,
                                  artistName: _artist?.name,
                                  artistId: _artist?.id,
                                  parentLabel:
                                      widget.parentLabel ?? 'Library',
                                ),
                              ),
                            ).then((_) => _loadArtist());
                          },
                  ),
                );
  }

  Future<void> _shufflePlayArtist() async {
    try {
      // Gather all songs from all albums
      List<Song> allSongs = [];

      for (final album in _albums) {
        final albumData = await _apiService.getAlbum(album.id);
        final songs = (albumData['songs'] as List).map((json) {
          json['artist_name'] = albumData['artist_name'];
          json['album_title'] = albumData['title'];
          return Song.fromJson(json);
        }).toList();
        allSongs.addAll(songs);
      }

      if (allSongs.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No songs found')));
        return;
      }

      // Shuffle and play
      allSongs.shuffle();
      widget.audioPlayerService.setQueue(
        allSongs,
        0,
        sourceType: 'artist',
        sourceId: widget.artistId,
        sourceName: _artist?.name,
      );

      NowPlayingScreen.open(
        context,
        audioPlayerService: widget.audioPlayerService,
      );
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }

  String _formatPlaycount(dynamic count) {
    final num = count is int ? count : int.tryParse(count.toString()) ?? 0;
    if (num >= 1000000000) {
      return '${(num / 1000000000).toStringAsFixed(1)}B';
    } else if (num >= 1000000) {
      return '${(num / 1000000).toStringAsFixed(1)}M';
    } else if (num >= 1000) {
      return '${(num / 1000).toStringAsFixed(1)}K';
    }
    return num.toString();
  }

  Future<ImageInfo> _resolveImage(ImageProvider provider) {
    final completer = Completer<ImageInfo>();
    final stream = provider.resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        if (!completer.isCompleted) completer.complete(info);
        stream.removeListener(listener);
      },
      onError: (exception, stackTrace) {
        if (!completer.isCompleted) completer.completeError(exception);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  Future<void> _extractDominantColor() async {
    try {
      final imageUrl = _apiService.getArtistImageUrl(_artist!.id, cacheBuster: _imageCacheBuster);
      final palette = await PaletteGenerator.fromImageProvider(
        CachedNetworkImageProvider(imageUrl),
        maximumColorCount: 8,
      );
      if (mounted) {
        setState(() {
          // Prefer vibrant color, fall back to dominant, then muted
          _dominantColor = palette.vibrantColor?.color ??
              palette.dominantColor?.color ??
              palette.mutedColor?.color ??
              const Color(0xFF00d4ff);
        });
      }
    } catch (e) {
      print('Could not extract palette: $e');
    }
  }

  Widget _buildStatChip(IconData icon, String label, {bool accent = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: accent
            ? const Color(0xFF00d4ff).withOpacity(0.15)
            : Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
        border: accent
            ? Border.all(color: const Color(0xFF00d4ff).withOpacity(0.3), width: 1)
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: accent ? const Color(0xFF00d4ff) : Colors.grey[400],
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: accent ? const Color(0xFF00d4ff) : Colors.grey[400],
              fontWeight: accent ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseBackButtonWrapper(
      child: Scaffold(
        backgroundColor: Color.lerp(_dominantColor, const Color(0xFF0d1117), 0.92)!,
        floatingActionButton: _selectionMode && _selectedAlbumIds.length >= 2
            ? FloatingActionButton.extended(
                onPressed: _showMergeAlbumsDialog,
                backgroundColor: const Color(0xFF00d4ff),
                foregroundColor: Colors.black,
                icon: const Icon(Icons.merge_type),
                label: Text('Merge ${_selectedAlbumIds.length}'),
              )
            : null,
        body: Column(
          children: [
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(child: Text('Error: $_error'))
                  : _buildContent(),
            ),
          ],
        ),
      ),
    );
  }

  void _showFullScreenImage(String imageUrl) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        // Tap-to-dismiss + d-pad-center-to-dismiss for Fire TV. Without
        // FocusableActionDetector(autofocus: true), the remote has no way
        // to close this fullscreen overlay since there's no other
        // focusable widget inside it.
        child: FocusableActionDetector(
          autofocus: true,
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                Navigator.of(context).pop();
                return null;
              },
            ),
          },
          child: GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              color: Colors.black.withOpacity(0.9),
              width: double.infinity,
              height: double.infinity,
              child: Stack(
                children: [
                  Center(
                    child: InteractiveViewer(
                      minScale: 0.5,
                      maxScale: 4.0,
                      child: CachedNetworkImage(
                        imageUrl: imageUrl,
                        fit: BoxFit.contain,
                        placeholder: (context, url) =>
                            const CircularProgressIndicator(
                          color: Color(0xFF00d4ff),
                        ),
                        errorWidget: (context, url, error) => const Icon(
                          Icons.broken_image,
                          color: Colors.grey,
                          size: 64,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 40,
                    right: 16,
                    child: IconButton(
                      icon: const Icon(
                        Icons.close,
                        color: Colors.white,
                        size: 30,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    return CustomScrollView(
      slivers: [
        // App bar with artist image
        SliverAppBar(
          expandedHeight: _isMobile ? 450 : 650,
          pinned: true,
          stretch: true,
          backgroundColor: Color.lerp(_dominantColor, const Color(0xFF0d1117), 0.88)!,
          title: _artist != null
              ? BreadcrumbBar(
                  items: [
                    BreadcrumbItem(
                      label: widget.parentLabel ?? 'Library',
                      // Root of the current section, however deep we are.
                      onTap: () =>
                          Navigator.popUntil(context, (r) => r.isFirst),
                    ),
                    BreadcrumbItem(label: _artist!.name),
                  ],
                )
              : null,
          leading: _selectionMode
              ? IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _exitSelectionMode,
                )
              : null,
          actions: _selectionMode
              ? [
                  IconButton(
                    icon: Icon(
                      _selectedAlbumIds.length == _albums.length
                          ? Icons.deselect
                          : Icons.select_all,
                    ),
                    tooltip: _selectedAlbumIds.length == _albums.length
                        ? 'Deselect all'
                        : 'Select all',
                    onPressed: () {
                      setState(() {
                        if (_selectedAlbumIds.length == _albums.length) {
                          _selectedAlbumIds.clear();
                          _selectionMode = false;
                        } else {
                          _selectedAlbumIds = _albums.map((a) => a.id).toSet();
                        }
                      });
                    },
                  ),
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: Text(
                        '${_selectedAlbumIds.length} selected',
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                ]
              : null,
          flexibleSpace: FlexibleSpaceBar(
            background: Stack(
              fit: StackFit.expand,
              children: [
                // Abstract color wash — overlapping radial gradients (skipped for Van Halen)
                if (!_isVanHalen) ...[
                  Container(color: Color.lerp(_dominantColor, const Color(0xFF0d1117), 0.7)),
                  Container(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(-0.6, -0.5),
                        radius: 1.8,
                        colors: [
                          _dominantColor.withOpacity(0.7),
                          _dominantColor.withOpacity(0.3),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0.8, -0.2),
                        radius: 1.5,
                        colors: [
                          Color.lerp(_dominantColor, const Color(0xFF6C00FF), 0.6)!.withOpacity(0.7),
                          Color.lerp(_dominantColor, const Color(0xFF6C00FF), 0.6)!.withOpacity(0.2),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(-0.3, 0.6),
                        radius: 1.3,
                        colors: [
                          Color.lerp(_dominantColor, const Color(0xFF00d4ff), 0.5)!.withOpacity(0.5),
                          Color.lerp(_dominantColor, const Color(0xFF00d4ff), 0.5)!.withOpacity(0.15),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0.4, 0.8),
                        radius: 1.0,
                        colors: [
                          Color.lerp(_dominantColor, const Color(0xFF9C27B0), 0.4)!.withOpacity(0.4),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ],
                // EVH Frankenstein stripes for Van Halen
                if (_isVanHalen)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _EvhStripesPainter(),
                    ),
                  ),
                // Centered artist image — natural aspect ratio, fully visible, rounded
                if (_artist!.imagePath != null && _artist!.imagePath!.isNotEmpty)
                  Positioned(
                    top: _isMobile ? 30 : 50,
                    left: _isMobile ? 16 : 24,
                    right: _isMobile ? 16 : 24,
                    bottom: _isMobile ? 120 : 160,
                    child: GestureDetector(
                      onTap: () => _showFullScreenImage(
                        _apiService.getArtistImageUrl(_artist!.id, cacheBuster: _imageCacheBuster),
                      ),
                      child: CachedNetworkImage(
                            imageUrl: _apiService.getArtistImageUrl(_artist!.id, cacheBuster: _imageCacheBuster),
                            fit: BoxFit.contain,
                            imageBuilder: (context, imageProvider) {
                              return LayoutBuilder(
                                builder: (context, constraints) {
                                  return FutureBuilder<ImageInfo>(
                                    future: _resolveImage(imageProvider),
                                    builder: (context, snapshot) {
                                      if (!snapshot.hasData) {
                                        return const SizedBox(width: 300, height: 300);
                                      }
                                      final imgWidth = snapshot.data!.image.width.toDouble();
                                      final imgHeight = snapshot.data!.image.height.toDouble();
                                      final aspectRatio = imgWidth / imgHeight;
                                      final isWide = aspectRatio > 1.2;

                                      if (isWide) {
                                        // Rectangular — show full image, centered vertically
                                        return Center(
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(20),
                                            child: Image(image: imageProvider, fit: BoxFit.contain),
                                          ),
                                        );
                                      } else {
                                        // Square-ish — fill height, maintain aspect ratio
                                        return Center(
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(20),
                                            child: Image(image: imageProvider, fit: BoxFit.contain),
                                          ),
                                        );
                                      }
                                    },
                                  );
                                },
                              );
                            },
                            placeholder: (context, url) => const SizedBox(width: 300, height: 300),
                            errorWidget: (context, url, error) => Container(
                              width: 300, height: 300,
                              color: const Color(0xFF1a2332),
                              child: const Icon(Icons.person, size: 80, color: Color(0xFF00d4ff)),
                            ),
                          ),
                    ),
                  )
                else
                  Center(
                    child: Container(
                      width: 200, height: 200,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1a2332),
                        borderRadius: BorderRadius.circular(100),
                      ),
                      child: const Icon(Icons.person, size: 80, color: Color(0xFF00d4ff)),
                    ),
                  ),
                // Subtle bottom fade — just enough to separate image from card
                Positioned(
                  left: 0, right: 0, bottom: 0, height: 100,
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withOpacity(0.3),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // Frosted glass artist info card
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0d1117).withOpacity(0.65),
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                          border: Border(
                            top: BorderSide(
                              color: Colors.white.withOpacity(0.08),
                              width: 1,
                            ),
                          ),
                        ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Artist name + actions
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Text(
                                _artist!.name,
                                style: const TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                  letterSpacing: -0.8,
                                  height: 1.1,
                                ),
                              ),
                            ),
                            FavoriteButton(
                              itemType: 'artist',
                              itemId: _artist!.id,
                              size: 28,
                            ),
                            MusicContextMenu(
                              itemType: 'artist',
                              itemId: _artist!.id,
                              itemName: _artist!.name,
                              audioPlayerService: widget.audioPlayerService,
                              onArtworkChanged: () {
                                setState(() => _imageCacheBuster++);
                                _loadArtist();
                              },
                              hasArtistImage:
                                  _artist!.imagePath != null &&
                                  _artist!.imagePath!.isNotEmpty,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        // Stats row with visual flair
                        Row(
                          children: [
                            _buildStatChip(Icons.album, '${_artist!.albumCount} albums'),
                            const SizedBox(width: 8),
                            _buildStatChip(Icons.music_note, '${_artist!.songCount} songs'),
                            if (_monthlyListeners != null && _monthlyListeners! > 0) ...[
                              const SizedBox(width: 8),
                              _buildStatChip(
                                Icons.headphones,
                                '${_formatPlaycount(_monthlyListeners!)} listeners',
                                accent: true,
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                ),
                ),
              ],
            ),
          ),
        ),

        // Action buttons
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: ElevatedButton.icon(
              onPressed: _shufflePlayArtist,
              icon: const Icon(Icons.shuffle, size: 20),
              label: const Text(
                'Shuffle All',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00d4ff),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
                elevation: 8,
                shadowColor: const Color(0xFF00d4ff).withOpacity(0.5),
              ),
            ),
          ),
        ),

        // Popular section with tabs
        if (_topTracks.isNotEmpty || _spotifyTracks.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  const Text(
                    'Popular',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const Spacer(),
                  // Tab buttons
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1a2332),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          onTap: () => setState(() => _popularTabIndex = 0),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: _popularTabIndex == 0
                                  ? const Color(0xFF00d4ff)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              'My Stats',
                              style: TextStyle(
                                color: _popularTabIndex == 0
                                    ? Colors.black
                                    : Colors.white70,
                                fontWeight: FontWeight.w500,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: () => setState(() => _popularTabIndex = 1),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: _popularTabIndex == 1
                                  ? const Color(0xFF00d4ff)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              'Global',
                              style: TextStyle(
                                color: _popularTabIndex == 1
                                    ? Colors.black
                                    : Colors.white70,
                                fontWeight: FontWeight.w500,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // My Stats tab
          if (_popularTabIndex == 0)
            _topTracks.isEmpty
                ? const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text(
                        'No plays yet - start listening!',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  )
                : SliverList(
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final track = _topTracks[index];
                      return ListTile(
                        leading: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 24,
                              child: Text(
                                '${index + 1}',
                                style: const TextStyle(
                                  fontSize: 16,
                                  color: Colors.grey,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            const SizedBox(width: 12),
                            track['artwork_path'] != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: CachedNetworkImage(
                                      imageUrl: _apiService.getArtworkUrl(
                                        track['album_id'],
                                      ),
                                      width: 45,
                                      height: 45,
                                      fit: BoxFit.cover,
                                      placeholder: (context, url) => Container(
                                        width: 45,
                                        height: 45,
                                        color: const Color(0xFF1a2332),
                                      ),
                                      errorWidget: (context, url, error) =>
                                          Container(
                                            width: 45,
                                            height: 45,
                                            color: const Color(0xFF1a2332),
                                            child: const Icon(
                                              Icons.music_note,
                                              color: Color(0xFF00d4ff),
                                            ),
                                          ),
                                    ),
                                  )
                                : Container(
                                    width: 45,
                                    height: 45,
                                    color: const Color(0xFF1a2332),
                                    child: const Icon(
                                      Icons.music_note,
                                      color: Color(0xFF00d4ff),
                                    ),
                                  ),
                          ],
                        ),
                        title: Text(
                          track['title'],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${track['play_count']} plays',
                          style: const TextStyle(color: Colors.grey),
                        ),
                        trailing: _isMobile
                            ? MusicContextMenu(
                                itemType: 'song',
                                itemId: track['id'],
                                itemName: track['title'],
                                audioPlayerService: widget.audioPlayerService,
                              )
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _formatDuration(track['duration'] ?? 0),
                                    style: const TextStyle(color: Colors.grey),
                                  ),
                                  MusicContextMenu(
                                    itemType: 'song',
                                    itemId: track['id'],
                                    itemName: track['title'],
                                    audioPlayerService:
                                        widget.audioPlayerService,
                                  ),
                                ],
                              ),
                        onTap: () {
                          final song = Song(
                            id: track['id'],
                            title: track['title'],
                            artistId: widget.artistId,
                            artistName: _artist!.name,
                            albumId: track['album_id'],
                            albumTitle: track['album_title'] ?? '',
                            duration: track['duration'] ?? 0,
                            trackNumber: 0,
                            discNumber: 1,
                            filePath: track['file_path'] ?? '',
                            fileSize: 0,
                            bitrate: 0,
                          );
                          widget.audioPlayerService.playSong(song);
                        },
                      );
                    }, childCount: _topTracks.length),
                  ),
          // Global tab (Last.fm)
          if (_popularTabIndex == 1)
            _isLoadingSpotifyTracks
                ? const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  )
                : _spotifyTracks.isEmpty
                ? const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text(
                        'No global stats available for this artist',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  )
                : SliverList(
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final track = _spotifyTracks[index];
                      final hasLocal = track['local_id'] != null;

                      if (!hasLocal) {
                        return _LastfmPreviewTile(
                          key: ValueKey('lastfm_$index'),
                          index: index,
                          track: track,
                          artistName: _artist!.name,
                          formatPlaycount: _formatPlaycount,
                          mainAudioPlayer: widget.audioPlayerService,
                          isCurrentlyPlaying: _currentlyPlayingIndex == index,
                          shouldStop:
                              _currentlyPlayingIndex != null &&
                              _currentlyPlayingIndex != index,
                          onPreviewStarted: (stopCallback) =>
                              _onPreviewStarted(index, stopCallback),
                          onPreviewStopped: _onPreviewStopped,
                        );
                      }

                      return ListTile(
                        leading: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 24,
                              child: Text(
                                '${index + 1}',
                                style: const TextStyle(
                                  fontSize: 16,
                                  color: Colors.grey,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            const SizedBox(width: 12),
                            track['artwork_path'] != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: CachedNetworkImage(
                                      imageUrl: _apiService.getArtworkUrl(
                                        track['album_id'],
                                      ),
                                      width: 45,
                                      height: 45,
                                      fit: BoxFit.cover,
                                      placeholder: (context, url) => Container(
                                        width: 45,
                                        height: 45,
                                        color: const Color(0xFF1a2332),
                                      ),
                                      errorWidget: (context, url, error) =>
                                          Container(
                                            width: 45,
                                            height: 45,
                                            color: const Color(0xFF1a2332),
                                            child: const Icon(
                                              Icons.music_note,
                                              color: Color(0xFF00d4ff),
                                            ),
                                          ),
                                    ),
                                  )
                                : Container(
                                    width: 45,
                                    height: 45,
                                    color: const Color(0xFF1a2332),
                                    child: const Icon(
                                      Icons.music_note,
                                      color: Color(0xFF00d4ff),
                                    ),
                                  ),
                          ],
                        ),
                        title: Text(
                          track['title'],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: _PopularityBar(
                          popularity: track['popularity'] ?? 0,
                          playcount: track['playcount'] as int?,
                          suffix: track['album_title'] ?? '',
                        ),
                        trailing: _isMobile
                            ? MusicContextMenu(
                                itemType: 'song',
                                itemId: track['local_id'],
                                itemName: track['title'],
                                audioPlayerService: widget.audioPlayerService,
                              )
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.play_arrow,
                                    color: Color(0xFF00d4ff),
                                  ),
                                  MusicContextMenu(
                                    itemType: 'song',
                                    itemId: track['local_id'],
                                    itemName: track['title'],
                                    audioPlayerService:
                                        widget.audioPlayerService,
                                  ),
                                ],
                              ),
                        onTap: () {
                          // Build queue from all matched library songs in popularity order
                          final matchedSongs = _spotifyTracks
                              .where((t) => t['local_id'] != null)
                              .map((t) => Song(
                                    id: t['local_id'],
                                    title: t['local_title'] ?? t['title'],
                                    artistId: t['artist_id'] ?? widget.artistId,
                                    artistName: _artist!.name,
                                    albumId: t['album_id'],
                                    albumTitle: t['album_title'] ?? '',
                                    duration: t['duration'] ?? 0,
                                    trackNumber: t['track_number'] ?? 0,
                                    discNumber: t['disc_number'] ?? 1,
                                    filePath: t['file_path'] ?? '',
                                    fileSize: t['file_size'] ?? 0,
                                    bitrate: t['bitrate'] ?? 0,
                                  ))
                              .toList();

                          final tappedSong = matchedSongs.firstWhere(
                            (s) => s.id == track['local_id'],
                            orElse: () => matchedSongs.first,
                          );
                          final startIndex = matchedSongs.indexOf(tappedSong);

                          widget.audioPlayerService.setQueue(
                            matchedSongs,
                            startIndex >= 0 ? startIndex : 0,
                            sourceType: 'artist',
                            sourceId: widget.artistId,
                            sourceName: '${_artist!.name} Top Songs',
                          );

                          NowPlayingScreen.open(
                            context,
                            audioPlayerService: widget.audioPlayerService,
                          );
                        },
                      );
                    }, childCount: _spotifyTracks.length),
                  ),
        ],

        // Discography section: every MusicBrainz release group for the
        // artist, tabbed by type, in release order. Owned ones are the
        // normal album tiles; the rest are greyed and open the ghost page
        // (Search Prowlarr / Search YouTube / Import files). Until the
        // backend has fetched MusicBrainz, the local library shows instead.
        if (_albums.isNotEmpty || _discographyReady) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
              child: Row(
                children: [
                  const Text(
                    'Discography',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (_discographyReady)
                    Text(
                      '${_discography!['in_library_count']} of '
                      '${_discography!['total_count']}',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 13,
                      ),
                    ),
                  const Spacer(),
                  if (_discography != null &&
                      (_discography!['status'] == 'fetching' ||
                          _discography!['status'] == 'refreshing'))
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF00d4ff),
                        ),
                      ),
                    )
                  else if (_discography != null)
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 20),
                      color: Colors.white38,
                      tooltip: 'Refresh from MusicBrainz',
                      onPressed: () => _loadDiscography(refresh: true),
                    ),
                ],
              ),
            ),
          ),
          if (_discography != null &&
              _discography!['status'] == 'fetching' &&
              !_discographyReady)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'Fetching the full discography from MusicBrainz…',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ),
            ),
          if (_discography != null &&
              _discography!['status'] == 'error' &&
              _discography!['error'] != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'MusicBrainz: ${_discography!['error']}',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ),
            ),
          // Tabs by release type (only the non-empty ones)
          if (_discographyReady) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _discographyTabs
                        .where((t) => _discographyEntries(t).isNotEmpty)
                        .map((tab) {
                          final counts = _discography!['counts']?[tab];
                          final owned = counts?['owned'] ?? 0;
                          final total = counts?['total'] ?? 0;
                          final isSelected = _discographyTab == tab;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: FilterChip(
                              label: Text(
                                '${_discographyTabLabels[tab]} $owned/$total',
                              ),
                              selected: isSelected,
                              showCheckmark: false,
                              onSelected: (_) =>
                                  setState(() => _discographyTab = tab),
                              selectedColor: const Color(0xFF00d4ff),
                              labelStyle: TextStyle(
                                color: isSelected
                                    ? Colors.black
                                    : Colors.white70,
                                fontWeight: isSelected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          );
                        })
                        .toList(),
                  ),
                ),
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final entries = _discographyEntries(_discographyTab);
                if (index >= entries.length) return null;
                final entry = entries[index];
                final localId = entry['local_album_id'] as int?;
                final album = localId != null ? _albumsById[localId] : null;
                if (album != null) return _buildOwnedAlbumTile(album);
                if (entry['mbid'] == null) return const SizedBox.shrink();
                return _buildGhostTile(entry);
              }, childCount: _discographyEntries(_discographyTab).length),
            ),
          ] else ...[
            // Local library while MusicBrainz is still loading (or unknown)
            if (_libraryCategoryCounts.length > 1)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _buildLibraryChip('All', _albums.length),
                        ..._libraryCategoryCounts.map(
                          (e) => _buildLibraryChip(e.key, e.value),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                return _buildOwnedAlbumTile(_libraryAlbums[index]);
              }, childCount: _libraryAlbums.length),
            ),
          ],
        ],

        // Appears On section
        if (_featuredSongs.isNotEmpty) ...[
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Appears On',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              final song = _featuredSongs[index];
              return ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: CachedNetworkImage(
                    imageUrl: _apiService.getArtworkUrl(song.albumId),
                    width: 50,
                    height: 50,
                    fit: BoxFit.cover,
                    placeholder: (context, url) => Container(
                      width: 50,
                      height: 50,
                      color: const Color(0xFF1a2332),
                    ),
                    errorWidget: (context, url, error) => Container(
                      width: 50,
                      height: 50,
                      color: const Color(0xFF0d1b2a),
                      child: const Icon(
                        Icons.music_note,
                        color: Color(0xFF00d4ff),
                        size: 24,
                      ),
                    ),
                  ),
                ),
                title: Text(song.title),
                subtitle: Text(song.albumTitle),
                trailing: Text(song.durationFormatted),
                onTap: () {
                  widget.audioPlayerService.setQueue(
                    [song],
                    0,
                    sourceType: 'single',
                  );
                  NowPlayingScreen.open(
                    context,
                    audioPlayerService: widget.audioPlayerService,
                  );
                },
              );
            }, childCount: _featuredSongs.length),
          ),
        ],

        // Empty state
        if (_albums.isEmpty && _featuredSongs.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(32.0),
              child: Center(
                child: Text(
                  'No music found for this artist',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            ),
          ),

        // Bottom padding
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
      ],
    );
  }
}

// =====================
// Last.fm Preview Tile (for unavailable tracks)
// =====================

// =====================
// Popularity Energy Bar
// =====================

class _PopularityBar extends StatelessWidget {
  final int popularity; // 0-100 relative for bar fill
  final String? suffix;
  final int? playcount; // Raw play count for formatted display

  const _PopularityBar({required this.popularity, this.suffix, this.playcount});

  String _formatCount(int count) {
    if (count >= 1000000000) {
      return '${(count / 1000000000).toStringAsFixed(1)}B';
    } else if (count >= 1000000) {
      return '${(count / 1000000).toStringAsFixed(1)}M';
    } else if (count >= 1000) {
      return '${(count / 1000).toStringAsFixed(1)}K';
    }
    return count.toString();
  }

  @override
  Widget build(BuildContext context) {
    final double score = popularity / 10.0; // 0-10 scale
    final String label = playcount != null
        ? _formatCount(playcount!)
        : score.toStringAsFixed(1);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 10 bar segments
        ...List.generate(10, (i) {
          final double fillAmount = (score - i).clamp(0.0, 1.0);
          return Container(
            width: 8,
            height: 12,
            margin: const EdgeInsets.only(right: 1.5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              color: fillAmount > 0
                  ? Color.lerp(
                      const Color(0xFF00d4ff).withOpacity(0.4),
                      const Color(0xFF00d4ff),
                      fillAmount,
                    )
                  : const Color(0xFF1a2332),
              boxShadow: fillAmount > 0.5
                  ? [
                      BoxShadow(
                        color: const Color(
                          0xFF00d4ff,
                        ).withOpacity(0.3 * fillAmount),
                        blurRadius: 3,
                        spreadRadius: 0,
                      ),
                    ]
                  : null,
            ),
          );
        }),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF00d4ff),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (suffix != null) ...[
          Text(
            ' • $suffix',
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ],
    );
  }
}

class _LastfmPreviewTile extends StatefulWidget {
  final int index;
  final Map<String, dynamic> track;
  final String artistName;
  final String Function(dynamic) formatPlaycount;
  final AudioPlayerService mainAudioPlayer;
  final bool isCurrentlyPlaying;
  final bool shouldStop;
  final void Function(VoidCallback stopCallback) onPreviewStarted;
  final VoidCallback onPreviewStopped;

  const _LastfmPreviewTile({
    super.key,
    required this.index,
    required this.track,
    required this.artistName,
    required this.formatPlaycount,
    required this.mainAudioPlayer,
    required this.isCurrentlyPlaying,
    required this.shouldStop,
    required this.onPreviewStarted,
    required this.onPreviewStopped,
  });

  @override
  State<_LastfmPreviewTile> createState() => _LastfmPreviewTileState();
}

class _LastfmPreviewTileState extends State<_LastfmPreviewTile>
    with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();

  AudioPlayer? _previewPlayer;
  bool _isPlaying = false;
  bool _isLoading = false;
  bool _isStopping = false;
  double _progress = 0.0;
  Timer? _progressTimer;
  late AnimationController _fadeController;
  String? _previewUrl;
  bool _noPreviewAvailable = false;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  void didUpdateWidget(covariant _LastfmPreviewTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shouldStop && _isPlaying) {
      _stopPreviewImmediate();
    }
  }

  @override
  void dispose() {
    _stopPreview();
    _fadeController.dispose();
    super.dispose();
  }

  Future<void> _fetchAndPlayPreview() async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
    });

    // Use preview_url directly from track data (already fetched from Spotify)
    final url = widget.track['preview_url'];
    if (url != null && url.toString().isNotEmpty) {
      _previewUrl = url;
      await _playPreview();
    } else {
      // Fallback: search Spotify for preview
      try {
        final response = await _apiService.getSpotifyPreview(
          widget.artistName,
          widget.track['title'],
        );

        if (!mounted) return;

        if (response['success'] == true && response['preview_url'] != null) {
          _previewUrl = response['preview_url'];
          await _playPreview();
        } else {
          setState(() {
            _isLoading = false;
            _noPreviewAvailable = true;
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'No preview available for "${widget.track['title']}"',
                ),
                duration: const Duration(seconds: 2),
              ),
            );
          }
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Error: $e')));
        }
      }
    }
  }

  Future<void> _playPreview() async {
    if (_previewUrl == null) return;

    widget.onPreviewStarted(_stopPreviewImmediate);

    if (widget.mainAudioPlayer.isPlaying) {
      widget.mainAudioPlayer.togglePlayPause();
    }

    setState(() {
      _isPlaying = true;
      _isLoading = false;
      _progress = 0.0;
    });

    try {
      _previewPlayer = AudioPlayer();
      _fadeController.reset();
      await _previewPlayer!.setVolume(0);
      await _previewPlayer!.play(UrlSource(_previewUrl!));

      _fadeController.addListener(_updateVolume);
      _fadeController.forward();

      _progressTimer = Timer.periodic(const Duration(milliseconds: 100), (
        timer,
      ) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() {
          _progress += 100 / 30000;
          if (_progress >= 0.87 && _isPlaying) {
            _stopPreview(fadeOut: true);
          }
        });
      });

      _previewPlayer!.onPlayerComplete.listen((_) {
        if (mounted) {
          _stopPreview(fadeOut: true);
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _isLoading = false;
        });
        widget.onPreviewStopped();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error playing preview: $e')));
      }
    }
  }

  void _updateVolume() {
    _previewPlayer?.setVolume(_fadeController.value);
  }

  Future<void> _stopPreview({bool fadeOut = false}) async {
    if (_isStopping) return;
    _isStopping = true;

    _fadeController.removeListener(_updateVolume);

    if (_previewPlayer != null && fadeOut) {
      try {
        for (int i = 0; i < 60; i++) {
          if (_previewPlayer == null) break;
          double vol = 1.0 - (i / 60);
          await _previewPlayer!.setVolume(vol.clamp(0.0, 1.0));
          await Future.delayed(const Duration(milliseconds: 50));
        }
        await _previewPlayer?.setVolume(0);
        await Future.delayed(const Duration(milliseconds: 100));
      } catch (e) {
        // Player may have stopped
      }
    }

    _progressTimer?.cancel();
    _progressTimer = null;

    if (_previewPlayer != null) {
      try {
        await _previewPlayer!.stop();
        await _previewPlayer!.dispose();
      } catch (e) {
        // Ignore
      }
      _previewPlayer = null;
    }

    if (mounted) {
      setState(() {
        _isPlaying = false;
        _progress = 0.0;
      });
      _fadeController.reset();
      widget.onPreviewStopped();
    }

    _isStopping = false;
  }

  void _stopPreviewImmediate() {
    _progressTimer?.cancel();
    _progressTimer = null;
    _fadeController.removeListener(_updateVolume);

    _previewPlayer?.stop();
    _previewPlayer?.dispose();
    _previewPlayer = null;

    if (mounted) {
      setState(() {
        _isPlaying = false;
        _progress = 0.0;
      });
      _fadeController.reset();
      widget.onPreviewStopped();
    }
  }

  void _togglePreview() {
    if (_isPlaying) {
      _stopPreview(fadeOut: false);
    } else if (_previewUrl != null) {
      _playPreview();
    } else {
      _fetchAndPlayPreview();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24,
            child: Text(
              '${widget.index + 1}',
              style: const TextStyle(fontSize: 16, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 8),
          _CircularPreviewButton(
            isPlaying: _isPlaying,
            isLoading: _isLoading,
            progress: _progress,
            hasPreview: !_noPreviewAvailable,
            onTap: _noPreviewAvailable ? null : _togglePreview,
          ),
        ],
      ),
      title: Text(
        widget.track['title'],
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.grey),
      ),
      subtitle: _PopularityBar(
        popularity: widget.track['popularity'] ?? 0,
        playcount: widget.track['playcount'] as int?,
        suffix: 'Not in library',
      ),
      trailing: _noPreviewAvailable
          ? const Tooltip(
              message: 'No preview available',
              child: Icon(Icons.music_off, color: Colors.grey, size: 20),
            )
          : const Icon(Icons.cloud_outlined, color: Colors.orange, size: 20),
    );
  }
}

// =====================
// Circular Preview Button
// =====================

class _CircularPreviewButton extends StatelessWidget {
  final bool isPlaying;
  final bool isLoading;
  final double progress;
  final bool hasPreview;
  final VoidCallback? onTap;

  const _CircularPreviewButton({
    required this.isPlaying,
    required this.isLoading,
    required this.progress,
    required this.hasPreview,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 40,
        height: 40,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hasPreview
                    ? const Color(0xFF1a2332)
                    : const Color(0xFF1a2332).withOpacity(0.5),
                border: Border.all(
                  color: hasPreview
                      ? Colors.orange.withOpacity(0.3)
                      : Colors.grey.withOpacity(0.2),
                  width: 2,
                ),
              ),
            ),
            if (isPlaying)
              SizedBox(
                width: 40,
                height: 40,
                child: CustomPaint(
                  painter: _ProgressRingPainter(
                    progress: progress,
                    color: Colors.orange,
                  ),
                ),
              ),
            if (isLoading)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.orange,
                ),
              )
            else
              Icon(
                isPlaying ? Icons.pause : Icons.play_arrow,
                color: hasPreview ? Colors.orange : Colors.grey,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}

// =====================
// Progress Ring Painter
// =====================

class _ProgressRingPainter extends CustomPainter {
  final double progress;
  final Color color;

  _ProgressRingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_ProgressRingPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

class _EvhStripesPainter extends CustomPainter {
  static const Color evhRed = Color(0xFFE31937);
  static const Color evhWhite = Color(0xFFFFFFFF);
  static const Color evhBlack = Color(0xFF1A1A1A);

  // Frankie: red body, bold black tape slashes at every angle, thinner
  // white ones crossing them, and plenty of open red. Roughly 7 black and
  // 9 white strips on a phone, more on wider canvases, instead of the old
  // fixed layout that squeezed 23 fat stripes into a 400 px phone and left
  // no red at all. Seeded, so every build paints the same guitar.
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = evhRed,
    );

    int seed = 0x5EED;
    double rnd() {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed / 0x7fffffff;
    }

    final unit = math.min(size.width, size.height) / 430; // phone header = 1
    // Strips span the whole canvas whatever its width, so scale the count
    // by the square root of the width ratio: an ultrawide gets ~2x the
    // strips of a phone, not 4x.
    final spread = math.sqrt(math.max(1.0, size.width / 412));
    final nBlack = (7 * spread).round();
    final nWhite = (9 * spread).round();
    final length = math.max(size.width, size.height) * 3;

    void strip(Color color, double width) {
      canvas.save();
      canvas.translate(rnd() * size.width, rnd() * size.height);
      canvas.rotate((rnd() - 0.5) * 3.0); // -86°..+86° off vertical
      canvas.drawRect(
        Rect.fromCenter(center: Offset.zero, width: width, height: length),
        Paint()..color = color,
      );
      canvas.restore();
    }

    for (var i = 0; i < nWhite; i++) {
      strip(evhWhite, (7 + rnd() * 6) * unit);
    }
    for (var i = 0; i < nBlack; i++) {
      strip(evhBlack, (12 + rnd() * 9) * unit);
    }

    // Slight dark vignette at the bottom so text remains readable
    canvas.drawRect(
      Rect.fromLTWH(0, size.height * 0.7, size.width, size.height * 0.3),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Color(0xCC000000)],
        ).createShader(
          Rect.fromLTWH(0, size.height * 0.7, size.width, size.height * 0.3),
        ),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
