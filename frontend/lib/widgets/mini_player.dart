import 'dart:async' show Timer;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
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

class _MiniPlayerState extends State<MiniPlayer> {
  bool _disposed = false;
  Object? _shown;

  @override
  void initState() {
    super.initState();
    // Rebuilds on real state changes only (song, play/pause, favorites...).
    // The per-frame progress lives in _MiniProgressBar: this whole widget
    // used to setState every frame forever, ~23% GPU on FRAMEWORK.
    widget.audioPlayerService.addListener(_onAudioStateChanged);
  }

  /// Everything the mini player shows from the service. The service notifies
  /// 4x/s for position alone; rebuild only when one of these changes (the
  /// progress strip below has its own clock). Until Nov 9 the whole mini
  /// player rebuilt on every position tick.
  Object _shownState() {
    final s = widget.audioPlayerService;
    return (
      s.currentSong,
      s.currentSong?.id,
      s.isPlaying,
      s.isLoading,
      s.isCasting,
      s.isPlayingPodcast,
      s.currentEpisodeId,
      s.podcastTitle,
      s.podcastEpisodeTitle,
      s.podcastArtworkUrl,
      s.stationTrackTitle,
      s.stationTrackArtist,
    );
  }

  void _onAudioStateChanged() {
    if (_disposed || !mounted) return;
    final shown = _shownState();
    if (shown == _shown) return;
    _shown = shown;
    setState(() {});
  }

  @override
  void dispose() {
    _disposed = true;
    widget.audioPlayerService.removeListener(_onAudioStateChanged);
    super.dispose();
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
              // Smooth progress bar with sparks (own widget + repaint layer)
              _MiniProgressBar(audioPlayerService: widget.audioPlayerService),

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
                                          : apiService.getArtworkThumbUrl(currentSong.albumId),
                                      width: _isMobile ? 44 : 50,
                                      height: _isMobile ? 44 : 50,
                                      // 300 px thumb, decoded at 2x the tile:
                                      // the full-size cover (up to ~3000 px,
                                      // ~36 MB decoded) was loaded for a 50 px
                                      // square on every song change.
                                      memCacheWidth: 100,
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

/// The mini player's progress bar, on its own so only this 3 px strip redraws
/// instead of the whole mini player.
///
/// Desktop: a 12.5 Hz Timer, no sparks. On Windows every frame re-draws and
/// re-presents the WHOLE window, and a vsync Ticker asks for a frame 60 times
/// a second for as long as a song plays, on every screen: that was ~33% of a
/// core on FRAMEWORK's raster thread (Nov 9), with heat and whole-machine
/// stalls. The bar moves ~10 px a second, so 12.5 updates look the same.
/// Phone: the per-frame ticker + sparks as before. Either way it runs only
/// while a song is actually playing and stops when the app can't be seen
/// (TickerMode / AppVisibility).
class _MiniProgressBar extends StatefulWidget {
  final AudioPlayerService audioPlayerService;
  const _MiniProgressBar({required this.audioPlayerService});

  @override
  State<_MiniProgressBar> createState() => _MiniProgressBarState();
}

class _MiniProgressBarState extends State<_MiniProgressBar>
    with SingleTickerProviderStateMixin {
  static const Duration _desktopStep = Duration(milliseconds: 80);

  late final Ticker _ticker;
  Timer? _timer;
  bool _visible = true;
  Duration _lastKnownPosition = Duration.zero;
  DateTime _lastUpdateTime = DateTime.now();

  AudioPlayerService get _svc => widget.audioPlayerService;
  bool get _running => _svc.isPlaying && !_svc.isBuffering;
  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => setState(() {}));
    _lastKnownPosition = _svc.position;
    _svc.addListener(_onAudioStateChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Muted (minimized / covered): a Timer isn't stopped by TickerMode.
    _visible = TickerMode.of(context);
    _syncClock();
  }

  void _onAudioStateChanged() {
    if (!mounted) return;
    setState(() {
      _lastKnownPosition = _svc.position;
      _lastUpdateTime = DateTime.now();
    });
    _syncClock();
  }

  void _syncClock() {
    final run = _running && _visible;
    if (_isMobile) {
      if (run && !_ticker.isActive) {
        _ticker.start();
      } else if (!run && _ticker.isActive) {
        _ticker.stop();
      }
      return;
    }
    if (run) {
      _timer ??= Timer.periodic(_desktopStep, (_) {
        if (mounted) setState(() {});
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _svc.removeListener(_onAudioStateChanged);
    _timer?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  Duration get _smoothPosition {
    if (!_running) return _lastKnownPosition;
    final smoothPos =
        _lastKnownPosition + DateTime.now().difference(_lastUpdateTime);
    final duration = _svc.duration;
    return smoothPos > duration ? duration : smoothPos;
  }

  @override
  Widget build(BuildContext context) {
    final duration = _svc.duration;
    final progress = duration.inMilliseconds > 0
        ? _smoothPosition.inMilliseconds / duration.inMilliseconds
        : 0.0;
    return RepaintBoundary(
      child: SparkProgressBar(
        progress: progress.clamp(0.0, 1.0),
        // Sparks are a per-frame animation: phone only (see above).
        active: _running && _isMobile,
      ),
    );
  }
}
