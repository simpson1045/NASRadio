import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:audioplayers/audioplayers.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import 'now_playing_screen.dart';
import '../widgets/mouse_back_button_wrapper.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'prowlarr_search_screen.dart';
import '../utils/text_utils.dart';
import '../widgets/explicit_badge.dart';
import '../widgets/hdcd_badge.dart';
import '../widgets/surround_badge.dart';
import '../widgets/music_context_menu.dart';
import '../widgets/design_system.dart';

class PlaylistDetailScreen extends StatefulWidget {
  final int playlistId;
  final AudioPlayerService audioPlayerService;

  const PlaylistDetailScreen({
    super.key,
    required this.playlistId,
    required this.audioPlayerService,
  });

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  final ApiService _apiService = ApiService();
  Playlist? _playlist;
  List<Map<String, dynamic>> _allItems =
      []; // Combined list with position order
  List<Song> _songs = []; // Just the available songs for playback
  bool _isLoading = true;
  String? _error;
  String _searchQuery = '';
  bool _showMissingOnly = false;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  // Selection mode state
  bool _isSelectMode = false;
  final Set<int> _selectedIndices = {};

  // Search controller
  final TextEditingController _searchController = TextEditingController();

  // Scroll controller for position preservation
  final ScrollController _scrollController = ScrollController();

  // Preview playback state
  int? _currentlyPlayingIndex;
  VoidCallback? _stopCurrentPreview;

  // Dominant color sampled from the first album in the playlist mosaic.
  // Drives the gradient backdrop on the hero. Null until extraction
  // completes; the backdrop falls back to a neutral gray in that
  // window so the UI doesn't flash.
  Color? _dominantColor;

  List<Map<String, dynamic>> get _filteredItems {
    var items = _allItems;

    // Filter by missing only if enabled
    if (_showMissingOnly) {
      items = items.where((item) => item['available'] != true).toList();
    }

    // Then filter by search query
    if (_searchQuery.isEmpty) return items;

    final terms = normalizeTextForSearch(
      _searchQuery,
    ).split(' ').where((t) => t.isNotEmpty).toList();

    return items.where((item) {
      if (item['available'] == true) {
        final song = item['song'] as Song;
        final combined = normalizeTextForSearch(
          '${song.title} ${song.artistName} ${song.albumTitle}',
        );
        return terms.every((term) => combined.contains(term));
      } else {
        final combined = normalizeTextForSearch(
          '${item['spotify_track_name'] ?? ''} ${item['spotify_artist'] ?? ''}',
        );
        return terms.every((term) => combined.contains(term));
      }
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _loadPlaylist();
    widget.audioPlayerService.addListener(_onMainPlayerChanged);
  }

  @override
  void dispose() {
    widget.audioPlayerService.removeListener(_onMainPlayerChanged);
    _searchController.dispose();
    _scrollController.dispose(); // Add this line
    super.dispose();
  }

  void _onMainPlayerChanged() {
    // If main player starts playing, stop any preview
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

  Future<void> _loadPlaylist({bool preserveScroll = false}) async {
    final scrollOffset = preserveScroll && _scrollController.hasClients
        ? _scrollController.offset
        : null;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final data = await _apiService.getPlaylist(widget.playlistId);

      // Widget can be disposed during the await above (user navigates
      // away mid-fetch). setState on a disposed State throws "Null check
      // operator used on a null value" — caught a 2026-05-23 crash.
      if (!mounted) return;
      setState(() {
        _playlist = Playlist.fromJson(data);

        // Parse all items maintaining position order
        final songsData = data['songs'] as List;
        _allItems = [];
        _songs = [];

        for (final json in songsData) {
          final available = json['available'] == 1;

          if (available) {
            final song = Song.fromJson(json);
            _songs.add(song);
            _allItems.add({
              'available': true,
              'song': song,
              'position': json['position'],
            });
          } else {
            _allItems.add({
              'available': false,
              'spotify_track_name': json['spotify_track_name'],
              'spotify_artist': json['spotify_artist'],
              'spotify_album': json['spotify_album'],
              'spotify_track_id': json['spotify_track_id'],
              'mbid': json['mbid'],
              'position': json['position'],
            });
          }
        }

        // Sort by position
        _allItems.sort(
          (a, b) => (a['position'] as int).compareTo(b['position'] as int),
        );

        _isLoading = false;
      });

      // Kick off dominant color extraction for the hero gradient
      // backdrop. Not awaited; UI renders immediately with a neutral
      // fallback and re-paints when the color arrives.
      _extractPlaylistDominantColor();

      // Restore scroll position if requested
      if (scrollOffset != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(scrollOffset);
          }
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Widget _buildPlaylistArtwork() {
    // Get unique album IDs from songs
    final albumIds = <int>[];
    final seen = <int>{};
    for (final song in _songs) {
      if (!seen.contains(song.albumId)) {
        seen.add(song.albumId);
        albumIds.add(song.albumId);
        if (albumIds.length >= 4) break;
      }
    }

    if (albumIds.isEmpty) {
      return const Icon(
        Icons.playlist_play,
        size: 100,
        color: Color(0xFF00d4ff),
      );
    }

    if (albumIds.length < 4) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CachedNetworkImage(
          imageUrl: _apiService.getArtworkUrl(albumIds.first),
          width: 200,
          height: 200,
          fit: BoxFit.cover,
          placeholder: (context, url) => Container(
            width: 200,
            height: 200,
            color: const Color(0xFF1a2332),
          ),
          errorWidget: (context, url, error) => const Icon(
            Icons.playlist_play,
            size: 100,
            color: Color(0xFF00d4ff),
          ),
        ),
      );
    }

    // 2x2 grid
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 200,
        height: 200,
        child: GridView.count(
          crossAxisCount: 2,
          physics: const NeverScrollableScrollPhysics(),
          children: albumIds.take(4).map((albumId) {
            return CachedNetworkImage(
              imageUrl: _apiService.getArtworkUrl(albumId),
              fit: BoxFit.cover,
              placeholder: (context, url) =>
                  Container(color: const Color(0xFF1a2332)),
              errorWidget: (context, url, error) =>
                  Container(color: const Color(0xFF1a2332)),
            );
          }).toList(),
        ),
      ),
    );
  }

  Future<void> _extractPlaylistDominantColor() async {
    // Pull the first unique-album cover from the songs and sample its
    // dominant color. The mosaic banner is now native-sized on the
    // left rather than stretched-cropped to the full banner; the
    // dominant color carries the visual continuity to the rest of
    // the hero.
    int? firstAlbumId;
    final seen = <int>{};
    for (final song in _songs) {
      if (!seen.contains(song.albumId)) {
        firstAlbumId = song.albumId;
        break;
      }
      seen.add(song.albumId);
    }
    if (firstAlbumId == null) return;
    final url = _apiService.getArtworkUrl(firstAlbumId);
    final color =
        await extractDominantColor(CachedNetworkImageProvider(url));
    if (!mounted || color == null) return;
    setState(() => _dominantColor = color);
  }

  Widget _buildHeaderBackground() {
    // Spotify-pattern hero: 2x2 album mosaic at native fixed size on
    // the upper-left, dominant-color gradient backdrop fills the rest.
    // Replaces the previous full-bleed BoxFit.cover that stretched the
    // mosaic into vertical slivers on ultrawide displays (simpson1045's
    // complaint: "I don't like how the image is taking up the entire
    // banner section, so I can't see it all").
    // Larger mosaic on desktop (the 220px version looked small dwarfed
    // by a wide banner); smaller on mobile.
    final double mosaicSize = _isMobile ? 200 : 300;
    final albumIds = <int>[];
    final seen = <int>{};
    for (final song in _songs) {
      if (!seen.contains(song.albumId)) {
        seen.add(song.albumId);
        albumIds.add(song.albumId);
        if (albumIds.length >= 4) break;
      }
    }

    Widget artworkBlock;
    if (albumIds.isEmpty) {
      artworkBlock = Container(
        width: mosaicSize,
        height: mosaicSize,
        decoration: BoxDecoration(
          color: const Color(0xFF1a2332),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(
          Icons.playlist_play,
          size: 80,
          color: Color(0xFF00d4ff),
        ),
      );
    } else if (albumIds.length < 4) {
      artworkBlock = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: mosaicSize,
          height: mosaicSize,
          child: CachedNetworkImage(
            imageUrl: _apiService.getArtworkUrl(albumIds.first),
            fit: BoxFit.cover,
            placeholder: (context, url) =>
                Container(color: const Color(0xFF1a2332)),
            errorWidget: (context, url, error) => Container(
              color: const Color(0xFF1a2332),
              child: const Icon(
                Icons.playlist_play,
                size: 80,
                color: Color(0xFF00d4ff),
              ),
            ),
          ),
        ),
      );
    } else {
      // Proper 2x2 mosaic at native square aspect — each cover is
      // 110x110 and recognizable, instead of being stretched to a
      // vertical sliver across the banner width.
      artworkBlock = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: mosaicSize,
          height: mosaicSize,
          child: GridView.count(
            crossAxisCount: 2,
            physics: const NeverScrollableScrollPhysics(),
            children: albumIds.take(4).map((albumId) {
              return CachedNetworkImage(
                imageUrl: _apiService.getArtworkUrl(albumId),
                fit: BoxFit.cover,
                placeholder: (context, url) =>
                    Container(color: const Color(0xFF1a2332)),
                errorWidget: (context, url, error) =>
                    Container(color: const Color(0xFF1a2332)),
              );
            }).toList(),
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Diagonal gradient from the dominant color toward the page bg.
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(
                      _dominantColor ?? const Color(0xFF1a2332),
                      const Color(0xFF0d1b2a),
                      0.35,
                    ) ??
                    const Color(0xFF1a2332),
                const Color(0xFF0d1b2a),
              ],
            ),
          ),
        ),
        // Radial glow centered on the mosaic so the dominant color
        // reads strongly behind the artwork.
        Container(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-0.6, -0.2),
              radius: 1.2,
              colors: [
                (_dominantColor ?? Colors.transparent).withOpacity(0.45),
                Colors.transparent,
              ],
            ),
          ),
        ),
        // Bottom fade for legibility of the title row.
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                const Color(0xFF0d1b2a).withOpacity(0.4),
                const Color(0xFF0d1b2a),
              ],
              stops: const [0.5, 0.85, 1.0],
            ),
          ),
        ),
        // Native-size mosaic CENTERED near the top. Text sits in a band
        // below (mirrors artist-detail layout). Each of the 4 covers is
        // recognizable instead of sliver-stretched.
        Positioned(
          top: 24,
          left: 0,
          right: 0,
          child: Center(child: artworkBlock),
        ),
      ],
    );
  }

  void _playSong(Song song, int index) {
    _apiService.markPlaylistPlayed(widget.playlistId);
    widget.audioPlayerService.setQueue(
      _songs,
      index,
      sourceType: 'playlist',
      sourceId: widget.playlistId,
      sourceName: _playlist?.name,
    );
    NowPlayingScreen.open(
      context,
      audioPlayerService: widget.audioPlayerService,
    );
  }

  Widget _buildPlaylistItem(Map<String, dynamic> item, int displayIndex) {
    final isAvailable = item['available'] == true;
    final isSelected = _selectedIndices.contains(displayIndex);

    if (isAvailable) {
      final song = item['song'] as Song;
      final songIndex = _songs.indexOf(song);

      return ListTile(
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isSelectMode)
              SizedBox(
                width: 32,
                child: Checkbox(
                  value: isSelected,
                  onChanged: (value) => _toggleSelection(displayIndex),
                  activeColor: const Color(0xFF00d4ff),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            SizedBox(
              width: _isSelectMode ? 28 : 36,
              child: Text(
                '${item['position']}',
                style: TextStyle(
                  fontSize: _isSelectMode ? 12 : 14,
                  color: Colors.grey,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(width: 8),
            ClipRRect(
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
          ],
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(song.title),
            ),
            if (song.isExplicit) ...[              const SizedBox(width: 6),
              const ExplicitBadge(fontSize: 10),
            ],
            if (song.isAtmos || song.isSurround) ...[
              const SizedBox(width: 6),
              SpatialBadge(song: song, fontSize: 10),
            ],
            if (song.isHdcd) ...[
              const SizedBox(width: 6),
              const HdcdBadge(fontSize: 10),
            ],
          ],
        ),
        subtitle: Text(
          song.artistName,
          style: const TextStyle(
            color: Colors.grey,
            fontWeight: FontWeight.w500,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(song.durationFormatted),
            const SizedBox(width: 8),
            if (!_isSelectMode) ...[
              ReorderableDragStartListener(
                index: displayIndex,
                child: const Icon(Icons.drag_handle, color: Colors.grey),
              ),
              const SizedBox(width: 4),
            ],
            // Unified context menu (v1.1.0). Replaces the previous
            // 3-item playlist-only menu (Move / Replace / Remove). Now
            // surfaces the full set of song actions — Go to Album, Go
            // to Artist, Play Next, Add to Queue, Add to Playlist,
            // Favorite, Analysis Details, Show File Location, Edit
            // Metadata — plus the playlist-specific Move / Replace /
            // Remove via the new onReplaceSong / onRemoveFromPlaylist
            // callbacks (which gate visibility of those items inside
            // MusicContextMenu).
            MusicContextMenu(
              itemType: 'song',
              itemId: song.id,
              itemName: song.displayTitle,
              audioPlayerService: widget.audioPlayerService,
              onMoveToPosition: () =>
                  _showMoveToPositionDialog(song, displayIndex),
              onReplaceSong: () =>
                  _showReplaceSongDialog(song, displayIndex),
              onRemoveFromPlaylist: () => _removeSong(song),
            ),
            // Extra padding on desktop to avoid scrollbar overlap
            if (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
              const SizedBox(width: 12),
          ],
        ),
        onTap: () {
          if (_isSelectMode) {
            _toggleSelection(displayIndex);
          } else {
            _playSong(song, songIndex);
          }
        },
      );
    } else {
      // Unavailable song - use separate widget for preview support
      return _UnavailableTrackTile(
        key: ValueKey('unavailable_$displayIndex'),
        index: displayIndex,
        trackName: item['spotify_track_name'] ?? 'Unknown Track',
        artistName: item['spotify_artist'] ?? 'Unknown Artist',
        albumName: item['spotify_album'] ?? '',
        spotifyTrackId: item['spotify_track_id'],
        mbid: item['mbid'],
        mainAudioPlayer: widget.audioPlayerService,
        isCurrentlyPlaying: _currentlyPlayingIndex == displayIndex,
        shouldStop:
            _currentlyPlayingIndex != null &&
            _currentlyPlayingIndex != displayIndex,
        onPreviewStarted: (stopCallback) =>
            _onPreviewStarted(displayIndex, stopCallback),
        onPreviewStopped: _onPreviewStopped,
        playlistId: widget.playlistId,
        onSongLinked: () => _loadPlaylist(preserveScroll: true),
      );
    }
  }

  Future<void> _showEditDialog() async {
    if (_playlist == null) return;

    final TextEditingController nameController = TextEditingController(
      text: _playlist!.name,
    );
    final TextEditingController descriptionController = TextEditingController(
      text: _playlist!.description ?? '',
    );

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Playlist'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Playlist Name',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: descriptionController,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00d4ff),
              foregroundColor: Colors.black,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result == true && nameController.text.trim().isNotEmpty) {
      try {
        await _apiService.updatePlaylist(
          widget.playlistId,
          nameController.text.trim(),
          descriptionController.text.trim().isEmpty
              ? null
              : descriptionController.text.trim(),
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Playlist updated'),
              backgroundColor: Colors.green,
            ),
          );
          _loadPlaylist();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  Future<void> _removeSong(Song song) async {
    try {
      await _apiService.removeSongFromPlaylist(widget.playlistId, song.id);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Removed "${song.title}" from playlist'),
            backgroundColor: Colors.green,
          ),
        );
        _loadPlaylist();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _showReplaceSongDialog(Song oldSong, int position) async {
    // Pre-fill search with song title and artist
    final initialQuery = '${oldSong.title} ${oldSong.artistName}';
    final searchController = TextEditingController(text: initialQuery);
    List<Song> searchResults = [];
    bool isSearching = true; // Start loading immediately
    bool initialSearchDone = false;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          // Perform initial search on first build
          if (!initialSearchDone) {
            initialSearchDone = true;
            _apiService
                .search(initialQuery)
                .then((results) {
                  final songs = (results['songs'] as List)
                      .map((json) => Song.fromJson(json))
                      .toList();
                  setDialogState(() {
                    searchResults = songs;
                    isSearching = false;
                  });
                })
                .catchError((e) {
                  setDialogState(() {
                    isSearching = false;
                  });
                });
          }

          return AlertDialog(
            title: Text('Replace "${oldSong.title}"'),
            content: SizedBox(
              width: 500,
              height: 400,
              child: Column(
                children: [
                  TextField(
                    controller: searchController,
                    decoration: InputDecoration(
                      hintText: 'Search by title, artist, or album...',
                      prefixIcon: const Icon(
                        Icons.search,
                        color: Color(0xFF00d4ff),
                      ),
                      suffixIcon: searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, color: Colors.grey),
                              onPressed: () {
                                searchController.clear();
                                setDialogState(() {
                                  searchResults = [];
                                });
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: const Color(0xFF0d1b2a),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (value) async {
                      if (value.length >= 2) {
                        setDialogState(() {
                          isSearching = true;
                        });

                        try {
                          final results = await _apiService.search(value);
                          final songs = (results['songs'] as List)
                              .map((json) => Song.fromJson(json))
                              .toList();

                          setDialogState(() {
                            searchResults = songs;
                            isSearching = false;
                          });
                        } catch (e) {
                          setDialogState(() {
                            isSearching = false;
                          });
                        }
                      } else {
                        setDialogState(() {
                          searchResults = [];
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: isSearching
                        ? const Center(child: CircularProgressIndicator())
                        : searchResults.isEmpty
                        ? Center(
                            child: Text(
                              searchController.text.isEmpty
                                  ? 'Type to search for a replacement song'
                                  : 'No results found',
                              style: const TextStyle(color: Colors.grey),
                            ),
                          )
                        : ListView.builder(
                            itemCount: searchResults.length,
                            itemBuilder: (context, index) {
                              final song = searchResults[index];
                              return ListTile(
                                leading: ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: CachedNetworkImage(
                                    imageUrl: _apiService.getArtworkUrl(
                                      song.albumId,
                                    ),
                                    width: 40,
                                    height: 40,
                                    fit: BoxFit.cover,
                                    placeholder: (context, url) => Container(
                                      width: 40,
                                      height: 40,
                                      color: const Color(0xFF1a2332),
                                    ),
                                    errorWidget: (context, url, error) =>
                                        Container(
                                          width: 40,
                                          height: 40,
                                          color: const Color(0xFF0d1b2a),
                                          child: const Icon(
                                            Icons.music_note,
                                            color: Color(0xFF00d4ff),
                                            size: 20,
                                          ),
                                        ),
                                  ),
                                ),
                                title: Text(song.title),
                                subtitle: Text(
                                  '${song.artistName} • ${song.albumTitle}',
                                  style: const TextStyle(color: Colors.grey),
                                ),
                                onTap: () async {
                                  Navigator.pop(context);

                                  try {
                                    // Get actual playlist position before removing
                                    final actualPosition =
                                        _allItems.firstWhere(
                                              (item) =>
                                                  item['available'] == true &&
                                                  (item['song'] as Song).id ==
                                                      oldSong.id,
                                            )['position']
                                            as int;

                                    // Remove old song
                                    await _apiService.removeSongFromPlaylist(
                                      widget.playlistId,
                                      oldSong.id,
                                    );

                                    // Add new song at the same position
                                    await _apiService.addSongToPlaylist(
                                      widget.playlistId,
                                      song.id,
                                      position: actualPosition,
                                    );

                                    if (mounted) {
                                      // Optimistic UI update - replace in both lists
                                      setState(() {
                                        // Find and update in _allItems
                                        final itemIndex = _allItems.indexWhere(
                                          (item) =>
                                              item['available'] == true &&
                                              (item['song'] as Song).id ==
                                                  oldSong.id,
                                        );
                                        if (itemIndex >= 0) {
                                          _allItems[itemIndex] = {
                                            'available': true,
                                            'song': song,
                                            'position':
                                                _allItems[itemIndex]['position'],
                                          };
                                        }

                                        // Find and update in _songs
                                        final songIndex = _songs.indexWhere(
                                          (s) => s.id == oldSong.id,
                                        );
                                        if (songIndex >= 0) {
                                          _songs[songIndex] = song;
                                        }
                                      });

                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            'Replaced "${oldSong.title}" with "${song.title}"',
                                          ),
                                          backgroundColor: Colors.green,
                                        ),
                                      );
                                    }
                                  } catch (e) {
                                    if (mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text('Error: $e'),
                                          backgroundColor: Colors.red,
                                        ),
                                      );
                                    }
                                  }
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _toggleSelectMode() {
    setState(() {
      _isSelectMode = !_isSelectMode;
      _selectedIndices.clear();
    });
  }

  void _toggleSelection(int index) {
    setState(() {
      if (_selectedIndices.contains(index)) {
        _selectedIndices.remove(index);
      } else {
        _selectedIndices.add(index);
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selectedIndices.clear();
      for (int i = 0; i < _filteredItems.length; i++) {
        if (_filteredItems[i]['available'] == true) {
          _selectedIndices.add(i);
        }
      }
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedIndices.clear();
    });
  }

  Future<void> _bulkMoveSelected() async {
    if (_selectedIndices.isEmpty) return;

    final controller = TextEditingController();
    final maxPosition = _allItems.length;

    // Get selected songs with their positions, then sort by position to maintain order
    final selectedSongs = _selectedIndices
        .where(
          (i) =>
              i < _filteredItems.length &&
              _filteredItems[i]['available'] == true,
        )
        .map((i) => _filteredItems[i])
        .toList();

    // Sort by actual playlist position
    selectedSongs.sort(
      (a, b) => (a['position'] as int).compareTo(b['position'] as int),
    );

    final selectedSongIds = selectedSongs
        .map((item) => (item['song'] as Song).id)
        .toList();

    if (selectedSongIds.isEmpty) return;

    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Move ${selectedSongIds.length} Songs'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Move selected songs to position:',
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'New position (1-$maxPosition)',
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (value) {
                final pos = int.tryParse(value);
                if (pos != null && pos >= 1 && pos <= maxPosition) {
                  Navigator.pop(context, pos);
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final pos = int.tryParse(controller.text);
              if (pos != null && pos >= 1 && pos <= maxPosition) {
                Navigator.pop(context, pos);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00d4ff),
              foregroundColor: Colors.black,
            ),
            child: const Text('Move'),
          ),
        ],
      ),
    );

    if (result != null) {
      try {
        await _apiService.bulkReorderPlaylistSongs(
          widget.playlistId,
          selectedSongIds,
          result,
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Moved ${selectedSongIds.length} songs to position $result',
              ),
              backgroundColor: Colors.green,
            ),
          );
          setState(() {
            _isSelectMode = false;
            _selectedIndices.clear();
          });
          _loadPlaylist();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  Future<void> _removeSelectedSongs() async {
    if (_selectedIndices.isEmpty) return;

    final selectedSongs = _selectedIndices
        .where(
          (i) =>
              i < _filteredItems.length &&
              _filteredItems[i]['available'] == true,
        )
        .map((i) => _filteredItems[i]['song'] as Song)
        .toList();

    if (selectedSongs.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Songs'),
        content: Text(
          'Remove ${selectedSongs.length} songs from this playlist?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      for (final song in selectedSongs) {
        await _apiService.removeSongFromPlaylist(widget.playlistId, song.id);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Removed ${selectedSongs.length} songs from playlist',
            ),
            backgroundColor: Colors.green,
          ),
        );
        setState(() {
          _isSelectMode = false;
          _selectedIndices.clear();
        });
        _loadPlaylist();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _showMoveToPositionDialog(Song song, int currentIndex) async {
    final controller = TextEditingController();
    final maxPosition = _allItems.length;

    // Find actual index and position in _allItems
    final actualIndex = _allItems.indexWhere(
      (item) =>
          item['available'] == true && (item['song'] as Song).id == song.id,
    );
    final actualPosition = _allItems[actualIndex]['position'] as int;

    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Move "${song.title}"'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Current position: $actualPosition',
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'New position (1-$maxPosition)',
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (value) {
                final pos = int.tryParse(value);
                if (pos != null && pos >= 1 && pos <= maxPosition) {
                  Navigator.pop(context, pos);
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final pos = int.tryParse(controller.text);
              if (pos != null && pos >= 1 && pos <= maxPosition) {
                Navigator.pop(context, pos);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00d4ff),
              foregroundColor: Colors.black,
            ),
            child: const Text('Move'),
          ),
        ],
      ),
    );

    if (result != null) {
      final newIndex = result - 1; // Convert to 0-based
      if (newIndex != actualIndex) {
        // Update local state
        final item = _allItems[actualIndex];
        setState(() {
          _allItems.removeAt(actualIndex);
          _allItems.insert(newIndex, item);

          // Renumber all positions to match new order
          for (int i = 0; i < _allItems.length; i++) {
            _allItems[i]['position'] = i + 1;
          }
        });

        // Update backend
        try {
          await _apiService.reorderPlaylistSong(
            widget.playlistId,
            song.id,
            result, // 1-based position
          );
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
            );
            _loadPlaylist();
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isMobile) {
      return _buildMobileLayout();
    }
    return _buildDesktopLayout();
  }

  Widget _buildMobileLayout() {
    final screenWidth = MediaQuery.of(context).size.width;
    final artworkSize = (screenWidth * 0.35).clamp(100.0, 140.0);

    return MouseBackButtonWrapper(
      child: Scaffold(
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(child: Text('Error: $_error'))
            : Stack(
                children: [
                  CustomScrollView(
                    controller: _scrollController,
                    slivers: [
                      // App bar with playlist artwork
                      // App bar with playlist artwork
                      SliverAppBar(
                        expandedHeight: _isMobile ? 400 : 500,
                        pinned: true,
                        backgroundColor: const Color(0xFF0d1b2a),
                        flexibleSpace: FlexibleSpaceBar(
                          background: Stack(
                            fit: StackFit.expand,
                            children: [
                              _buildHeaderBackground(),
                              // Playlist info anchored right of the
                              // 220x220 cover (cover ends at left:24+220=244,
                              // Info band at bottom-left, below centered mosaic.
                              Positioned(
                                left: 24,
                                right:
                                    Platform.isWindows ||
                                        Platform.isLinux ||
                                        Platform.isMacOS
                                    ? 32
                                    : 16,
                                bottom: 16,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // Playlist name with edit button
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            _playlist?.name ?? 'Playlist',
                                            style: const TextStyle(
                                              fontSize: 24,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                        IconButton(
                                          icon: const Icon(
                                            Icons.edit,
                                            color: Colors.white70,
                                            size: 22,
                                          ),
                                          onPressed: _showEditDialog,
                                        ),
                                      ],
                                    ),
                                    if (_playlist?.description?.isNotEmpty ??
                                        false) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        _playlist!.description!,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                    const SizedBox(height: 4),
                                    Text(
                                      '${_songs.length} songs',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Action buttons
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: _songs.isEmpty
                                          ? null
                                          : () {
                                              widget.audioPlayerService
                                                  .setQueue(
                                                    _songs,
                                                    0,
                                                    sourceType: 'playlist',
                                                    sourceId: widget.playlistId,
                                                    sourceName: _playlist?.name,
                                                  );
                                              NowPlayingScreen.open(
                                                context,
                                                audioPlayerService:
                                                    widget.audioPlayerService,
                                              );
                                            },
                                      icon: const Icon(
                                        Icons.play_arrow,
                                        size: 18,
                                      ),
                                      label: const Text('Play'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFF00d4ff,
                                        ),
                                        foregroundColor: Colors.black,
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 10,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: _songs.isEmpty
                                          ? null
                                          : () {
                                              final randomIndex =
                                                  (List.generate(
                                                    _songs.length,
                                                    (i) => i,
                                                  )..shuffle()).first;
                                              widget.audioPlayerService
                                                  .setQueue(
                                                    _songs,
                                                    randomIndex,
                                                    sourceType: 'playlist',
                                                    sourceId: widget.playlistId,
                                                    sourceName: _playlist?.name,
                                                  );
                                              if (!widget
                                                  .audioPlayerService
                                                  .isShuffled) {
                                                widget.audioPlayerService
                                                    .toggleShuffle();
                                              }
                                              NowPlayingScreen.open(
                                                context,
                                                audioPlayerService:
                                                    widget.audioPlayerService,
                                              );
                                            },
                                      icon: const Icon(Icons.shuffle, size: 18),
                                      label: const Text('Shuffle'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFF1a2332,
                                        ),
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 10,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: _songs.isEmpty
                                          ? null
                                          : _toggleSelectMode,
                                      icon: Icon(
                                        _isSelectMode
                                            ? Icons.close
                                            : Icons.checklist,
                                        size: 16,
                                      ),
                                      label: Text(
                                        _isSelectMode ? 'Cancel' : 'Select',
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: _isSelectMode
                                            ? Colors.grey
                                            : const Color(0xFF1a2332),
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 8,
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (_isSelectMode &&
                                      _selectedIndices.isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: ElevatedButton.icon(
                                        icon: const Icon(
                                          Icons.open_with,
                                          size: 16,
                                        ),
                                        label: Text(
                                          'Move (${_selectedIndices.length})',
                                        ),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(
                                            0xFF00d4ff,
                                          ),
                                          foregroundColor: Colors.black,
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 8,
                                          ),
                                        ),
                                        onPressed: _bulkMoveSelected,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.red,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 8,
                                          horizontal: 12,
                                        ),
                                      ),
                                      onPressed: _removeSelectedSongs,
                                      child: const Icon(
                                        Icons.delete_outline,
                                        size: 18,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Pinned search bar
                      SliverPersistentHeader(
                        pinned: true,
                        delegate: _SearchBarDelegate(
                          searchQuery: _searchQuery,
                          controller: _searchController,
                          onChanged: (value) {
                            setState(() {
                              _searchQuery = value;
                            });
                          },
                          onClear: () {
                            _searchController.clear();
                            setState(() {
                              _searchQuery = '';
                            });
                          },
                          showMissingOnly: _showMissingOnly,
                          onMissingFilterChanged: (value) {
                            setState(() {
                              _showMissingOnly = value;
                            });
                          },
                          missingCount: _allItems
                              .where((item) => item['available'] != true)
                              .length,
                        ),
                      ),
                      // Song list
                      if (_filteredItems.isEmpty)
                        SliverFillRemaining(
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.music_note,
                                  size: 60,
                                  color: Colors.grey,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  _searchQuery.isEmpty
                                      ? 'No songs in this playlist'
                                      : 'No songs match "$_searchQuery"',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        SliverList(
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            return _buildPlaylistItem(
                              _filteredItems[index],
                              index,
                            );
                          }, childCount: _filteredItems.length),
                        ),
                      // Bottom padding for mini player
                      SliverPadding(
                        padding: EdgeInsets.only(
                          bottom: _isSelectMode ? 140 : 80,
                        ),
                      ),
                    ],
                  ),
                  // Floating selection bar
                  if (_isSelectMode)
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 70,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1a2332),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.3),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Text(
                              '${_selectedIndices.length}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF00d4ff),
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: _selectAll,
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                minimumSize: Size.zero,
                              ),
                              child: const Text(
                                'All',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                            const Spacer(),
                            if (_selectedIndices.isNotEmpty) ...[
                              ElevatedButton(
                                onPressed: _bulkMoveSelected,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF00d4ff),
                                  foregroundColor: Colors.black,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                ),
                                child: const Text(
                                  'Move',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                              const SizedBox(width: 6),
                              ElevatedButton(
                                onPressed: _removeSelectedSongs,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                ),
                                child: const Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                ),
                              ),
                            ],
                            const SizedBox(width: 6),
                            IconButton(
                              onPressed: _toggleSelectMode,
                              icon: const Icon(Icons.close, size: 20),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              tooltip: 'Exit select mode',
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Widget _buildDesktopLayout() {
    return MouseBackButtonWrapper(
      child: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(child: Text('Error: $_error'))
                  : Stack(
                      children: [
                        CustomScrollView(
                          controller: _scrollController,
                          slivers: [
                            // App bar with playlist artwork
                            SliverAppBar(
                              expandedHeight: _isMobile ? 400 : 500,
                              pinned: true,
                              backgroundColor: const Color(0xFF0d1b2a),
                              flexibleSpace: FlexibleSpaceBar(
                                background: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    _buildHeaderBackground(),
                                    // Info band at bottom-left, below
                                    // the centered mosaic.
                                    Positioned(
                                      left: 24,
                                      right: 16,
                                      bottom: 16,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          // Playlist name with edit button
                                          Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  _playlist?.name ?? 'Playlist',
                                                  style: const TextStyle(
                                                    fontSize: 28,
                                                    fontWeight: FontWeight.bold,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                              ),
                                              IconButton(
                                                icon: const Icon(
                                                  Icons.edit,
                                                  color: Colors.white70,
                                                ),
                                                onPressed: _showEditDialog,
                                              ),
                                            ],
                                          ),
                                          if (_playlist
                                                  ?.description
                                                  ?.isNotEmpty ??
                                              false) ...[
                                            const SizedBox(height: 4),
                                            Text(
                                              _playlist!.description!,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                color: Colors.grey,
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                          const SizedBox(height: 8),
                                          Text(
                                            '${_songs.length} songs',
                                            style: const TextStyle(
                                              fontSize: 14,
                                              color: Colors.grey,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            // Action buttons
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: ElevatedButton.icon(
                                            onPressed: _songs.isEmpty
                                                ? null
                                                : () {
                                                    widget.audioPlayerService
                                                        .setQueue(
                                                          _songs,
                                                          0,
                                                          sourceType:
                                                              'playlist',
                                                          sourceId:
                                                              widget.playlistId,
                                                          sourceName:
                                                              _playlist?.name,
                                                        );
                                                    NowPlayingScreen.open(
                                                      context,
                                                      audioPlayerService: widget
                                                          .audioPlayerService,
                                                    );
                                                  },
                                            icon: const Icon(
                                              Icons.play_arrow,
                                              size: 20,
                                            ),
                                            label: const Text('Play'),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: const Color(
                                                0xFF00d4ff,
                                              ),
                                              foregroundColor: Colors.black,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 12,
                                                  ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: ElevatedButton.icon(
                                            onPressed: _songs.isEmpty
                                                ? null
                                                : () {
                                                    final randomIndex =
                                                        (List.generate(
                                                          _songs.length,
                                                          (i) => i,
                                                        )..shuffle()).first;
                                                    widget.audioPlayerService
                                                        .setQueue(
                                                          _songs,
                                                          randomIndex,
                                                          sourceType:
                                                              'playlist',
                                                          sourceId:
                                                              widget.playlistId,
                                                          sourceName:
                                                              _playlist?.name,
                                                        );
                                                    if (!widget
                                                        .audioPlayerService
                                                        .isShuffled) {
                                                      widget.audioPlayerService
                                                          .toggleShuffle();
                                                    }
                                                    NowPlayingScreen.open(
                                                      context,
                                                      audioPlayerService: widget
                                                          .audioPlayerService,
                                                    );
                                                  },
                                            icon: const Icon(
                                              Icons.shuffle,
                                              size: 20,
                                            ),
                                            label: const Text('Shuffle'),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: const Color(
                                                0xFF1a2332,
                                              ),
                                              foregroundColor: Colors.white,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 12,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: ElevatedButton.icon(
                                            onPressed: _songs.isEmpty
                                                ? null
                                                : _toggleSelectMode,
                                            icon: Icon(
                                              _isSelectMode
                                                  ? Icons.close
                                                  : Icons.checklist,
                                              size: 18,
                                            ),
                                            label: Text(
                                              _isSelectMode
                                                  ? 'Cancel'
                                                  : 'Select',
                                            ),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: _isSelectMode
                                                  ? Colors.grey
                                                  : const Color(0xFF1a2332),
                                              foregroundColor: Colors.white,
                                            ),
                                          ),
                                        ),
                                        if (_isSelectMode &&
                                            _selectedIndices.isNotEmpty) ...[
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: ElevatedButton.icon(
                                              icon: const Icon(
                                                Icons.open_with,
                                                size: 18,
                                              ),
                                              label: Text(
                                                'Move (${_selectedIndices.length})',
                                              ),
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: const Color(
                                                  0xFF00d4ff,
                                                ),
                                                foregroundColor: Colors.black,
                                              ),
                                              onPressed: _bulkMoveSelected,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          ElevatedButton.icon(
                                            icon: const Icon(
                                              Icons.delete_outline,
                                              size: 18,
                                            ),
                                            label: Text(
                                              'Delete (${_selectedIndices.length})',
                                            ),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.red,
                                              foregroundColor: Colors.white,
                                            ),
                                            onPressed: _removeSelectedSongs,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // Pinned search bar
                            SliverPersistentHeader(
                              pinned: true,
                              delegate: _SearchBarDelegate(
                                searchQuery: _searchQuery,
                                controller: _searchController,
                                onChanged: (value) {
                                  setState(() {
                                    _searchQuery = value;
                                  });
                                },
                                onClear: () {
                                  _searchController.clear();
                                  setState(() {
                                    _searchQuery = '';
                                  });
                                },
                                showMissingOnly: _showMissingOnly,
                                onMissingFilterChanged: (value) {
                                  setState(() {
                                    _showMissingOnly = value;
                                  });
                                },
                                missingCount: _allItems
                                    .where((item) => item['available'] != true)
                                    .length,
                              ),
                            ),
                            // Song list
                            if (_filteredItems.isEmpty)
                              SliverFillRemaining(
                                child: Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Icon(
                                        Icons.music_note,
                                        size: 60,
                                        color: Colors.grey,
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        _searchQuery.isEmpty
                                            ? 'No songs in this playlist'
                                            : 'No songs match "$_searchQuery"',
                                        style: const TextStyle(
                                          fontSize: 16,
                                          color: Colors.grey,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      const Text(
                                        'Add songs from context menus',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            else if (_searchQuery.isNotEmpty)
                              // Regular list when searching (no reorder)
                              SliverList(
                                delegate: SliverChildBuilderDelegate((
                                  context,
                                  index,
                                ) {
                                  return _buildPlaylistItem(
                                    _filteredItems[index],
                                    index,
                                  );
                                }, childCount: _filteredItems.length),
                              )
                            else
                              // Reorderable list when not searching
                              SliverReorderableList(
                                itemCount: _filteredItems.length,
                                onReorder: (oldIndex, newIndex) async {
                                  if (newIndex > oldIndex) {
                                    newIndex -= 1;
                                  }

                                  final item = _allItems[oldIndex];

                                  setState(() {
                                    _allItems.removeAt(oldIndex);
                                    _allItems.insert(newIndex, item);
                                  });

                                  try {
                                    if (item['available'] == true) {
                                      final song = item['song'] as Song;
                                      await _apiService.reorderPlaylistSong(
                                        widget.playlistId,
                                        song.id,
                                        newIndex + 1,
                                      );
                                    }
                                  } catch (e) {
                                    if (mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text('Error: $e'),
                                          backgroundColor: Colors.red,
                                        ),
                                      );
                                      _loadPlaylist();
                                    }
                                  }
                                },
                                itemBuilder: (context, index) {
                                  return Material(
                                    key: ValueKey('item_$index'),
                                    color: Colors.transparent,
                                    child: ReorderableDelayedDragStartListener(
                                      index: index,
                                      child: _buildPlaylistItem(
                                        _filteredItems[index],
                                        index,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            // Bottom padding
                            SliverPadding(
                              padding: EdgeInsets.only(
                                bottom: _isSelectMode ? 80 : 20,
                              ),
                            ),
                          ],
                        ),
                        // Floating selection bar
                        if (_isSelectMode)
                          Positioned(
                            left: 16,
                            right: 16,
                            bottom: 16,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1a2332),
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.3),
                                    blurRadius: 10,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Row(
                                children: [
                                  Text(
                                    '${_selectedIndices.length} selected',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF00d4ff),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  TextButton(
                                    onPressed: _selectAll,
                                    child: const Text('Select All'),
                                  ),
                                  TextButton(
                                    onPressed: _clearSelection,
                                    child: const Text('Clear'),
                                  ),
                                  const Spacer(),
                                  if (_selectedIndices.isNotEmpty) ...[
                                    ElevatedButton.icon(
                                      onPressed: _bulkMoveSelected,
                                      icon: const Icon(
                                        Icons.open_with,
                                        size: 18,
                                      ),
                                      label: const Text('Move'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFF00d4ff,
                                        ),
                                        foregroundColor: Colors.black,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    ElevatedButton.icon(
                                      onPressed: _removeSelectedSongs,
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        size: 18,
                                      ),
                                      label: const Text('Remove'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.red,
                                        foregroundColor: Colors.white,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(width: 8),
                                  IconButton(
                                    onPressed: _toggleSelectMode,
                                    icon: const Icon(Icons.close),
                                    tooltip: 'Exit select mode',
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// =====================
// Unavailable Track Tile with Preview
// =====================

class _UnavailableTrackTile extends StatefulWidget {
  final int index;
  final String trackName;
  final String artistName;
  final String albumName;
  final String? spotifyTrackId;
  final String? mbid;
  final AudioPlayerService mainAudioPlayer;
  final bool isCurrentlyPlaying;
  final bool shouldStop;
  final void Function(VoidCallback stopCallback) onPreviewStarted;
  final VoidCallback onPreviewStopped;
  final int playlistId;
  final VoidCallback onSongLinked;

  const _UnavailableTrackTile({
    super.key,
    required this.index,
    required this.trackName,
    required this.artistName,
    required this.albumName,
    this.spotifyTrackId,
    this.mbid,
    required this.mainAudioPlayer,
    required this.isCurrentlyPlaying,
    required this.shouldStop,
    required this.onPreviewStarted,
    required this.onPreviewStopped,
    required this.playlistId,
    required this.onSongLinked,
  });

  @override
  State<_UnavailableTrackTile> createState() => _UnavailableTrackTileState();
}

class _UnavailableTrackTileState extends State<_UnavailableTrackTile>
    with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  AudioPlayer? _previewPlayer;
  bool _isPlaying = false;
  bool _isStopping = false;
  bool _isLoading = false;
  double _progress = 0.0;
  Timer? _progressTimer;
  late AnimationController _fadeController;
  String? _previewUrl;
  String? _artworkUrl;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  void didUpdateWidget(covariant _UnavailableTrackTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shouldStop && _isPlaying) {
      _stopPreviewImmediate();
    }
  }

  @override
  void dispose() {
    _stopPreview(fromDispose: true);
    _fadeController.dispose();
    super.dispose();
  }

  Future<void> _fetchPreviewUrl() async {
    if (widget.spotifyTrackId == null) return;

    setState(() => _isLoading = true);

    try {
      final response = await _apiService.getSpotifyPreviewById(
        widget.spotifyTrackId!,
      );
      if (response['success'] == true && response['preview_url'] != null) {
        _previewUrl = response['preview_url'];
        _artworkUrl = response['artwork_url'];
      }
    } catch (e) {
      // Ignore errors
    }

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _playPreview() async {
    // Fetch preview URL if we don't have it yet
    if (_previewUrl == null && widget.spotifyTrackId != null) {
      await _fetchPreviewUrl();
    }

    if (_previewUrl == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No preview available for this track')),
        );
      }
      return;
    }

    // Notify parent that this preview is starting
    widget.onPreviewStarted(_stopPreviewImmediate);

    // Pause main player if playing
    if (widget.mainAudioPlayer.isPlaying) {
      widget.mainAudioPlayer.togglePlayPause();
    }

    setState(() {
      _isPlaying = true;
      _progress = 0.0;
    });

    try {
      _previewPlayer = AudioPlayer();
      _fadeController.reset();

      await _previewPlayer!.setVolume(0);
      await _previewPlayer!.play(UrlSource(_previewUrl!));

      // Fade in
      _fadeController.addListener(_updateVolume);
      _fadeController.forward();

      // Start progress timer (30 second preview)
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
        setState(() => _isPlaying = false);
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

  Future<void> _stopPreview({
    bool fadeOut = false,
    bool fromDispose = false,
  }) async {
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
        // Player may have already stopped
      }
    }

    _progressTimer?.cancel();
    _progressTimer = null;

    if (_previewPlayer != null) {
      try {
        await _previewPlayer!.stop();
        await _previewPlayer!.dispose();
      } catch (e) {
        // Ignore disposal errors
      }
      _previewPlayer = null;
    }

    if (mounted && !fromDispose) {
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
    } else {
      _playPreview();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasSpotifyId = widget.spotifyTrackId != null;

    return ListTile(
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24,
            child: Text(
              '${widget.index + 1}',
              style: const TextStyle(fontSize: 14, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 8),
          // Preview button or artwork
          _CircularPreviewButton(
            isPlaying: _isPlaying,
            isLoading: _isLoading,
            progress: _progress,
            hasPreview: hasSpotifyId,
            artworkUrl: _artworkUrl,
            onTap: hasSpotifyId ? _togglePreview : null,
          ),
        ],
      ),
      title: Text(
        widget.trackName,
        style: const TextStyle(color: Colors.grey),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        widget.mbid != null
            ? '${widget.artistName} • ${widget.albumName}'
            : '${widget.artistName} • Not in library',
        style: TextStyle(
          color: widget.mbid != null ? Colors.grey : Colors.orange.shade300,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.search, color: Colors.orange),
            tooltip: 'Find album to download',
            onPressed: _showAlbumPicker,
          ),
          IconButton(
            icon: const Icon(Icons.link, color: Color(0xFF00d4ff)),
            tooltip: 'Link to library song',
            onPressed: _showLinkDialog,
          ),
        ],
      ),
    );
  }

  /// Primary artist only — drops "& João Gilberto", "feat. X" etc. that
  /// confuse torrent indexers.
  String _primaryArtist() => widget.artistName
      .split(
        RegExp(r'\s*[&,]\s*|\s+feat\.?\s+|\s+featuring\s+', caseSensitive: false),
      )
      .first
      .trim();

  /// Strip parenthetical/bracket suffixes (e.g. "(30th Anniversary Edition)")
  /// and anything after a slash, which break indexer matching.
  String _cleanForSearch(String s) => s
      .replaceAll(RegExp(r'\([^)]*\)'), '')
      .replaceAll(RegExp(r'\[[^\]]*\]'), '')
      .split(' / ')
      .first
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  void _searchProwlarr(String query) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProwlarrSearchScreen(
          audioPlayerService: widget.mainAudioPlayer,
          initialQuery: query,
        ),
      ),
    );
  }

  /// Open a picker listing the albums this track appears on (with type tags),
  /// so the user chooses which release to search Prowlarr for. The auto-resolved
  /// album is often an obscure comp; this puts the choice in the user's hands.
  Future<void> _showAlbumPicker() async {
    await showDialog<void>(
      context: context,
      builder: (context) => _AlbumPickerDialog(
        artist: widget.artistName,
        track: widget.trackName,
        primaryArtist: _primaryArtist(),
        onAlbumChosen: (album) {
          Navigator.pop(context);
          _searchProwlarr('${_primaryArtist()} ${_cleanForSearch(album)}');
        },
        onSearchByTrack: () {
          Navigator.pop(context);
          _searchProwlarr('${_primaryArtist()} ${_cleanForSearch(widget.trackName)}');
        },
      ),
    );
  }

  Future<void> _showLinkDialog() async {
    final initialQuery = '${widget.trackName} ${widget.artistName}';
    String searchQuery = initialQuery;
    List<Song> searchResults = [];
    bool isSearching = true;
    Timer? debounceTimer;
    final searchController = TextEditingController(text: initialQuery);
    bool hasAutoSearched = false;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          // Auto-search on first build
          if (!hasAutoSearched) {
            hasAutoSearched = true;
            Future.microtask(() async {
              try {
                final results = await _apiService.searchLibrarySong(
                  searchQuery,
                  artist: widget.artistName,
                );
                final songs = (results['songs'] as List)
                    .map((json) => Song.fromJson(json))
                    .toList();
                setDialogState(() {
                  searchResults = songs;
                  isSearching = false;
                });
              } catch (e) {
                setDialogState(() => isSearching = false);
              }
            });
          }

          return WillPopScope(
            onWillPop: () async {
              debounceTimer?.cancel();
              searchController.dispose();
              return true;
            },
            child: AlertDialog(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Link to Library Song'),
                  const SizedBox(height: 8),
                  Text(
                    '"${widget.trackName}" by ${widget.artistName}',
                    style: const TextStyle(
                      fontSize: 14,
                      color: Colors.grey,
                      fontWeight: FontWeight.normal,
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 500,
                height: 400,
                child: Column(
                  children: [
                    TextField(
                      controller: searchController,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: 'Search your library...',
                        prefixIcon: const Icon(
                          Icons.search,
                          color: Color(0xFF00d4ff),
                        ),
                        suffixIcon: searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, color: Colors.grey),
                                onPressed: () {
                                  searchController.clear();
                                  setDialogState(() {
                                    searchQuery = '';
                                    searchResults = [];
                                  });
                                },
                              )
                            : null,
                        filled: true,
                        fillColor: const Color(0xFF0d1b2a),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: (value) {
                        searchQuery = value;

                        // Cancel previous timer
                        debounceTimer?.cancel();

                        if (searchQuery.length >= 2) {
                          setDialogState(() {
                            isSearching = true;
                          });

                          // Start new timer (500ms delay)
                          debounceTimer = Timer(
                            const Duration(milliseconds: 500),
                            () async {
                              try {
                                final results = await _apiService
                                    .searchLibrarySong(searchQuery);
                                final songs = (results['songs'] as List)
                                    .map((json) => Song.fromJson(json))
                                    .toList();

                                setDialogState(() {
                                  searchResults = songs;
                                  isSearching = false;
                                });
                              } catch (e) {
                                setDialogState(() {
                                  isSearching = false;
                                });
                              }
                            },
                          );
                        } else {
                          setDialogState(() {
                            searchResults = [];
                            isSearching = false;
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: isSearching
                          ? const Center(child: CircularProgressIndicator())
                          : searchResults.isEmpty
                          ? Center(
                              child: Text(
                                searchQuery.isEmpty
                                    ? 'Search for the correct song in your library'
                                    : 'No results found',
                                style: const TextStyle(color: Colors.grey),
                              ),
                            )
                          : ListView.builder(
                              itemCount: searchResults.length,
                              itemBuilder: (context, index) {
                                final song = searchResults[index];
                                return ListTile(
                                  leading: ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: CachedNetworkImage(
                                      imageUrl: _apiService.getArtworkUrl(
                                        song.albumId,
                                      ),
                                      width: 40,
                                      height: 40,
                                      fit: BoxFit.cover,
                                      placeholder: (context, url) => Container(
                                        width: 40,
                                        height: 40,
                                        color: const Color(0xFF1a2332),
                                      ),
                                      errorWidget: (context, url, error) =>
                                          Container(
                                            width: 40,
                                            height: 40,
                                            color: const Color(0xFF0d1b2a),
                                            child: const Icon(
                                              Icons.music_note,
                                              color: Color(0xFF00d4ff),
                                              size: 20,
                                            ),
                                          ),
                                    ),
                                  ),
                                  title: Text(song.title),
                                  subtitle: Text(
                                    '${song.artistName} • ${song.albumTitle}',
                                    style: const TextStyle(color: Colors.grey),
                                  ),
                                  onTap: () async {
                                    Navigator.pop(context);
                                    await _linkSong(song);
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _linkSong(Song song) async {
    try {
      if (widget.spotifyTrackId != null) {
        // Link by Spotify track ID (preferred)
        await _apiService.linkPlaylistSong(
          widget.playlistId,
          widget.spotifyTrackId!,
          song.id,
        );
      } else {
        // Fall back to name-based linking
        await _apiService.linkPlaylistSongToLibrary(
          spotifyArtist: widget.artistName,
          spotifyTrack: widget.trackName,
          spotifyAlbum: widget.albumName,
          librarySongId: song.id,
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Linked to "${song.title}"'),
            backgroundColor: Colors.green,
          ),
        );
        widget.onSongLinked();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error linking song: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
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
  final String? artworkUrl;
  final VoidCallback? onTap;

  const _CircularPreviewButton({
    required this.isPlaying,
    required this.isLoading,
    required this.progress,
    required this.hasPreview,
    this.artworkUrl,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 50,
        height: 50,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Background - artwork or placeholder
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: const Color(0xFF1a2332),
                borderRadius: BorderRadius.circular(4),
                image: artworkUrl != null
                    ? DecorationImage(
                        image: NetworkImage(artworkUrl!),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: artworkUrl == null
                  ? const Icon(Icons.cloud_off, color: Colors.grey, size: 24)
                  : null,
            ),
            // Progress ring overlay
            if (isPlaying)
              SizedBox(
                width: 50,
                height: 50,
                child: CustomPaint(
                  painter: _ProgressRingPainter(
                    progress: progress,
                    color: const Color(0xFF1DB954),
                  ),
                ),
              ),
            // Play/Pause icon overlay
            if (hasPreview)
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF1DB954),
                        ),
                      )
                    : Icon(
                        isPlaying ? Icons.pause : Icons.play_arrow,
                        color: const Color(0xFF1DB954),
                        size: 24,
                      ),
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

// =====================
// Search Bar Delegate for Pinned Header
// =====================

class _SearchBarDelegate extends SliverPersistentHeaderDelegate {
  final String searchQuery;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final TextEditingController controller;
  final bool showMissingOnly;
  final ValueChanged<bool> onMissingFilterChanged;
  final int missingCount;

  _SearchBarDelegate({
    required this.searchQuery,
    required this.onChanged,
    required this.onClear,
    required this.controller,
    required this.showMissingOnly,
    required this.onMissingFilterChanged,
    required this.missingCount,
  });

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: const Color(0xFF0d1b2a),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              decoration: InputDecoration(
                hintText: 'Search in playlist...',
                prefixIcon: const Icon(Icons.search, color: Color(0xFF00d4ff)),
                suffixIcon: searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: Colors.grey),
                        onPressed: onClear,
                      )
                    : null,
                filled: true,
                fillColor: const Color(0xFF1a2332),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
            ),
          ),
          if (missingCount > 0) ...[
            const SizedBox(width: 8),
            FilterChip(
              label: Text(
                'Missing ($missingCount)',
                style: TextStyle(
                  fontSize: 12,
                  color: showMissingOnly ? Colors.black : Colors.orange,
                ),
              ),
              selected: showMissingOnly,
              onSelected: onMissingFilterChanged,
              selectedColor: Colors.orange,
              backgroundColor: const Color(0xFF1a2332),
              checkmarkColor: Colors.black,
              side: BorderSide(
                color: showMissingOnly
                    ? Colors.orange
                    : Colors.orange.withOpacity(0.5),
              ),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ],
      ),
    );
  }

  @override
  double get maxExtent => 56;

  @override
  double get minExtent => 56;

  @override
  bool shouldRebuild(covariant _SearchBarDelegate oldDelegate) {
    return searchQuery != oldDelegate.searchQuery ||
        showMissingOnly != oldDelegate.showMissingOnly ||
        missingCount != oldDelegate.missingCount;
  }
}

/// Modal that lists the albums a track appears on (Studio Album / Compilation /
/// Live / Single / EP), so the user can pick which release to search Prowlarr for.
class _AlbumPickerDialog extends StatefulWidget {
  final String artist;
  final String track;
  final String primaryArtist;
  final void Function(String album) onAlbumChosen;
  final VoidCallback onSearchByTrack;

  const _AlbumPickerDialog({
    required this.artist,
    required this.track,
    required this.primaryArtist,
    required this.onAlbumChosen,
    required this.onSearchByTrack,
  });

  @override
  State<_AlbumPickerDialog> createState() => _AlbumPickerDialogState();
}

class _AlbumPickerDialogState extends State<_AlbumPickerDialog> {
  final ApiService _api = ApiService();
  late Future<List<Map<String, dynamic>>> _future;
  bool _studioOnly = false;

  @override
  void initState() {
    super.initState();
    _future = _api.getTrackReleases(widget.artist, widget.track);
  }

  Color _chipColor(String category) {
    switch (category) {
      case 'Studio Album':
        return const Color(0xFF00d4ff);
      case 'Compilation':
        return Colors.orange;
      case 'Live':
        return Colors.purpleAccent;
      case 'Single':
      case 'EP':
        return Colors.lightBlueAccent;
      case 'Soundtrack':
        return Colors.tealAccent;
      default:
        return Colors.grey;
    }
  }

  /// Cover Art Archive serves release-group art directly by MBID — no extra
  /// backend lookup needed. 404s (common for obscure comps) fall back to a
  /// placeholder icon in the tile.
  String _artUrl(Map<String, dynamic> g, {int size = 250}) =>
      'https://coverartarchive.org/release-group/${g['mbid']}/front-$size';

  void _showEnlarged(Map<String, dynamic> g) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              _artUrl(g, size: 500),
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => Container(
                width: 300,
                height: 300,
                color: const Color(0xFF1a2332),
                child: const Icon(
                  Icons.broken_image,
                  size: 64,
                  color: Colors.grey,
                ),
              ),
              loadingBuilder: (context, child, progress) {
                if (progress == null) return child;
                return Container(
                  width: 300,
                  height: 300,
                  color: const Color(0xFF1a2332),
                  child: const Center(child: CircularProgressIndicator()),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _albumTile(Map<String, dynamic> g) {
    final category = (g['category'] ?? 'Other') as String;
    final date = (g['date'] ?? '') as String;
    final year = date.isNotEmpty ? date.split('-').first : '';
    final album = (g['album'] ?? '') as String;

    return GestureDetector(
      onTap: () => widget.onAlbumChosen(album),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade700),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(5),
                    ),
                    child: Image.network(
                      _artUrl(g),
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        color: const Color(0xFF1a2332),
                        child: const Icon(
                          Icons.album,
                          size: 36,
                          color: Colors.grey,
                        ),
                      ),
                      loadingBuilder: (context, child, progress) {
                        if (progress == null) return child;
                        return Container(
                          color: const Color(0xFF1a2332),
                          child: const Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        );
                      },
                    ),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: GestureDetector(
                      onTap: () => _showEnlarged(g),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Icon(
                          Icons.zoom_in,
                          size: 16,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(6),
              decoration: const BoxDecoration(
                color: Color(0xFF1a2332),
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(5),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    album,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: _chipColor(category).withOpacity(0.18),
                          borderRadius: BorderRadius.circular(3),
                          border: Border.all(
                            color: _chipColor(category),
                            width: 1,
                          ),
                        ),
                        child: Text(
                          category,
                          style: TextStyle(
                            fontSize: 8,
                            color: _chipColor(category),
                          ),
                        ),
                      ),
                      const Spacer(),
                      if (year.isNotEmpty)
                        Text(
                          year,
                          style: const TextStyle(
                            fontSize: 9,
                            color: Colors.grey,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;
    final dialogWidth = isMobile ? screenWidth * 0.9 : 560.0;
    final gridColumns = isMobile ? 2 : 3;

    return AlertDialog(
      backgroundColor: const Color(0xFF0d1521),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Choose an album', style: TextStyle(fontSize: 18)),
          const SizedBox(height: 2),
          Text(
            '${widget.track} • ${widget.artist}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      content: SizedBox(
        width: dialogWidth,
        height: MediaQuery.of(context).size.height * 0.7,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final all = snapshot.data ?? [];
            final items = _studioOnly
                ? all.where((g) => g['category'] == 'Studio Album').toList()
                : all;
            if (all.isEmpty) {
              return _emptyState(
                'No albums found on MusicBrainz for this track.',
              );
            }
            return Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${items.length} album${items.length == 1 ? '' : 's'}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                    const Text(
                      'Studio only',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    Switch(
                      value: _studioOnly,
                      activeColor: const Color(0xFF00d4ff),
                      onChanged: (v) => setState(() => _studioOnly = v),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (items.isEmpty)
                  Expanded(
                    child: _emptyState('No studio albums — turn off the filter.'),
                  )
                else
                  Expanded(
                    child: GridView.builder(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: gridColumns,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                        childAspectRatio: 0.62,
                      ),
                      itemCount: items.length,
                      itemBuilder: (context, i) => _albumTile(items[i]),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: widget.onSearchByTrack,
          child: const Text('Search by track instead'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _emptyState(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.album_outlined, size: 40, color: Colors.grey),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
