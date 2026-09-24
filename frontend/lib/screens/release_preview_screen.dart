import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:audioplayers/audioplayers.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import 'prowlarr_search_screen.dart';
import 'artist_detail_screen.dart';

class ReleasePreviewScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;
  final Map<String, dynamic> release;

  const ReleasePreviewScreen({
    super.key,
    required this.audioPlayerService,
    required this.release,
  });

  @override
  State<ReleasePreviewScreen> createState() => _ReleasePreviewScreenState();
}

class _ReleasePreviewScreenState extends State<ReleasePreviewScreen> {
  final ApiService _apiService = ApiService();
  List<Map<String, dynamic>> _tracks = [];
  String? _albumArtworkUrl;
  String? _spotifyUrl;
  bool _isLoading = true;
  String? _error;
  int? _currentlyPlayingIndex;
  VoidCallback? _stopCurrentPreview;

  String get _artistName => widget.release['artist_name'] ?? 'Unknown Artist';
  String get _releaseTitle => widget.release['release_title'] ?? 'Unknown';
  String get _releaseDate => widget.release['release_date'] ?? '';
  String get _releaseType => widget.release['release_type'] ?? '';
  bool get _inLibrary => widget.release['in_library'] == true;
  String get _mbid => widget.release['mbid'] ?? '';

  String get _coverArtUrl => _mbid.isNotEmpty
      ? 'https://coverartarchive.org/release-group/$_mbid/front-500'
      : '';

  @override
  void initState() {
    super.initState();
    _loadTracks();
  }

  @override
  void dispose() {
    _stopCurrentPreview?.call();
    super.dispose();
  }

  Future<void> _loadTracks() async {
    try {
      final result = await _apiService.getSpotifyAlbumTracks(
        _artistName,
        _releaseTitle,
      );

      if (!mounted) return;

      setState(() {
        _tracks = List<Map<String, dynamic>>.from(result['tracks'] ?? []);
        _albumArtworkUrl = result['artwork_url'];
        _spotifyUrl = result['spotify_url'];
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  void _onPreviewStarted(int index, VoidCallback stopCallback) {
    _stopCurrentPreview?.call();
    setState(() {
      _currentlyPlayingIndex = index;
      _stopCurrentPreview = stopCallback;
    });
  }

  void _onPreviewStopped(int index) {
    if (_currentlyPlayingIndex == index) {
      setState(() {
        _currentlyPlayingIndex = null;
        _stopCurrentPreview = null;
      });
    }
  }

  String _formatDate(String dateStr) {
    if (dateStr.isEmpty) return '';
    try {
      final parts = dateStr.split('-');
      if (parts.length == 3) {
        final months = [
          '',
          'Jan',
          'Feb',
          'Mar',
          'Apr',
          'May',
          'Jun',
          'Jul',
          'Aug',
          'Sep',
          'Oct',
          'Nov',
          'Dec',
        ];
        final month = int.parse(parts[1]);
        final day = int.parse(parts[2]);
        final year = parts[0];
        return '${months[month]} $day, $year';
      }
      return dateStr;
    } catch (_) {
      return dateStr;
    }
  }

  String _formatDuration(int ms) {
    final duration = Duration(milliseconds: ms);
    final minutes = duration.inMinutes;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0d1b2a),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF00d4ff)),
            )
          : _buildContent(),
    );
  }

  Widget _buildContent() {
    final artUrl = _albumArtworkUrl ?? _coverArtUrl;

    return CustomScrollView(
      slivers: [
        // Hero artwork header
        SliverAppBar(
          expandedHeight: 350,
          pinned: true,
          backgroundColor: const Color(0xFF0d1b2a),
          iconTheme: const IconThemeData(color: Color(0xFF00d4ff)),
          flexibleSpace: FlexibleSpaceBar(
            background: Stack(
              fit: StackFit.expand,
              children: [
                // Album artwork
                artUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: artUrl,
                        fit: BoxFit.cover,
                        placeholder: (context, url) =>
                            Container(color: const Color(0xFF1a2332)),
                        errorWidget: (context, url, error) => Container(
                          color: const Color(0xFF1a2332),
                          child: const Icon(
                            Icons.album,
                            size: 100,
                            color: Color(0xFF00d4ff),
                          ),
                        ),
                      )
                    : Container(
                        color: const Color(0xFF1a2332),
                        child: const Icon(
                          Icons.album,
                          size: 100,
                          color: Color(0xFF00d4ff),
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
                        const Color(0xFF0d1b2a).withOpacity(0.7),
                        const Color(0xFF0d1b2a),
                      ],
                      stops: const [0.3, 0.7, 1.0],
                    ),
                  ),
                ),
                // Release info at bottom
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Text(
                              _releaseTitle,
                              style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          if (_inLibrary)
                            Container(
                              margin: const EdgeInsets.only(left: 8),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.green.withValues(alpha: 0.9),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'IN LIBRARY',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      GestureDetector(
                        onTap: () {
                          final artistId = widget.release['artist_id'];
                          if (artistId != null) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => ArtistDetailScreen(
                                  artistId: artistId,
                                  audioPlayerService: widget.audioPlayerService,
                                  parentLabel: 'Releases',
                                ),
                              ),
                            );
                          }
                        },
                        child: Text(
                          _artistName,
                          style: const TextStyle(
                            fontSize: 18,
                            color: Color(0xFF00d4ff),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          if (_releaseType.isNotEmpty) _releaseType,
                          if (_releaseDate.isNotEmpty)
                            _formatDate(_releaseDate),
                          if (_tracks.isNotEmpty)
                            '${_tracks.length} ${_tracks.length == 1 ? 'track' : 'tracks'}',
                        ].join(' • '),
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
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ProwlarrSearchScreen(
                        audioPlayerService: widget.audioPlayerService,
                        initialQuery: '$_artistName $_releaseTitle',
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.search, size: 20),
                label: const Text('Search on Prowlarr'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1a2332),
                  foregroundColor: const Color(0xFF00d4ff),
                  side: const BorderSide(color: Color(0xFF00d4ff), width: 1),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ),
        ),

        // Error state
        if (_error != null)
          SliverFillRemaining(
            child: Center(
              child: Text(
                'Could not load tracks from Spotify',
                style: const TextStyle(color: Colors.grey, fontSize: 16),
              ),
            ),
          )
        // Track list
        else
          SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              final track = _tracks[index];
              return _PreviewTrackTile(
                index: index,
                track: track,
                mainAudioPlayer: widget.audioPlayerService,
                isCurrentlyPlaying: _currentlyPlayingIndex == index,
                shouldStop:
                    _currentlyPlayingIndex != null &&
                    _currentlyPlayingIndex != index,
                onPreviewStarted: (stopCallback) =>
                    _onPreviewStarted(index, stopCallback),
                onPreviewStopped: () => _onPreviewStopped(index),
                formatDuration: _formatDuration,
              );
            }, childCount: _tracks.length),
          ),
      ],
    );
  }
}

// =====================
// Preview Track Tile
// =====================

class _PreviewTrackTile extends StatefulWidget {
  final int index;
  final Map<String, dynamic> track;
  final AudioPlayerService mainAudioPlayer;
  final bool isCurrentlyPlaying;
  final bool shouldStop;
  final void Function(VoidCallback stopCallback) onPreviewStarted;
  final VoidCallback onPreviewStopped;
  final String Function(int) formatDuration;

  const _PreviewTrackTile({
    required this.index,
    required this.track,
    required this.mainAudioPlayer,
    required this.isCurrentlyPlaying,
    required this.shouldStop,
    required this.onPreviewStarted,
    required this.onPreviewStopped,
    required this.formatDuration,
  });

  @override
  State<_PreviewTrackTile> createState() => _PreviewTrackTileState();
}

class _PreviewTrackTileState extends State<_PreviewTrackTile>
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
  void didUpdateWidget(covariant _PreviewTrackTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shouldStop && _isPlaying) {
      _stopPreviewImmediate();
    }
  }

  @override
  void dispose() {
    _stopPreviewCleanup();
    _fadeController.dispose();
    super.dispose();
  }

  Future<void> _fetchAndPlayPreview() async {
    if (_isLoading) return;

    setState(() => _isLoading = true);

    try {
      final trackId = widget.track['track_id'];
      if (trackId == null) {
        setState(() {
          _isLoading = false;
          _noPreviewAvailable = true;
        });
        return;
      }

      final existingPreview = widget.track['preview_url'];
      if (existingPreview != null && existingPreview.toString().isNotEmpty) {
        _previewUrl = existingPreview;
        await _playPreview();
        return;
      }

      final response = await _apiService.getSpotifyPreviewById(trackId);

      if (!mounted) return;

      if (response['success'] == true && response['preview_url'] != null) {
        _previewUrl = response['preview_url'];
        await _playPreview();
      } else {
        setState(() {
          _isLoading = false;
          _noPreviewAvailable = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
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
        if (mounted) _stopPreview(fadeOut: true);
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _isLoading = false;
        });
        widget.onPreviewStopped();
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
      } catch (_) {}
    }

    _progressTimer?.cancel();
    _progressTimer = null;

    if (_previewPlayer != null) {
      try {
        await _previewPlayer!.stop();
        await _previewPlayer!.dispose();
      } catch (_) {}
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

  void _stopPreviewCleanup() {
    _progressTimer?.cancel();
    _progressTimer = null;
    _fadeController.removeListener(_updateVolume);
    _previewPlayer?.stop();
    _previewPlayer?.dispose();
    _previewPlayer = null;
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
    final trackName = widget.track['track_name'] ?? 'Unknown Track';
    final trackNumber = widget.track['track_number'] ?? (widget.index + 1);
    final discNumber = widget.track['disc_number'];
    final durationMs = widget.track['duration_ms'] ?? 0;

    return Container(
      margin: const EdgeInsets.only(left: 4, right: 0, top: 2, bottom: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: _isPlaying
            ? const Color(0xFF00d4ff).withOpacity(0.15)
            : Colors.transparent,
        border: _isPlaying
            ? Border.all(
                color: const Color(0xFF00d4ff).withOpacity(0.3),
                width: 1,
              )
            : null,
      ),
      child: InkWell(
        onTap: _noPreviewAvailable ? null : _togglePreview,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
          child: Row(
            children: [
              // Track number or preview button
              SizedBox(
                width: 40,
                child: _isPlaying
                    ? _CircularPreviewButton(
                        isPlaying: true,
                        isLoading: false,
                        progress: _progress,
                        hasPreview: true,
                        onTap: _togglePreview,
                      )
                    : _isLoading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF00d4ff),
                        ),
                      )
                    : Text(
                        '$trackNumber',
                        style: const TextStyle(
                          fontSize: 16,
                          color: Colors.grey,
                        ),
                        textAlign: TextAlign.center,
                      ),
              ),
              const SizedBox(width: 8),
              // Title and disc info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      trackName,
                      style: TextStyle(
                        color: _isPlaying
                            ? const Color(0xFF00d4ff)
                            : Colors.white,
                        fontWeight: _isPlaying
                            ? FontWeight.w600
                            : FontWeight.normal,
                        fontSize: 16,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (discNumber != null && discNumber > 1)
                      Text(
                        'Disc $discNumber',
                        style: TextStyle(
                          fontSize: 12,
                          color: _isPlaying
                              ? const Color(0xFF00d4ff).withOpacity(0.7)
                              : Colors.grey,
                        ),
                      ),
                  ],
                ),
              ),
              // Duration and no-preview icon
              if (_noPreviewAvailable)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Tooltip(
                    message: 'No preview available',
                    child: Icon(Icons.music_off, color: Colors.grey, size: 16),
                  ),
                ),
              if (durationMs > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 8, right: 12),
                  child: Text(
                    widget.formatDuration(durationMs),
                    style: TextStyle(
                      color: _isPlaying
                          ? const Color(0xFF00d4ff).withOpacity(0.8)
                          : Colors.grey,
                      fontSize: 14,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
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
        width: 36,
        height: 36,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hasPreview
                    ? const Color(0xFF1a2332)
                    : const Color(0xFF1a2332).withValues(alpha: 0.5),
                border: Border.all(
                  color: hasPreview
                      ? const Color(0xFF00d4ff).withValues(alpha: 0.3)
                      : Colors.grey.withValues(alpha: 0.2),
                  width: 2,
                ),
              ),
            ),
            if (isPlaying)
              SizedBox(
                width: 36,
                height: 36,
                child: CustomPaint(
                  painter: _ProgressRingPainter(
                    progress: progress,
                    color: const Color(0xFF00d4ff),
                  ),
                ),
              ),
            if (isLoading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF00d4ff),
                ),
              )
            else
              Icon(
                isPlaying ? Icons.pause : Icons.play_arrow,
                color: hasPreview ? const Color(0xFF00d4ff) : Colors.grey,
                size: 18,
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
