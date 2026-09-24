import 'package:flutter/material.dart';
import 'dart:io' show Platform;
import '../services/audio_player_service.dart';
import '../services/api_service.dart';
import '../services/cast_service.dart';
import '../screens/now_playing_screen.dart';
import 'favorite_button.dart';
import '../screens/queue_screen.dart';
import '../widgets/spark_progress_bar.dart';
import '../widgets/cast_button.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'marquee_text.dart';
import 'explicit_badge.dart';
import 'hdcd_badge.dart';
import 'surround_badge.dart';
import 'tv_focus.dart';
import '../main.dart' show globalCastService, globalDeviceSyncService;

class MiniPlayer extends StatefulWidget {
  final AudioPlayerService audioPlayerService;

  const MiniPlayer({super.key, required this.audioPlayerService});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  Duration _lastKnownPosition = Duration.zero;
  DateTime _lastUpdateTime = DateTime.now();
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _lastKnownPosition = widget.audioPlayerService.position;
    _lastUpdateTime = DateTime.now();

    // Listen for audio service updates
    widget.audioPlayerService.addListener(_onAudioStateChanged);

    // Use AnimationController for buttery smooth 60fps
    _animationController =
        AnimationController(vsync: this, duration: const Duration(hours: 24))
          ..addListener(() {
            if (mounted) {
              setState(() {}); // Trigger repaint at screen refresh rate
            }
          });

    _animationController.repeat();
  }

  void _onAudioStateChanged() {
    if (_disposed) return;
    if (mounted) {
      setState(() {
        _lastKnownPosition = widget.audioPlayerService.position;
        _lastUpdateTime = DateTime.now();
      });
    }
  }

  @override
  void dispose() {
    _disposed = true;
    widget.audioPlayerService.removeListener(_onAudioStateChanged);
    _animationController.stop();
    _animationController.dispose();
    super.dispose();
  }

  Duration get _smoothPosition {
    if (!widget.audioPlayerService.isPlaying || widget.audioPlayerService.isBuffering) {
      return _lastKnownPosition;
    }
    final now = DateTime.now();
    final elapsed = now.difference(_lastUpdateTime);
    final smoothPos = _lastKnownPosition + elapsed;

    final duration = widget.audioPlayerService.duration;

    if (smoothPos > duration) {
      return duration;
    }
    return smoothPos;
  }

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  Widget build(BuildContext context) {
    final ApiService apiService = ApiService();
    final currentSong = widget.audioPlayerService.currentSong;
    final isPodcast = widget.audioPlayerService.isPlayingPodcast;

    // Don't show if nothing is loaded
    if (currentSong == null && !isPodcast) {
      return const SizedBox.shrink();
    }

    final isPlaying = widget.audioPlayerService.isPlaying;
    final duration = widget.audioPlayerService.duration;
    final progress = duration.inMilliseconds > 0
        ? _smoothPosition.inMilliseconds / duration.inMilliseconds
        : 0.0;

    return SafeArea(
      top: false,
      left: false,
      right: false,
      child: TvFocusable(
        onTap: () {
          NowPlayingScreen.open(
            context,
            audioPlayerService: widget.audioPlayerService,
          );
        },
        child: Container(
          height: _isMobile ? 64 : 80,
          decoration: BoxDecoration(
            color: const Color(0xFF1a2332),
            border: Border(
              top: BorderSide(
                color: const Color(0xFF00d4ff).withOpacity(0.3),
                width: 1,
              ),
            ),
          ),
          child: Column(
            children: [
              // Smooth progress bar with sparks
              SparkProgressBar(progress: progress.clamp(0.0, 1.0)),

              // Main content
              Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: _isMobile ? 12.0 : 16.0,
                  ),
                  child: Row(
                    children: [
                      // Artwork (album or podcast)
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 500),
                        child: ClipRRect(
                          key: ValueKey(isPodcast
                              ? 'pod_${widget.audioPlayerService.currentEpisodeId}'
                              : (currentSong?.isStation == true
                                  ? 'stn_${currentSong?.id}'
                                  : currentSong?.albumId)),
                          borderRadius: BorderRadius.circular(4),
                          child: isPodcast && widget.audioPlayerService.podcastArtworkUrl != null
                              ? Image.network(
                                  widget.audioPlayerService.podcastArtworkUrl!,
                                  width: _isMobile ? 44 : 50,
                                  height: _isMobile ? 44 : 50,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Container(
                                    width: _isMobile ? 44 : 50,
                                    height: _isMobile ? 44 : 50,
                                    color: const Color(0xFF0d1b2a),
                                    child: const Icon(Icons.podcasts, color: Colors.orange),
                                  ),
                                )
                              : currentSong != null
                                  ? CachedNetworkImage(
                                      // Live stations carry their own artwork
                                      // (favicon); albumId is 0 so getArtworkUrl
                                      // would 404 to a blank placeholder.
                                      imageUrl: currentSong.isStation &&
                                              (currentSong.stationArtworkUrl ?? '').isNotEmpty
                                          ? currentSong.stationArtworkUrl!
                                          : apiService.getArtworkUrl(currentSong.albumId),
                                      width: _isMobile ? 44 : 50,
                                      height: _isMobile ? 44 : 50,
                                      fit: BoxFit.cover,
                                      placeholder: (context, url) => Container(
                                        width: _isMobile ? 44 : 50,
                                        height: _isMobile ? 44 : 50,
                                        color: const Color(0xFF1a2332),
                                      ),
                                      errorWidget: (context, url, error) => Container(
                                        width: _isMobile ? 44 : 50,
                                        height: _isMobile ? 44 : 50,
                                        color: const Color(0xFF0d1b2a),
                                        child: const Icon(Icons.album, color: Color(0xFF00d4ff)),
                                      ),
                                    )
                                  : Container(
                                      width: _isMobile ? 44 : 50,
                                      height: _isMobile ? 44 : 50,
                                      color: const Color(0xFF0d1b2a),
                                      child: const Icon(Icons.podcasts, color: Colors.orange),
                                    ),
                        ),
                      ),
                      const SizedBox(width: 10),

                      // Song info
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxWidth: _isMobile ? 200 : 300,
                                    ),
                                    child: AnimatedSwitcher(
                                      duration: const Duration(milliseconds: 500),
                                      child: MarqueeText(
                                        key: ValueKey(isPodcast ? 'pod_${widget.audioPlayerService.currentEpisodeId}' : currentSong?.id),
                                        text: isPodcast
                                            ? (widget.audioPlayerService.podcastEpisodeTitle ?? 'Podcast')
                                            : (currentSong?.isStation == true &&
                                                    (widget.audioPlayerService.stationTrackTitle?.isNotEmpty ?? false)
                                                ? widget.audioPlayerService.stationTrackTitle!
                                                : (currentSong?.title ?? '')),
                                        style: TextStyle(
                                          fontSize: _isMobile ? 13 : 14,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                if (!isPodcast && currentSong != null) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: (currentSong!.isStation
                                            ? Colors.red
                                            : currentSong.formatColor)
                                        .withOpacity(0.2),
                                    border: Border.all(
                                      color: currentSong.isStation
                                          ? Colors.red
                                          : currentSong.formatColor,
                                      width: 1,
                                    ),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    currentSong.isStation
                                        ? 'LIVE'
                                        : currentSong.fileFormat,
                                    style: TextStyle(
                                      fontSize: _isMobile ? 8 : 9,
                                      fontWeight: FontWeight.bold,
                                      color: currentSong.isStation
                                          ? Colors.red
                                          : currentSong.formatColor,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ),
                                if (currentSong.isExplicit) ...[
                                  const SizedBox(width: 4),
                                  ExplicitBadge(fontSize: _isMobile ? 8 : 9),
                                ],
                                if (currentSong.isAtmos || currentSong.isSurround) ...[
                                  const SizedBox(width: 4),
                                  SpatialBadge(song: currentSong, fontSize: _isMobile ? 8 : 9),
                                ],
                                if (currentSong.isHdcd) ...[
                                  const SizedBox(width: 4),
                                  HdcdBadge(fontSize: _isMobile ? 8 : 9),
                                ],
                                ], // end if (!isPodcast)
                              ],
                            ),
                            const SizedBox(height: 2),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 500),
                              child: Text(
                                isPodcast
                                    ? (widget.audioPlayerService.podcastTitle ?? 'Podcast')
                                    : widget.audioPlayerService.isCasting
                                        ? '📺 Casting to ${globalCastService.deviceName}'
                                        : globalDeviceSyncService.isBeingControlled
                                            ? '🎮 Controlled by ${globalDeviceSyncService.controllerDeviceName ?? 'another device'}'
                                            : globalDeviceSyncService.isController
                                                ? '🎮 Controlling ${globalDeviceSyncService.targetDeviceName ?? 'a device'}'
                                                : (currentSong?.isStation == true &&
                                                        (widget.audioPlayerService.stationTrackArtist?.isNotEmpty ?? false)
                                                    ? '${widget.audioPlayerService.stationTrackArtist} • ${currentSong?.title ?? ''}'
                                                    : '${currentSong?.artistsFormatted ?? ''} • ${currentSong?.albumTitle ?? ''}'),
                                key: ValueKey(isPodcast
                                    ? 'pod_${widget.audioPlayerService.currentEpisodeId}'
                                    : widget.audioPlayerService.isCasting
                                        ? 'casting_${globalCastService.deviceName}'
                                        : globalDeviceSyncService.isBeingControlled
                                            ? 'controlled_${globalDeviceSyncService.controllerDeviceName}'
                                            : globalDeviceSyncService.isController
                                                ? 'controlling_${globalDeviceSyncService.targetDeviceName}'
                                                : '${currentSong?.id}_info'),
                                style: TextStyle(
                                  fontSize: _isMobile ? 11 : 12,
                                  color: isPodcast
                                      ? Colors.orange
                                      : (widget.audioPlayerService.isCasting ||
                                              globalDeviceSyncService.isBeingControlled ||
                                              globalDeviceSyncService.isController)
                                          ? const Color(0xFF00d4ff)
                                          : Colors.grey,
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Controls - simplified for mobile
                      if (_isMobile) ...[
                        // Mobile: cast button, play/pause, and next
                        CastButton(
                          castService: globalCastService,
                          audioPlayerService: widget.audioPlayerService,
                          iconSize: 22,
                        ),
                        widget.audioPlayerService.isLoading
                            ? const SizedBox(
                                width: 32,
                                height: 32,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF00d4ff),
                                ),
                              )
                            : IconButton(
                                icon: Icon(
                                  isPlaying ? Icons.pause : Icons.play_arrow,
                                ),
                                iconSize: 32,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () {
                                  widget.audioPlayerService.togglePlayPause();
                                },
                              ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.skip_next),
                          iconSize: 28,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () {
                            widget.audioPlayerService.next();
                          },
                        ),
                      ] else ...[
                        // Desktop: full controls
                        IconButton(
                          icon: const Icon(Icons.skip_previous),
                          iconSize: 28,
                          onPressed: () {
                            widget.audioPlayerService.previous();
                          },
                        ),
                        widget.audioPlayerService.isLoading
                            ? const SizedBox(
                                width: 32,
                                height: 32,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF00d4ff),
                                ),
                              )
                            : IconButton(
                                icon: Icon(
                                  isPlaying ? Icons.pause : Icons.play_arrow,
                                ),
                                iconSize: 32,
                                onPressed: () {
                                  widget.audioPlayerService.togglePlayPause();
                                },
                              ),
                        IconButton(
                          icon: const Icon(Icons.skip_next),
                          iconSize: 28,
                          onPressed: () {
                            widget.audioPlayerService.next();
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.queue_music),
                          iconSize: 24,
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => QueueScreen(
                                  audioPlayerService: widget.audioPlayerService,
                                ),
                              ),
                            );
                          },
                        ),
                        if (!isPodcast && currentSong != null)
                        FavoriteButton(
                          itemType: 'song',
                          itemId: currentSong.id,
                          size: 24,
                        ),
                        IconButton(
                          icon: const Icon(Icons.fullscreen),
                          iconSize: 24,
                          tooltip: 'Fullscreen',
                          onPressed: () {
                            NowPlayingScreen.open(
                              context,
                              audioPlayerService: widget.audioPlayerService,
                              startFullScreen: true,
                            );
                          },
                        ),
                      ],
                    ],
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
