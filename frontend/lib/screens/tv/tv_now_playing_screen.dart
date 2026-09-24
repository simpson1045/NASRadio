import 'dart:async';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/song.dart';
import '../../services/api_service.dart';
import '../../services/audio_player_service.dart';
import '../../widgets/explicit_badge.dart';
import '../../widgets/hdcd_badge.dart';
import '../../widgets/tv_focus.dart';
import '../../widgets/waveform_progress_bar.dart';
import '../../widgets/remote_control_badge.dart';
import '../../main.dart' show globalDeviceSyncService;

/// TV-variant Now Playing screen. Models on the cast receiver's
/// left-panel layout (`backend/cast/receiver.html` / `receiver.css`):
/// blurred album art background, dark scrim, centered artwork +
/// title/artist/album/badges, full-width waveform progress bar at the
/// bottom, and a horizontal row of 5 d-pad-focusable playback controls
/// underneath. Top-right shows the clock and (when active) the sleep
/// timer countdown.
///
/// Re-uses the same `routeName` as the phone `NowPlayingScreen` so the
/// `popUntil` dedupe in `NowPlayingScreen.open` still works for repeat
/// taps.
class TvNowPlayingScreen extends StatefulWidget {
  static const String routeName = 'now_playing';

  final AudioPlayerService audioPlayerService;

  const TvNowPlayingScreen({super.key, required this.audioPlayerService});

  @override
  State<TvNowPlayingScreen> createState() => _TvNowPlayingScreenState();
}

class _TvNowPlayingScreenState extends State<TvNowPlayingScreen> {
  final ApiService _apiService = ApiService();

  List<double> _waveformData = [];
  int? _waveformSongId;
  bool _blackScreenActive = false;

  Timer? _clockTimer;
  String _clockText = '';

  // Tracked-state fields used by `_onPlayerChange` to gate setState. The
  // audio service notifies on every position tick (~1Hz during playback);
  // without gating the entire screen — including the blurred album-art
  // ImageFilter — would re-render every second, which is what produced
  // the laggy feel in build 37. Now we only rebuild on the dimensions
  // that actually drive visible state in this screen: current song,
  // play/loading status, sleep timer activity. WaveformProgressBar
  // handles its own 60fps position smoothing internally.
  int? _lastSongId;
  bool _lastIsPlaying = false;
  bool _lastIsLoading = false;
  bool _lastIsSleepActive = false;
  Duration _lastDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    final svc = widget.audioPlayerService;
    _lastSongId = svc.currentSong?.id;
    _lastIsPlaying = svc.isPlaying;
    _lastIsLoading = svc.isLoading;
    _lastIsSleepActive = svc.isSleepTimerActive;
    _lastDuration = svc.duration;
    svc.addListener(_onPlayerChange);
    _maybeFetchWaveform();
    _updateClock();
    _clockTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _updateClock(),
    );
  }

  @override
  void dispose() {
    widget.audioPlayerService.removeListener(_onPlayerChange);
    _clockTimer?.cancel();
    super.dispose();
  }

  void _onPlayerChange() {
    if (!mounted) return;
    final svc = widget.audioPlayerService;
    final songId = svc.currentSong?.id;
    final isPlaying = svc.isPlaying;
    final isLoading = svc.isLoading;
    final isSleepActive = svc.isSleepTimerActive;
    final duration = svc.duration;

    final songChanged = songId != _lastSongId;
    if (songChanged) {
      _lastSongId = songId;
      _maybeFetchWaveform();
    }

    if (songChanged ||
        isPlaying != _lastIsPlaying ||
        isLoading != _lastIsLoading ||
        isSleepActive != _lastIsSleepActive ||
        duration != _lastDuration) {
      _lastIsPlaying = isPlaying;
      _lastIsLoading = isLoading;
      _lastIsSleepActive = isSleepActive;
      _lastDuration = duration;
      setState(() {});
    }
  }

  Future<void> _maybeFetchWaveform() async {
    final song = widget.audioPlayerService.currentSong;
    if (song == null) return;
    if (_waveformSongId == song.id && _waveformData.isNotEmpty) return;
    _waveformSongId = song.id;
    if (_waveformData.isNotEmpty) {
      setState(() => _waveformData = []);
    }
    try {
      final wf = await _apiService.getWaveform(song.id);
      if (!mounted || _waveformSongId != song.id) return;
      setState(() => _waveformData = wf);
    } catch (_) {
      if (!mounted) return;
      // Flat fallback so the bar still renders during outages.
      setState(() => _waveformData = List.filled(1000, 0.5));
    }
  }

  void _updateClock() {
    final now = DateTime.now();
    final h12 = now.hour > 12 ? now.hour - 12 : (now.hour == 0 ? 12 : now.hour);
    final newText = '$h12:${now.minute.toString().padLeft(2, '0')}';
    if (newText != _clockText && mounted) {
      setState(() => _clockText = newText);
    }
  }

  String _fmtDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final svc = widget.audioPlayerService;
    final song = svc.currentSong;

    if (song == null) {
      return Scaffold(
        backgroundColor: const Color(0xFF050a14),
        body: const Center(
          child: Text(
            'Nothing playing',
            style: TextStyle(color: Colors.white54, fontSize: 22),
          ),
        ),
      );
    }

    if (_blackScreenActive) {
      // Don't use TvFocusable here — its 3px cyan focus border would
      // draw around the entire screen the moment autofocus claims, which
      // defeats the whole point of black-screen mode. Plain Focus +
      // GestureDetector: claim focus invisibly, dismiss on any keydown
      // (so any direction key OR OK on the remote works) or any tap.
      return Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent) {
              setState(() => _blackScreenActive = false);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _blackScreenActive = false),
            child: Container(color: Colors.black),
          ),
        ),
      );
    }

    final artworkUrl = _apiService.getArtworkUrl(song.albumId);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _BlurredArtBg(imageUrl: artworkUrl),
          // Heavy scrim — the receiver gets away with 55% because it has
          // no UI competing for attention with the bg, but the Flutter
          // layout has title / artist / album / waveform text + controls
          // all over the bg and needs strong contrast on bright album
          // covers (e.g. light-shirt portraits with bold cyan text on a
          // near-white background blur to a near-white smudge). 82% +
          // per-text drop shadows below.
          Container(color: Colors.black.withOpacity(0.82)),
          SafeArea(
            child: Column(
              children: [
                _buildTopBar(svc),
                // Remote-control badge — fades in when this TV is being
                // controlled (or is controlling), like the Cast indicator.
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                  child: RemoteControlBadge(
                    service: globalDeviceSyncService,
                    onStopControl: () =>
                        globalDeviceSyncService.stopRemoteControl(),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // The center panel IS the title/artist/album text
                      // panel — it failed to render in build 38 because
                      // `MarqueeText` was wrapped in a `Padding` whose
                      // width came from a Column with default
                      // `crossAxisAlignment.center`, leaving `MarqueeText`
                      // with effectively unbounded horizontal constraints.
                      // Now we lay out from a `LayoutBuilder` so we know
                      // the panel's max width and can pass explicit
                      // `SizedBox(width: ...)` wrappers around each text
                      // line. Text widgets also use `maxLines: 1/2`
                      // + `TextOverflow.ellipsis` instead of marquee
                      // scrolling — simpler, no overflow surprises, no
                      // dependency on a third-party widget.
                      return Center(
                        child: _buildCenterPanel(
                          song,
                          artworkUrl,
                          constraints.maxWidth,
                        ),
                      );
                    },
                  ),
                ),
                _buildWaveform(svc),
                _buildControlRow(svc, song),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(AudioPlayerService svc) {
    final sleepActive = svc.isSleepTimerActive;
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 12, 40, 0),
      child: Row(
        children: [
          const Spacer(),
          if (sleepActive) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.5),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('🌙', style: TextStyle(fontSize: 14)),
                  const SizedBox(width: 8),
                  Text(
                    _fmtDuration(svc.sleepTimeRemaining),
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 16,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
          ],
          Text(
            _clockText,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 26,
              fontWeight: FontWeight.bold,
              fontFeatures: [FontFeature.tabularFigures()],
              shadows: [
                Shadow(
                  color: Colors.black54,
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCenterPanel(Song song, String artworkUrl, double availableWidth) {
    // ALL dimensions scale with screen height. A Firestick 4K at density
    // 2.0 reports `MediaQuery.of(context).size.height ≈ 540dp`, while a
    // density-1.0 Android TV reports ≈1080dp. Build 39 used fixed pixel
    // values sized for the 1080dp case (artwork 460, title 30pt, etc.),
    // which on a 540dp Firestick overflowed the Expanded vertical space
    // and pushed the title text down onto the waveform. Scaling
    // proportionally + clamping to a sane range fixes the overflow on
    // small TV viewports without making the 1080dp layout look cramped.
    // 1.25× TV font scaling from `MaterialApp.builder` is applied ON TOP
    // of these sizes; the clamped maxes are tuned so the result still
    // fits.
    final h = MediaQuery.of(context).size.height;
    final artDim = (h * 0.30).clamp(140.0, 320.0);
    final titleSize = (h * 0.048).clamp(18.0, 26.0);
    final artistSize = (h * 0.036).clamp(14.0, 20.0);
    final albumSize = (h * 0.026).clamp(11.0, 14.0);
    final spaceArt = (h * 0.014).clamp(6.0, 14.0);
    final spaceText = (h * 0.008).clamp(3.0, 6.0);
    final spaceBeforeBadges = (h * 0.012).clamp(5.0, 10.0);

    final textWidth = (availableWidth - 120).clamp(300.0, 1100.0);

    const textShadow = Shadow(
      color: Colors.black,
      blurRadius: 12,
      offset: Offset(0, 2),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Artwork
        Container(
          width: artDim,
          height: artDim,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: const Color(0xFF1a2332),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.5),
                blurRadius: 40,
                offset: const Offset(0, 20),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: CachedNetworkImage(
            imageUrl: artworkUrl,
            fit: BoxFit.cover,
            placeholder: (_, __) => Container(color: const Color(0xFF1a2332)),
            errorWidget: (_, __, ___) => Container(
              color: const Color(0xFF1a2332),
              child: const Icon(
                Icons.album,
                color: Colors.white24,
                size: 80,
              ),
            ),
          ),
        ),
        SizedBox(height: spaceArt),
        // Title — single-line on small screens to keep the panel under
        // the available height; users can still see the full title in
        // the mini player at the bottom of the screen and on the
        // dashboard cards.
        SizedBox(
          width: textWidth,
          child: Text(
            song.title,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: titleSize,
              fontWeight: FontWeight.w700,
              height: 1.2,
              shadows: const [textShadow],
            ),
          ),
        ),
        SizedBox(height: spaceText),
        // Artist
        SizedBox(
          width: textWidth,
          child: Text(
            song.artistsFormatted,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: artistSize,
              fontWeight: FontWeight.w500,
              shadows: const [textShadow],
            ),
          ),
        ),
        SizedBox(height: spaceText / 2),
        // Album
        SizedBox(
          width: textWidth,
          child: Text(
            song.albumTitle,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white70,
              fontSize: albumSize,
              shadows: const [textShadow],
            ),
          ),
        ),
        // Format / HDCD / Explicit badges — hidden for podcasts. The
        // phone Now Playing does the same (`!song.isPodcast` guards
        // around the format chunk). For an episode the `fileFormat` is
        // either the audio container the episode happens to ship in
        // (mp3 / m4a / opus) — which is just noise to the user — or
        // empty, which renders as a useless empty chip. Either way:
        // useless on a podcast, hide it.
        if (!song.isPodcast) ...[
          SizedBox(height: spaceBeforeBadges),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: song.formatColor.withOpacity(0.15),
                  border: Border.all(color: song.formatColor, width: 1.5),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  song.fileFormat.toUpperCase(),
                  style: TextStyle(
                    color: song.formatColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              if (song.isHdcd) const HdcdBadge(fontSize: 12),
              if (song.isExplicit) const ExplicitBadge(fontSize: 12),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildWaveform(AudioPlayerService svc) {
    if (_waveformData.isEmpty) {
      return const SizedBox(height: 48);
    }
    // The parent screen's `setState` is gated to song / play-state
    // changes (no rebuild on 1Hz position ticks — that's what made
    // build 39 laggy). But the waveform progress bar + the time labels
    // DO need fresh `position` every tick to render the moving cursor
    // and the running clock. Wrap just THIS subtree in a
    // `ListenableBuilder` so it re-renders on every audio-service
    // notify while the parent stays gated. ListenableBuilder rebuilds
    // are cheap because the subtree is tiny — no blurred bg, no album
    // art, no Stack of overlays.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 60, vertical: 4),
      child: ExcludeFocus(
        child: ListenableBuilder(
          listenable: svc,
          builder: (context, _) {
            return Column(
              children: [
                SizedBox(
                  height: 28,
                  child: WaveformProgressBar(
                    waveformData: _waveformData,
                    position: svc.position,
                    duration: svc.duration,
                    // Fire TV remote has no touch surface for seeking.
                    onSeek: (_) {},
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _fmtDuration(svc.position),
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      _fmtDuration(svc.duration),
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildControlRow(AudioPlayerService svc, Song song) {
    final isPlaying = svc.isPlaying;
    final isLoading = svc.isLoading;

    // `MainAxisAlignment.spaceEvenly` distributes equal space before,
    // between, and after all 5 slots across the row's full width.
    // Build 41's `MainAxisAlignment.center` and build 42's
    // `Center(child: Row(min))` both rendered as if the row had less
    // width than the screen — slots ended up bunched on the left.
    // spaceEvenly side-steps the constraint problem entirely: it's a
    // Row layout policy that requires the row to have a finite max
    // width and then computes slot positions purely from
    // mainAxis-extent/slot-count. No "did the row get full width"
    // ambiguity. If even spaceEvenly fails, the row genuinely isn't
    // getting width and we'd see ALL slots crammed at x=0.
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _slot(
          TvIconButton(
            icon: const Icon(
              Icons.skip_previous,
              color: Colors.white,
              size: 36,
            ),
            iconSize: 60,
            onPressed: svc.previous,
          ),
        ),
        _slot(
          isLoading
              ? const SizedBox(
                  width: 56,
                  height: 56,
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Color(0xFF00d4ff),
                    ),
                  ),
                )
              : TvIconButton(
                  icon: Icon(
                    isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                    color: Colors.white,
                    size: 56,
                  ),
                  iconSize: 80,
                  autofocus: true,
                  onPressed: svc.togglePlayPause,
                ),
        ),
        _slot(
          TvIconButton(
            icon: const Icon(Icons.skip_next, color: Colors.white, size: 36),
            iconSize: 60,
            onPressed: svc.next,
          ),
        ),
        _slot(_TvFavoriteButton(songId: song.id)),
        _slot(
          TvIconButton(
            icon: const Icon(
              Icons.nightlight_outlined,
              color: Colors.white,
              size: 32,
            ),
            iconSize: 60,
            tooltip: 'Black screen',
            onPressed: () => setState(() => _blackScreenActive = true),
          ),
        ),
      ],
    );
  }

  Widget _slot(Widget child) {
    return SizedBox(width: 96, height: 72, child: Center(child: child));
  }
}

/// Background album art layer — separate widget so it only repaints
/// when the URL actually changes (the parent rebuilds on every player
/// notify, which would otherwise re-blur on every position tick).
class _BlurredArtBg extends StatelessWidget {
  final String imageUrl;
  const _BlurredArtBg({required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      imageUrl: imageUrl,
      fit: BoxFit.cover,
      errorWidget: (_, __, ___) => Container(color: const Color(0xFF050a14)),
      imageBuilder: (context, image) => ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          decoration: BoxDecoration(
            image: DecorationImage(image: image, fit: BoxFit.cover),
          ),
        ),
      ),
    );
  }
}

/// TV-friendly favorite toggle. Re-uses the same ApiService endpoints as
/// the phone `FavoriteButton` (`checkFavorite` / `addFavorite` /
/// `removeFavorite`) but renders through `TvIconButton` so the cyan
/// focus ring is consistent with the rest of the playback controls.
class _TvFavoriteButton extends StatefulWidget {
  final int songId;
  const _TvFavoriteButton({required this.songId});

  @override
  State<_TvFavoriteButton> createState() => _TvFavoriteButtonState();
}

class _TvFavoriteButtonState extends State<_TvFavoriteButton> {
  final ApiService _apiService = ApiService();
  bool _isFavorite = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void didUpdateWidget(covariant _TvFavoriteButton old) {
    super.didUpdateWidget(old);
    if (old.songId != widget.songId) {
      _ready = false;
      _check();
    }
  }

  Future<void> _check() async {
    try {
      final fav = await _apiService.checkFavorite('song', widget.songId);
      if (!mounted) return;
      setState(() {
        _isFavorite = fav;
        _ready = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _ready = true);
    }
  }

  Future<void> _toggle() async {
    setState(() => _isFavorite = !_isFavorite);
    try {
      if (_isFavorite) {
        await _apiService.addFavorite('song', widget.songId);
      } else {
        await _apiService.removeFavorite('song', widget.songId);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _isFavorite = !_isFavorite);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const SizedBox(
        width: 36,
        height: 36,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24),
      );
    }
    return TvIconButton(
      icon: Icon(
        _isFavorite ? Icons.favorite : Icons.favorite_border,
        color: _isFavorite ? const Color(0xFFFF4081) : Colors.white,
        size: 32,
      ),
      iconSize: 60,
      tooltip: _isFavorite ? 'Unfavorite' : 'Favorite',
      onPressed: _toggle,
    );
  }
}
