import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:audioplayers/audioplayers.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import '../widgets/mouse_back_button_wrapper.dart';

class MissingAlbumDetailScreen extends StatefulWidget {
  final String artist;
  final String albumName;
  final AudioPlayerService audioPlayerService;

  const MissingAlbumDetailScreen({
    super.key,
    required this.artist,
    required this.albumName,
    required this.audioPlayerService,
  });

  @override
  State<MissingAlbumDetailScreen> createState() =>
      _MissingAlbumDetailScreenState();
}

class _MissingAlbumDetailScreenState extends State<MissingAlbumDetailScreen> {
  final ApiService _apiService = ApiService();

  bool _isLoading = true;
  String? _error;

  // Album data from Spotify
  Map<String, dynamic>? _albumData;
  List<Map<String, dynamic>> _tracks = [];

  // Track which preview is currently playing
  int? _currentlyPlayingIndex;
  VoidCallback? _stopCurrentPreview;

  @override
  void initState() {
    super.initState();
    _loadAlbumTracks();
    // Listen for main player state changes
    widget.audioPlayerService.addListener(_onMainPlayerChanged);
  }

  void _onMainPlayerChanged() {
    // If main player starts playing, stop any preview
    print(
      'DEBUG: _onMainPlayerChanged - isPlaying=${widget.audioPlayerService.isPlaying}, _currentlyPlayingIndex=$_currentlyPlayingIndex',
    );
    if (widget.audioPlayerService.isPlaying && _currentlyPlayingIndex != null) {
      print('DEBUG: Stopping all previews');
      _stopAllPreviews();
    }
  }

  @override
  void dispose() {
    widget.audioPlayerService.removeListener(_onMainPlayerChanged);
    super.dispose();
  }

  Future<void> _loadAlbumTracks() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await _apiService.getSpotifyAlbumTracks(
        widget.artist,
        widget.albumName,
      );

      if (response['success'] == true) {
        setState(() {
          _albumData = response;
          _tracks = List<Map<String, dynamic>>.from(response['tracks'] ?? []);
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = response['error'] ?? 'Failed to load album';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  String _formatDuration(int ms) {
    final minutes = ms ~/ 60000;
    final seconds = (ms % 60000) ~/ 1000;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  void _onPreviewStarted(int index, VoidCallback stopCallback) {
    // Stop the previous preview if one is playing
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

  Future<void> _addToLidarr() async {
    final artist = _albumData?['artist_name'] ?? widget.artist;
    final album = _albumData?['album_name'] ?? widget.albumName;

    // Show the editable MusicBrainz search dialog
    final selectedMbid = await showDialog<String>(
      context: context,
      builder: (context) =>
          _MusicBrainzSearchDialog(initialArtist: artist, initialAlbum: album),
    );

    if (selectedMbid == null || !mounted) return;

    // Add to Lidarr with the selected MBID
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final addResult = await _apiService.addToLidarr(
        artist,
        album,
        albumMbid: selectedMbid,
      );

      if (!mounted) return;
      Navigator.pop(context); // Dismiss loading

      if (addResult['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              addResult['message'] ?? 'Added to Lidarr successfully',
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(addResult['error'] ?? 'Failed to add to Lidarr'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _addToLidarrManual() async {
    // Show the editable MusicBrainz search dialog
    final selectedMbid = await showDialog<String>(
      context: context,
      builder: (context) => _MusicBrainzSearchDialog(
        initialArtist: widget.artist,
        initialAlbum: widget.albumName,
      ),
    );

    if (selectedMbid == null || !mounted) return;

    // Add to Lidarr with the selected MBID
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final addResult = await _apiService.addToLidarr(
        widget.artist,
        widget.albumName,
        albumMbid: selectedMbid,
      );

      if (!mounted) return;
      Navigator.pop(context); // Dismiss loading

      if (addResult['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              addResult['message'] ?? 'Added to Lidarr successfully',
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(addResult['error'] ?? 'Failed to add to Lidarr'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _searchAndAddToLidarr(String artist, String album) async {
    // Show loading while searching MusicBrainz
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      // Search MusicBrainz for release groups
      final searchResult = await _apiService.searchMusicBrainz(artist, album);

      if (!mounted) return;
      Navigator.pop(context); // Dismiss loading

      final results = searchResult['results'] as List? ?? [];

      if (results.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No results found in MusicBrainz'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // Show picker dialog
      final selectedMbid = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: const Color(0xFF1a2332),
        isScrollControlled: true,
        builder: (context) => DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) => Column(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Select Release from MusicBrainz',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Searching: $artist - $album',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const Divider(),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: results.length,
                  itemBuilder: (context, index) {
                    final result = results[index];
                    return ListTile(
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.network(
                          result['cover_url'] ?? '',
                          width: 50,
                          height: 50,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            width: 50,
                            height: 50,
                            color: const Color(0xFF0d1b2a),
                            child: const Icon(Icons.album, color: Colors.grey),
                          ),
                        ),
                      ),
                      title: Text(
                        result['title'] ?? 'Unknown',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${result['artist'] ?? 'Unknown'} • ${result['type'] ?? 'Unknown type'}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                      trailing: const Icon(
                        Icons.add_circle_outline,
                        color: Color(0xFF1DB954),
                      ),
                      onTap: () => Navigator.pop(context, result['mbid']),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );

      if (selectedMbid == null) return; // User cancelled

      // Now add to Lidarr with the selected MBID
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );

      final addResult = await _apiService.addToLidarr(
        artist,
        album,
        albumMbid: selectedMbid,
      );

      if (!mounted) return;
      Navigator.pop(context); // Dismiss loading

      if (addResult['success'] == true) {
        final releasesFound = addResult['releases_found'] ?? 0;
        final message = releasesFound > 0
            ? "${addResult['message']} - Found $releasesFound releases!"
            : "${addResult['message']} - No releases found. Check RuTracker!";

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: releasesFound > 0 ? Colors.green : Colors.orange,
            duration: const Duration(seconds: 5),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(addResult['error'] ?? 'Failed to add to Lidarr'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // Dismiss loading

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _showLinkDialog() async {
    final result = await showDialog<int>(
      context: context,
      builder: (context) =>
          _AlbumLinkDialog(artist: widget.artist, albumName: widget.albumName),
    );

    if (result != null && mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );

      try {
        final response = await _apiService.linkSpotifyAlbum(
          spotifyArtist: widget.artist,
          spotifyAlbum: widget.albumName,
          libraryAlbumId: result,
        );

        if (!mounted) return;
        Navigator.pop(context); // dismiss loading

        if (response['success'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(response['message'] ?? 'Album linked successfully'),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context); // go back to list
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(response['error'] ?? 'Failed to link album'),
              backgroundColor: Colors.red,
            ),
          );
        }
      } catch (e) {
        if (!mounted) return;
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _showDismissDialog() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text('Dismiss Album?'),
        content: Text(
          'This will hide "${widget.albumName}" by ${widget.artist} from the missing albums list.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.orange),
            child: const Text('Dismiss'),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      try {
        final response = await _apiService.dismissSpotifyAlbum(
          spotifyArtist: widget.artist,
          spotifyAlbum: widget.albumName,
        );

        if (!mounted) return;

        if (response['success'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(response['message'] ?? 'Album dismissed'),
              backgroundColor: Colors.orange,
            ),
          );
          Navigator.pop(context); // go back to list
        }
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseBackButtonWrapper(
      child: Scaffold(
        backgroundColor: const Color(0xFF0d1b2a),
        appBar: _error != null
            ? AppBar(
                title: Text('${widget.albumName} - ${widget.artist}'),
                backgroundColor: const Color(0xFF0d1b2a),
              )
            : null,
        body: Column(
          children: [
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? _buildErrorView()
                  : _buildContent(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.orange, size: 64),
            const SizedBox(height: 24),
            Text(
              'Album not found on Spotify',
              style: const TextStyle(
                color: Colors.orange,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              '"${widget.albumName}" by ${widget.artist}',
              style: const TextStyle(color: Colors.grey, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            const Text(
              'The album name or artist might be different on Spotify.\nYou can still add it to Lidarr manually.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _loadAlbumTracks,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1a2332),
                    foregroundColor: Colors.white,
                  ),
                ),
                const SizedBox(width: 16),
                ElevatedButton.icon(
                  onPressed: _addToLidarrManual,
                  icon: const Icon(Icons.add),
                  label: const Text('Add to Lidarr'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1DB954),
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: _showLinkDialog,
              icon: const Icon(Icons.link, size: 18),
              label: const Text('Link to existing library album'),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF00d4ff),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    return CustomScrollView(
      slivers: [
        // App bar with album artwork
        SliverAppBar(
          expandedHeight: 300,
          pinned: true,
          backgroundColor: const Color(0xFF0d1b2a),
          actions: [
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              color: const Color(0xFF1a2332),
              onSelected: (value) {
                if (value == 'link') {
                  _showLinkDialog();
                } else if (value == 'dismiss') {
                  _showDismissDialog();
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'link',
                  child: Row(
                    children: [
                      Icon(Icons.link, color: Color(0xFF1DB954), size: 20),
                      SizedBox(width: 12),
                      Text('Link to Library Album'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'dismiss',
                  child: Row(
                    children: [
                      Icon(
                        Icons.visibility_off,
                        color: Colors.orange,
                        size: 20,
                      ),
                      SizedBox(width: 12),
                      Text('Dismiss'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          flexibleSpace: FlexibleSpaceBar(
            background: Stack(
              fit: StackFit.expand,
              children: [
                // Album artwork
                if (_albumData?['artwork_url'] != null)
                  Image.network(
                    _albumData!['artwork_url'],
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      color: const Color(0xFF1a2332),
                      child: const Icon(
                        Icons.album,
                        size: 100,
                        color: Color(0xFF1DB954),
                      ),
                    ),
                  )
                else
                  Container(
                    color: const Color(0xFF1a2332),
                    child: const Icon(
                      Icons.album,
                      size: 100,
                      color: Color(0xFF1DB954),
                    ),
                  ),
                // Gradient overlay
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        const Color(0xFF0d1b2a).withOpacity(0.8),
                        const Color(0xFF0d1b2a),
                      ],
                    ),
                  ),
                ),
                // Album info at bottom
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // "Missing from Library" badge
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.8),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'MISSING FROM LIBRARY',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _albumData?['album_name'] ?? widget.albumName,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _albumData?['artist_name'] ?? widget.artist,
                        style: const TextStyle(
                          fontSize: 16,
                          color: Color(0xFF1DB954),
                        ),
                      ),
                      if (_albumData?['release_date'] != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          _albumData!['release_date'],
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // Track count header
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Text(
                  '${_tracks.length} tracks',
                  style: const TextStyle(color: Colors.grey, fontSize: 14),
                ),
                const Spacer(),
                // TODO: Add to Lidarr button
                TextButton.icon(
                  onPressed: _addToLidarr,
                  icon: const Icon(Icons.add, color: Color(0xFF1DB954)),
                  label: const Text(
                    'Add to Lidarr',
                    style: TextStyle(color: Color(0xFF1DB954)),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Track list
        SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            final track = _tracks[index];
            return _TrackTile(
              key: ValueKey(index),
              trackNumber: track['track_number'] ?? (index + 1),
              trackName: track['track_name'] ?? 'Unknown',
              artistName: track['artist_name'] ?? widget.artist,
              duration: _formatDuration(track['duration_ms'] ?? 0),
              previewUrl: track['preview_url'],
              mainAudioPlayer: widget.audioPlayerService,
              index: index,
              isCurrentlyPlaying: _currentlyPlayingIndex == index,
              shouldStop:
                  _currentlyPlayingIndex != null &&
                  _currentlyPlayingIndex != index,
              onPreviewStarted: (stopCallback) =>
                  _onPreviewStarted(index, stopCallback),
              onPreviewStopped: _onPreviewStopped,
            );
          }, childCount: _tracks.length),
        ),

        // Bottom padding
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
    );
  }
}

// =====================
// Track Tile with Preview Player
// =====================

class _TrackTile extends StatefulWidget {
  final int trackNumber;
  final String trackName;
  final String artistName;
  final String duration;
  final String? previewUrl;
  final AudioPlayerService mainAudioPlayer;
  final int index;
  final bool isCurrentlyPlaying;
  final bool shouldStop;
  final void Function(VoidCallback stopCallback) onPreviewStarted;
  final VoidCallback onPreviewStopped;

  const _TrackTile({
    super.key,
    required this.trackNumber,
    required this.trackName,
    required this.artistName,
    required this.duration,
    this.previewUrl,
    required this.mainAudioPlayer,
    required this.index,
    required this.isCurrentlyPlaying,
    required this.shouldStop,
    required this.onPreviewStarted,
    required this.onPreviewStopped,
  });

  @override
  State<_TrackTile> createState() => _TrackTileState();
}

class _TrackTileState extends State<_TrackTile>
    with SingleTickerProviderStateMixin {
  // Preview player
  AudioPlayer? _previewPlayer;
  bool _isPlaying = false;
  bool _isStopping = false;
  double _progress = 0.0;
  Timer? _progressTimer;
  late AnimationController _fadeController;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  void didUpdateWidget(covariant _TrackTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Stop this preview if another one started
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

  Future<void> _playPreview() async {
    if (widget.previewUrl == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No preview available for this track')),
      );
      return;
    }

    // Notify parent that this preview is starting (pass stop callback)
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

      // Reset fade controller for fresh fade in
      _fadeController.reset();

      // Set volume to 0 for fade in
      await _previewPlayer!.setVolume(0);
      await _previewPlayer!.play(UrlSource(widget.previewUrl!));

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
          _progress += 100 / 30000; // 30 seconds = 30000ms
          // Start fade out at 93% (~28 seconds) to allow 2 second fade before end
          if (_progress >= 0.87 && _isPlaying) {
            _stopPreview(fadeOut: true);
          }
        });
      });

      // Listen for completion
      _previewPlayer!.onPlayerComplete.listen((_) {
        if (mounted) {
          _stopPreview(fadeOut: true);
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
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
        // Fade out over 3 seconds (60 steps of 50ms each)
        for (int i = 0; i < 60; i++) {
          if (_previewPlayer == null) break;
          double vol = 1.0 - (i / 60);
          await _previewPlayer!.setVolume(vol.clamp(0.0, 1.0));
          await Future.delayed(const Duration(milliseconds: 50));
        }
        // Ensure volume is zero and hold briefly
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

  // Immediate stop without fade (used when switching tracks)
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
    final hasPreview = widget.previewUrl != null;

    return ListTile(
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Track number
          SizedBox(
            width: 24,
            child: Text(
              '${widget.trackNumber}',
              style: const TextStyle(color: Colors.grey, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 8),
          // Circular preview button with progress
          _CircularPreviewButton(
            isPlaying: _isPlaying,
            progress: _progress,
            hasPreview: hasPreview,
            onTap: hasPreview ? _togglePreview : null,
          ),
        ],
      ),
      title: Text(
        widget.trackName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: hasPreview ? Colors.white : Colors.grey),
      ),
      subtitle: Text(
        widget.artistName,
        style: const TextStyle(color: Colors.grey, fontSize: 12),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!hasPreview)
            const Tooltip(
              message: 'No preview available',
              child: Icon(Icons.music_off, color: Colors.grey, size: 16),
            ),
          const SizedBox(width: 8),
          Text(
            widget.duration,
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// =====================
// Circular Preview Button
// =====================

class _CircularPreviewButton extends StatelessWidget {
  final bool isPlaying;
  final double progress;
  final bool hasPreview;
  final VoidCallback? onTap;

  const _CircularPreviewButton({
    required this.isPlaying,
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
            // Background circle
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
                      ? const Color(0xFF1DB954).withOpacity(0.3)
                      : Colors.grey.withOpacity(0.2),
                  width: 2,
                ),
              ),
            ),
            // Progress ring
            if (isPlaying)
              SizedBox(
                width: 40,
                height: 40,
                child: CustomPaint(
                  painter: _ProgressRingPainter(
                    progress: progress,
                    color: const Color(0xFF1DB954),
                  ),
                ),
              ),
            // Play/Pause icon
            Icon(
              isPlaying ? Icons.pause : Icons.play_arrow,
              color: hasPreview ? const Color(0xFF1DB954) : Colors.grey,
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

    // Draw arc from top (- pi/2) clockwise
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2, // Start from top
      2 * math.pi * progress, // Sweep angle based on progress
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
// Album Link Dialog
// =====================

class _AlbumLinkDialog extends StatefulWidget {
  final String artist;
  final String albumName;

  const _AlbumLinkDialog({required this.artist, required this.albumName});

  @override
  State<_AlbumLinkDialog> createState() => _AlbumLinkDialogState();
}

class _AlbumLinkDialogState extends State<_AlbumLinkDialog> {
  final ApiService _apiService = ApiService();
  final TextEditingController _searchController = TextEditingController();
  List<dynamic> _searchResults = [];
  bool _isLoading = true;
  List<dynamic> _allAlbums = [];

  @override
  void initState() {
    super.initState();
    _loadAllAlbums();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadAllAlbums() async {
    try {
      final albums = await _apiService.getAlbums();
      if (mounted) {
        setState(() {
          _allAlbums = albums
              .map(
                (a) => {
                  'id': a.id,
                  'title': a.title,
                  'artist_name': a.artistName,
                  'artwork_path': a.artworkPath,
                  'song_count': a.songCount,
                },
              )
              .toList();
          _filterAlbums(widget.artist);
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _filterAlbums(String query) {
    if (query.isEmpty) {
      setState(() => _searchResults = _allAlbums);
      return;
    }

    final lowerQuery = query.toLowerCase();
    setState(() {
      _searchResults = _allAlbums.where((album) {
        final title = (album['title'] ?? '').toString().toLowerCase();
        final artist = (album['artist_name'] ?? '').toString().toLowerCase();
        return title.contains(lowerQuery) || artist.contains(lowerQuery);
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1a2332),
      child: Container(
        width: 500,
        height: 600,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.link, color: Color(0xFF1DB954)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Link to Library Album',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${widget.artist} - ${widget.albumName}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search your library...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: const Color(0xFF0d1b2a),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: _filterAlbums,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _searchResults.isEmpty
                  ? const Center(
                      child: Text(
                        'No albums found',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _searchResults.length,
                      itemBuilder: (context, index) {
                        final album = _searchResults[index];
                        return ListTile(
                          leading: Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              color: const Color(0xFF0d1b2a),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: album['artwork_path'] != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: Image.network(
                                      '${ApiService.baseUrl}/artwork/${Uri.encodeComponent(album['artwork_path'])}',
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => const Icon(
                                        Icons.album,
                                        color: Color(0xFF1DB954),
                                      ),
                                    ),
                                  )
                                : const Icon(
                                    Icons.album,
                                    color: Color(0xFF1DB954),
                                  ),
                          ),
                          title: Text(
                            album['title'] ?? 'Unknown',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            album['artist_name'] ?? 'Unknown Artist',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Text(
                            '${album['song_count'] ?? 0} tracks',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 11,
                            ),
                          ),
                          onTap: () => Navigator.pop(context, album['id']),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// =====================
// MusicBrainz Search Dialog
// =====================

class _MusicBrainzSearchDialog extends StatefulWidget {
  final String initialArtist;
  final String initialAlbum;

  const _MusicBrainzSearchDialog({
    required this.initialArtist,
    required this.initialAlbum,
  });

  @override
  State<_MusicBrainzSearchDialog> createState() =>
      _MusicBrainzSearchDialogState();
}

class _MusicBrainzSearchDialogState extends State<_MusicBrainzSearchDialog> {
  final ApiService _apiService = ApiService();
  late TextEditingController _artistController;
  late TextEditingController _albumController;

  List<dynamic> _results = [];
  bool _isLoading = false;
  bool _hasSearched = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _artistController = TextEditingController(text: widget.initialArtist);
    _albumController = TextEditingController(text: widget.initialAlbum);
    // Auto-search on open
    _search();
  }

  @override
  void dispose() {
    _artistController.dispose();
    _albumController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final artist = _artistController.text.trim();
    final album = _albumController.text.trim();

    if (artist.isEmpty && album.isEmpty) {
      setState(() {
        _error = 'Enter an artist or album name';
        _results = [];
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
      _hasSearched = true;
    });

    try {
      final response = await _apiService.searchMusicBrainz(artist, album);

      if (mounted) {
        setState(() {
          _results = response['results'] ?? [];
          _isLoading = false;
          if (_results.isEmpty) {
            _error = 'No results found. Try different search terms.';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Search failed: $e';
          _isLoading = false;
          _results = [];
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1a2332),
      child: Container(
        width: 550,
        height: 650,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1DB954).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.search,
                    color: Color(0xFF1DB954),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Search MusicBrainz',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Find the album to add to Lidarr',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Search fields
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _artistController,
                    decoration: InputDecoration(
                      labelText: 'Artist',
                      hintText: 'e.g. Hed PE',
                      filled: true,
                      fillColor: const Color(0xFF0d1b2a),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _albumController,
                    decoration: InputDecoration(
                      labelText: 'Album',
                      hintText: 'e.g. Blackout',
                      filled: true,
                      fillColor: const Color(0xFF0d1b2a),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _isLoading ? null : _search,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1DB954),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.search),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Results area
            Expanded(child: _buildResultsArea()),
          ],
        ),
      ),
    );
  }

  Widget _buildResultsArea() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Color(0xFF1DB954)),
            SizedBox(height: 16),
            Text(
              'Searching MusicBrainz...',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _hasSearched ? Icons.search_off : Icons.info_outline,
              color: Colors.grey,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              _error!,
              style: const TextStyle(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            if (_hasSearched) ...[
              const SizedBox(height: 16),
              const Text(
                'Tips:\n• Try removing special characters\n• Use simpler spelling\n• Search by artist only',
                style: TextStyle(color: Colors.grey, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      );
    }

    if (_results.isEmpty && !_hasSearched) {
      return const Center(
        child: Text(
          'Enter search terms and click Search',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final result = _results[index];
        return Card(
          color: const Color(0xFF0d1b2a),
          margin: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            onTap: () => Navigator.pop(context, result['mbid']),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  // Album art
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.network(
                      result['cover_url'] ?? '',
                      width: 60,
                      height: 60,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 60,
                        height: 60,
                        color: const Color(0xFF1a2332),
                        child: const Icon(
                          Icons.album,
                          color: Colors.grey,
                          size: 30,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          result['title'] ?? 'Unknown',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          result['artist'] ?? 'Unknown Artist',
                          style: const TextStyle(
                            color: Color(0xFF1DB954),
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            result['type'] ?? 'Unknown',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Add button
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1DB954).withOpacity(0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.add,
                      color: Color(0xFF1DB954),
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
