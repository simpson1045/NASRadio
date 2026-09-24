import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:io' show Platform;
import 'dart:ui' show ImageFilter;
import '../services/audio_player_service.dart';
import '../services/api_service.dart';
import '../services/app_logger.dart';
import '../widgets/chapter_strip.dart';
import '../widgets/chaptered_slider.dart';
import '../widgets/chapters_sheet.dart';
import '../widgets/lyrics_view.dart';
import '../models/song_chapter.dart';
import '../screens/artist_detail_screen.dart';
import '../screens/album_detail_screen.dart';
import '../screens/rss_feed_detail_screen.dart';
import '../models/rss_feed.dart';
import '../screens/queue_screen.dart';
import '../widgets/favorite_button.dart';
import '../widgets/waveform_progress_bar.dart';
import '../widgets/mouse_back_button_wrapper.dart';
import '../models/song.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../widgets/marquee_text.dart';
import 'playlist_detail_screen.dart';
import 'favorites_screen.dart';
import 'stations_screen.dart';
import 'recently_played_screen.dart';
import 'most_played_screen.dart';
import '../widgets/explicit_badge.dart';
import '../widgets/hdcd_badge.dart';
import '../widgets/surround_badge.dart';
import '../widgets/cast_button.dart';
import '../main.dart' show globalCastService, isFireTvLike, globalDeviceSyncService;
import '../widgets/remote_control_badge.dart';
import '../widgets/devices_sheet.dart';
import 'tv/tv_now_playing_screen.dart';
import 'dart:async';
import 'main_navigation_screen.dart';

class NowPlayingScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;
  final bool startFullScreen;

  const NowPlayingScreen({
    super.key,
    required this.audioPlayerService,
    this.startFullScreen = false,
  });

  /// Stable route name. Every push of this screen carries it via
  /// `RouteSettings(name: routeName)` so the helper below can detect
  /// whether NowPlaying is already on the navigator stack.
  static const String routeName = 'now_playing';

  /// Open NowPlaying without ever stacking duplicate instances.
  ///
  /// History — left unguarded, every "tap song to play" / "tap mini
  /// player" / "tap title in some detail screen" path was doing a
  /// raw `Navigator.push(MaterialPageRoute(builder: ...))`. With the
  /// natural drill-down navigation pattern (NowPlaying → Artist →
  /// song → NowPlaying → Album → song → NowPlaying), three or more
  /// `_NowPlayingScreenState` instances would end up alive on the
  /// stack, each with its own listener attached to the audio
  /// service, each rebuilding on every position tick, each running
  /// the full `_onPlayerStateChanged` body on every state flip.
  /// Confirmed in the live combined.log heartbeat output.
  ///
  /// Behaviour:
  ///   * If NowPlaying is already on the navigator stack, pop back
  ///     to it (closing any intermediate routes pushed on top).
  ///     User lands on the existing widget — no new instance, no
  ///     duplicate listener attachments, no leaked tickers.
  ///   * Otherwise push a fresh route with the stable name.
  ///
  /// All call sites that used `Navigator.push(NowPlayingScreen(...))`
  /// should use this helper instead.
  static Future<void> open(
    BuildContext context, {
    required AudioPlayerService audioPlayerService,
    bool startFullScreen = false,
  }) async {
    // Now Playing is an overlay on the ROOT navigator, above the section
    // shell — opening it never unwinds the page you were on, and closing
    // it lands you exactly where you were.
    final navigator = Navigator.of(context, rootNavigator: true);
    bool alreadyOnStack = false;
    navigator.popUntil((route) {
      if (route.settings.name == routeName) {
        alreadyOnStack = true;
        return true;
      }
      return route.isFirst;
    });
    if (alreadyOnStack) return;
    final useTvLayout = isFireTvLike(context);
    // Player surfaces slide UP from the bottom (and back down on
    // dismiss) — the platform idiom for now-playing everywhere, and
    // simpson1045's ask from the first macOS session. A vertical slide also
    // reads better than a side-push when invoked from the docked
    // mini player, which is where most opens come from.
    await navigator.push(
      PageRouteBuilder(
        settings: const RouteSettings(name: routeName),
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, __, ___) => useTvLayout
            ? TvNowPlayingScreen(audioPlayerService: audioPlayerService)
            : NowPlayingScreen(
                audioPlayerService: audioPlayerService,
                startFullScreen: startFullScreen,
              ),
        transitionsBuilder: (_, animation, __, child) {
          final slide = Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(animation);
          return SlideTransition(position: slide, child: child);
        },
      ),
    );
  }

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen>
    with TickerProviderStateMixin {
  /// Pages opened from the player (artist, album, playlist, stations…) go
  /// INTO the section beneath it: close the player overlay, then push on
  /// the current section's navigator, so the shell's bar/rail stays put
  /// and Back returns to wherever you were before opening the player.
  void _pushBelowPlayer(Route<dynamic> route) {
    final push = MainNavigationScreenState.pushInCurrentTab;
    if (push == null) {
      Navigator.push(context, route); // no section shell (TV layout)
      return;
    }
    Navigator.of(context, rootNavigator: true).pop();
    push(route);
  }

  final ApiService _apiService = ApiService();
  final Map<int, List<int>> _playlistAlbumCache = {};
  List<double> _waveformData = [];
  bool _waveformLoading = false;
  int? _waveformSongId;

  /// True only when the waveform carries real shape worth drawing. A degenerate
  /// waveform — empty, all-zero (a past silent/failed decode that got cached),
  /// or a flat placeholder (all 0.5 while still generating) — renders as an
  /// INVISIBLE or shapeless bar with no usable thumb. In those cases the gates
  /// below fall back to the plain Slider so there is ALWAYS a visible, seekable
  /// scrubber. (The all-zero case is what made one M4A's scrubber vanish.)
  bool get _hasUsableWaveform {
    if (_waveformData.isEmpty) return false;
    final first = _waveformData.first;
    var maxV = 0.0;
    var allSame = true;
    for (final v in _waveformData) {
      if (v > maxV) maxV = v;
      if ((v - first).abs() > 1e-6) allSame = false;
    }
    return maxV >= 0.02 && !allSame;
  }

  // Podcast chapters — populated when the current song is a podcast and
  // chapters are available. Keyed by Song.id (including the virtual
  // negative ID) so we refetch on song change. Non-podcast songs leave
  // this empty; the ChapterStrip collapses to zero height.
  List<SongChapter> _chapters = [];
  int? _chaptersForSongId;
  Timer? _waveformPollTimer;
  bool _showLyrics = false;
  // Black-screen overlay for bedtime / OLED-friendly sleep mode. Mirrors
  // the cast-receiver-side BLACK_SCREEN feature so Fire TV / native users
  // get the same affordance without needing a Chromecast in the chain.
  // Tap the overlay anywhere or hit d-pad center to dismiss.
  bool _blackScreenActive = false;
  bool _isFullScreen = false;

  // Swipeable album art
  PageController? _artworkPageController;
  int _artworkPageIndex = 0; // tracks which page we're showing
  bool _isAnimatingPage = false; // prevents re-entrant page jumps

  // Smooth progress bar for immersive fullscreen
  Ticker? _smoothTicker;
  Duration _lastKnownPosition = Duration.zero;
  DateTime _lastPositionTime = DateTime.now();
  // 60fps-driven position notifier for the scrubber + time displays.
  // The smooth ticker updates THIS instead of calling setState — so
  // only the ValueListenableBuilder-wrapped slider/time text rebuild
  // on every vsync, not the entire 3700-line Now Playing tree. Before
  // this gate the per-tick setState was rebuilding artwork, playback
  // controls, lyrics, queue, and a fullscreen BackdropFilter on every
  // single frame, saturating the UI thread and triggering the
  // "Server unreachable" banner because the main thread couldn't
  // keep up with API responses fast enough.
  final ValueNotifier<Duration> _interpolatedPositionNotifier =
      ValueNotifier(Duration.zero);
  bool _isSeeking = false;
  int? _lastSongId;

  // True once the engine has reported genuine forward playback for the
  // CURRENT song. Until then the smooth ticker must NOT extrapolate the
  // position clock. On the very first stream of a not-yet-downloaded
  // podcast episode the engine reports playing=true / buffering=false
  // while real audio is still loading and position is pinned at 0 — a
  // running clock would tick up from 0 and then visibly snap back when
  // audio actually starts. Seeded true when we open/switch to a song
  // that's already past 0 (resume / open-on-playing), reset to false on
  // a song change that starts at 0, and flipped true the moment we see a
  // real forward position advance.
  bool _genuinePlaybackStarted = false;

  // Last-rendered play/buffer state. `_onPlayerStateChanged` used to
  // gate setState on "songChanged || positionChanged" only — which
  // meant a pure isPlaying flip (user tapped play/pause, service
  // paused due to buffering, etc.) would arrive via notifyListeners
  // but never trigger a rebuild, leaving the play/pause button icon
  // and the buffering spinner stuck on the last-rendered state.
  // Also linked to the UI "freeze" reports: once the smooth ticker
  // stopped firing for any reason, state flips from the service
  // couldn't wake the widget up again. Tracking these here closes
  // that gap.
  bool _lastIsPlaying = false;
  bool _lastIsBuffering = false;

  // Guard against rapid fire of F11 / ESC triggering multiple
  // concurrent fullscreen toggles. The windowManager chain does
  // setFullScreen + setSize + delay + setSize — overlapping calls
  // can leave the window in an inconsistent state.
  bool _fullscreenInFlight = false;

  // Tracks the last orientation we reacted to so build() doesn't
  // re-trigger the fullscreen toggle on every rebuild. On mobile,
  // landscape flips us into the immersive fullscreen layout and
  // hides the Android system bars; portrait restores both.
  Orientation? _lastOrientation;

  // Rapid-skip accumulator — lets the user mash +30 / -10 without each press
  // waiting for buffering. Every press accumulates into _pendingSkipTarget
  // and seeks immediately from that target, so four fast +30 taps jump +120s
  // as a single logical operation. Cleared after 600ms of no further presses.
  Duration? _pendingSkipTarget;
  Timer? _pendingSkipResetTimer;

  // Disc names cache
  int? _cachedAlbumId;
  Map<int, String> _discNames = {};

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  // Lightsaber mode detection
  bool _isStarWarsTrack(Song song) {
    return song.albumTitle.toLowerCase().contains('star wars');
  }

  // DNA mode detection (Jurassic Park)
  bool _isJurassicParkTrack(Song song) {
    final albumLower = song.albumTitle.toLowerCase();
    return albumLower.contains('jurassic park') ||
        albumLower.contains('jurassic world');
  }

  // EVH Stripes mode detection (Van Halen)
  bool _isVanHalenTrack(Song song) {
    final artistLower = song.artistName.toLowerCase();
    return artistLower == 'van halen' || artistLower.contains('van halen');
  }

  Future<void> _loadDiscNames(int albumId) async {
    if (_cachedAlbumId == albumId) return;

    try {
      final names = await _apiService.getDiscNames(albumId);
      if (mounted) {
        setState(() {
          _cachedAlbumId = albumId;
          _discNames = names;
        });
      }
    } catch (e) {
      // Non-fatal — multi-disc albums just won't show disc names.
      // Log so future failures surface in combined.log instead of
      // disappearing into a silent catch.
      AppLogger.instance.warning(
          'Failed to load disc names for album $albumId: $e');
    }
  }

  Color _getLightsaberColor(Song song) {
    final title = song.title.toLowerCase();

    final redKeywords = [
      'imperial',
      'vader',
      'duel of the fates',
      'sith',
      'dark side',
      'dark lord',
      'emperor',
      'palpatine',
      'anakin\'s dark deeds',
      'order 66',
      'grievous',
      'dooku',
      'separatist',
      'trade federation',
      'darth',
      'battle of the heroes',
      'immolation',
      'kylo',
      'snoke',
      'first order',
    ];

    final greenKeywords = [
      'yoda',
      'dagobah',
      'jedi council',
      'qui-gon',
      'qui gon',
    ];
    final purpleKeywords = ['mace windu'];

    for (final keyword in redKeywords) {
      if (title.contains(keyword)) return const Color(0xFFff4444);
    }
    for (final keyword in greenKeywords) {
      if (title.contains(keyword)) return const Color(0xFF44ff44);
    }
    for (final keyword in purpleKeywords) {
      if (title.contains(keyword)) return const Color(0xFFaa44ff);
    }
    return const Color(0xFF4488ff);
  }

  final FocusNode _focusNode = FocusNode();

  // Background-download progress for the current podcast episode (from the
  // device-sync websocket). Drives the small "saving for instant seek"
  // indicator so you can see the download is actually happening.
  int? _dlEpisodeId;
  int _dlDownloaded = 0;
  int _dlTotal = 0;

  void _onDownloadProgress(int episodeId, int downloaded, int total) {
    if (!mounted) return;
    if (episodeId != widget.audioPlayerService.currentEpisodeId) return;
    setState(() {
      _dlEpisodeId = episodeId;
      _dlDownloaded = downloaded;
      _dlTotal = total;
    });
  }

  Widget _buildDownloadIndicator() {
    final epId = widget.audioPlayerService.currentEpisodeId;
    final downloading = _dlEpisodeId != null &&
        _dlEpisodeId == epId &&
        _dlTotal > 0 &&
        _dlDownloaded < _dlTotal;
    if (!downloading) return const SizedBox.shrink();
    final pct = (_dlDownloaded / _dlTotal).clamp(0.0, 1.0);
    final mb = (_dlDownloaded / (1024 * 1024)).toStringAsFixed(0);
    final totalMb = (_dlTotal / (1024 * 1024)).toStringAsFixed(0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
      child: Row(
        children: [
          const Icon(Icons.download_rounded, size: 13, color: Color(0xFFff8c42)),
          const SizedBox(width: 6),
          Text(
            'Saving for instant seek — ${(pct * 100).toStringAsFixed(0)}%  ($mb/$totalMb MB)',
            style: const TextStyle(color: Color(0xFF9aa5b4), fontSize: 11),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 3,
                backgroundColor: Colors.white12,
                valueColor: const AlwaysStoppedAnimation(Color(0xFFff8c42)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Tracks the mirrored-target signature so we rebuild not just on control
  // start/stop, but also when the controlled device changes track or the full
  // song record finishes loading (otherwise the screen stays frozen on the
  // first fallback song — wrong title/art and an UNKNOWN format badge).
  bool _lastIsController = false;
  int? _lastMirroredSongId;
  bool _lastTargetFull = false;

  void _onSyncControlChanged() {
    if (!mounted) return;
    final c = globalDeviceSyncService.isController;
    final songId = c ? widget.audioPlayerService.currentSong?.id : null;
    final full = c && globalDeviceSyncService.hasFullTargetSong;
    if (c != _lastIsController ||
        songId != _lastMirroredSongId ||
        full != _lastTargetFull) {
      setState(() {
        _lastIsController = c;
        _lastMirroredSongId = songId;
        _lastTargetFull = full;
      });
    }
  }

  // Lyrics / black-screen toggles. When controlling another device, these are
  // screen-level controls that belong on the TARGET (like casting them to a TV),
  // so we send a remote command instead of toggling locally. Otherwise local
  // (+ mirror to the cast receiver when casting), exactly as before.
  void _toggleLyrics() {
    if (widget.audioPlayerService.isControlling) {
      globalDeviceSyncService.sendRemoteCommand('toggle_lyrics');
      return;
    }
    setState(() => _showLyrics = !_showLyrics);
    if (widget.audioPlayerService.isCasting) {
      globalCastService.toggleLyrics(_showLyrics);
    }
  }

  void _toggleBlackScreen() {
    if (widget.audioPlayerService.isControlling) {
      globalDeviceSyncService.sendRemoteCommand('toggle_black_screen');
      return;
    }
    setState(() => _blackScreenActive = !_blackScreenActive);
    if (widget.audioPlayerService.isCasting) {
      globalCastService.setBlackScreen(_blackScreenActive);
    }
  }

  @override
  void initState() {
    super.initState();
    globalDeviceSyncService.onPodcastDownloadProgress = _onDownloadProgress;
    // Rebuild when control mode flips so the screen swaps in/out of the
    // remote-control takeover. Gated on the mode actually changing so we don't
    // rebuild the whole screen on every 1Hz target-state tick (the takeover
    // view has its own AnimatedBuilder for that).
    _lastIsController = globalDeviceSyncService.isController;
    globalDeviceSyncService.addListener(_onSyncControlChanged);
    // When THIS device is being controlled, a controller's toggle_lyrics /
    // toggle_black_screen commands flip our screen state here.
    widget.audioPlayerService.onRemoteLyricsToggle = () {
      if (mounted) setState(() => _showLyrics = !_showLyrics);
    };
    widget.audioPlayerService.onRemoteBlackScreenToggle = () {
      if (mounted) setState(() => _blackScreenActive = !_blackScreenActive);
    };
    // Initialize position and song ID from service immediately (don't wait for listener)
    _lastKnownPosition = widget.audioPlayerService.position;
    _lastPositionTime = DateTime.now();
    // Seed the scrubber notifier so the slider shows the current
    // position on first paint — without this it would briefly read
    // 0 for ~16ms until the first ticker frame fires, causing a
    // visible flicker when opening the screen on a playing song.
    _interpolatedPositionNotifier.value = _lastKnownPosition;
    _lastSongId = widget.audioPlayerService.currentSong?.id;
    _lastIsPlaying = widget.audioPlayerService.isPlaying;
    _lastIsBuffering = widget.audioPlayerService.isBuffering;
    // If we open on a song that's already advanced past 0 (resume or an
    // already-playing track), treat playback as genuine immediately so
    // the scrubber starts ticking without waiting for the next advance.
    _genuinePlaybackStarted = _lastKnownPosition > Duration.zero;
    _isFullScreen = widget.startFullScreen;
    _startSmoothTicker();
    if (widget.startFullScreen) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await windowManager.setFullScreen(true);
        await Future.delayed(const Duration(milliseconds: 200));
        final size = await windowManager.getSize();
        await windowManager.setSize(Size(size.width + 1, size.height));
        await Future.delayed(const Duration(milliseconds: 50));
        await windowManager.setSize(size);
      });
    }
    _focusNode.requestFocus();
    widget.audioPlayerService.setNowPlayingVisible(true);
    widget.audioPlayerService.addListener(_onPlayerStateChanged);

    // Prime the per-song data (waveform / chapters / disc-names)
    // for the song that's already playing when this screen opens.
    // Previously these lived in build() with internal guards, but
    // calling loaders from build() is an anti-pattern — moved them
    // to the state-change listener + this one-shot initial prime.
    final initialSong = widget.audioPlayerService.currentSong;
    if (initialSong != null) {
      if (!initialSong.isPodcast && !_waveformLoading) {
        _loadWaveform(initialSong.id);
      }
      _loadChaptersFor(initialSong);
      if (initialSong.discNumber > 1) {
        _loadDiscNames(initialSong.albumId);
      }
    }
  }

  // Last live-station track we rendered. A station's song id never changes and
  // its position doesn't advance, so without this a track change wouldn't trip
  // the rebuild gate below and the screen would show a stale track.
  String? _lastStationTrackTitle;

  void _onPlayerStateChanged() {
    final newPosition = widget.audioPlayerService.position;
    final newSong = widget.audioPlayerService.currentSong;
    final newIsPlaying = widget.audioPlayerService.isPlaying;
    final newIsBuffering = widget.audioPlayerService.isBuffering;

    // Rebuild whenever *anything visible* changes — song, position
    // (at 50ms resolution to keep repaint pressure sane), play
    // state, or buffering state. Previously the gate was
    // songChanged || positionChanged only, which silently dropped
    // play/pause/buffer transitions and left the UI stuck on
    // stale state.
    final songChanged = newSong?.id != _lastSongId;
    final positionChanged =
        (newPosition - _lastKnownPosition).inMilliseconds.abs() > 50;
    final playingChanged = newIsPlaying != _lastIsPlaying;
    final bufferingChanged = newIsBuffering != _lastIsBuffering;
    final stationTrackChanged =
        widget.audioPlayerService.stationTrackTitle != _lastStationTrackTitle;
    _lastStationTrackTitle = widget.audioPlayerService.stationTrackTitle;
    _lastKnownPosition = newPosition;
    _lastPositionTime = DateTime.now();
    _lastIsPlaying = newIsPlaying;
    _lastIsBuffering = newIsBuffering;

    // Gate the interpolated scrubber clock on genuine playback (see
    // _genuinePlaybackStarted). On a song change we re-arm the gate: a
    // fresh-from-0 start must wait for a real advance, while a resume
    // that lands past 0 counts as genuine right away.
    if (songChanged) {
      _genuinePlaybackStarted = newPosition > Duration.zero;
      // A track change invalidates any in-progress scrub — clearing this
      // guards against _isSeeking sticking true across an auto-advance and
      // blocking the scrubber clock.
      _isSeeking = false;
    } else if (!_genuinePlaybackStarted &&
        newIsPlaying &&
        !newIsBuffering &&
        newPosition > Duration.zero) {
      // Self-heal: a genuine nonzero position while actively playing means
      // real audio is flowing. We intentionally do NOT require the forward
      // advance to land in this exact callback — on buffering-heavy remote
      // streams that event was routinely missed, leaving the gate stuck
      // false and the scrubber frozen at 0:00 until the screen was reopened.
      _genuinePlaybackStarted = true;
    }

    if (songChanged) {
      _lastSongId = newSong?.id;
      // Always reset artwork page to center (page 1 = current song).
      // Must run even when _isAnimatingPage is true — the swipe that triggered
      // next()/previous() set that flag, and we need to snap back to center
      // now that the song content has changed.
      if (_isMobile && _artworkPageController != null &&
          _artworkPageController!.hasClients) {
        _isAnimatingPage = true;
        _artworkPageController!.jumpToPage(1);
        _artworkPageIndex = 1;
        Future.delayed(const Duration(milliseconds: 150), () {
          if (!mounted) return;
          _isAnimatingPage = false;
        });
      }
      // Load waveform on song change (not in build() which fires on every position update)
      if (newSong != null && !_waveformLoading) {
        _loadWaveform(newSong.id);
      }
      // Load chapters on song change — only for podcasts.
      _loadChaptersFor(newSong);
      // Load disc names on song change (instead of from build()).
      // `_loadDiscNames` is a no-op when the album hasn't changed.
      if (newSong != null && newSong.discNumber > 1) {
        _loadDiscNames(newSong.albumId);
      }
    }

    // Position-only changes go to the notifier (cheap; only the
    // scrubber subtree rebuilds). Full setState fires only when
    // something the rest of the screen actually cares about has
    // changed — song, play state, buffering. Before this split,
    // position events were rebuilding the entire tree ~14x/second
    // even when Now Playing wasn't the visible route, because the
    // listener stays attached as long as the screen is mounted.
    if (positionChanged && mounted) {
      _interpolatedPositionNotifier.value = newPosition;
    }
    if (mounted &&
        (songChanged || playingChanged || bufferingChanged || stationTrackChanged)) {
      setState(() {});
    }
  }

  Future<void> _toggleFullScreen() async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;
    if (_fullscreenInFlight) return;
    _fullscreenInFlight = true;
    try {
      _isFullScreen = !_isFullScreen;
      await windowManager.setFullScreen(_isFullScreen);
      await Future.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      final size = await windowManager.getSize();
      await windowManager.setSize(Size(size.width + 1, size.height));
      await Future.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;
      await windowManager.setSize(size);
      if (!mounted) return;
      _focusNode.requestFocus();
      setState(() {});
    } finally {
      _fullscreenInFlight = false;
    }
  }

  Future<void> _exitFullScreen() async {
    if (!_isFullScreen || _fullscreenInFlight) return;
    _fullscreenInFlight = true;
    try {
      _isFullScreen = false;
      if (mounted) setState(() {});
      if (_isMobile) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        return;
      }
      await windowManager.setFullScreen(false);
      await Future.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      final size = await windowManager.getSize();
      await windowManager.setSize(Size(size.width + 1, size.height));
      await Future.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;
      await windowManager.setSize(size);
      if (!mounted) return;
      _focusNode.requestFocus();
      setState(() {});
    } finally {
      _fullscreenInFlight = false;
    }
  }

  // Called from build() on orientation change. Landscape on mobile
  // enters the same _isFullScreen layout desktop uses (artwork
  // centred, chrome hidden) and drops the Android status + nav bars
  // via SystemChrome. Portrait restores everything.
  Future<void> _syncMobileFullScreenToOrientation(
      Orientation orientation) async {
    if (!_isMobile || !mounted) return;
    final shouldBeFullScreen = orientation == Orientation.landscape;
    if (shouldBeFullScreen == _isFullScreen) return;

    if (shouldBeFullScreen) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    if (!mounted) return;
    setState(() {
      _isFullScreen = shouldBeFullScreen;
    });
  }

  void _startSmoothTicker() {
    _smoothTicker?.dispose();
    _smoothTicker = createTicker((_) {
      if (!mounted) return;
      // Only emit position updates when playback is actually moving.
      // Previously this called setState on every vsync (60Hz) which
      // rebuilt the entire ~3700-line Now Playing tree including a
      // fullscreen BackdropFilter(sigma=30-80) — saturating the UI
      // thread. Now we just bump the position notifier; the only
      // widgets that subscribe to it are the slider + time-elapsed
      // text (via ValueListenableBuilder below), so only THEY repaint
      // at 60fps. Artwork/controls/lyrics/queue/blur stay still.
      final svc = widget.audioPlayerService;
      // When controlling another device, position already arrives live — the
      // sync service interpolates the target's 1Hz pushes — so mirror it
      // directly instead of extrapolating on top (which would double-advance).
      if (svc.isControlling) {
        _interpolatedPositionNotifier.value = svc.position;
        return;
      }
      // Self-heal the playback gate from the ticker as well. If audio is
      // genuinely playing at a nonzero position but a missed listener event
      // left the gate false, arm it here and seed the interpolation anchors,
      // so the scrubber starts moving on its own instead of staying pinned at
      // 0:00 until the screen is reopened.
      // Update the scrubber every frame while audio is actively flowing. The
      // gate (_genuinePlaybackStarted) only decides whether to EXTRAPOLATE for
      // 60fps smoothness — it must NOT decide whether the scrubber moves at
      // all. Otherwise an edge case that leaves the gate false (e.g. gapless
      // auto-advance) freezes the scrubber at 0:00 until the screen is
      // reopened. Until armed, show the raw service position (stepwise); arm
      // and switch to smooth extrapolation once genuine forward motion shows.
      if (svc.isPlaying && !svc.isBuffering && !_isSeeking) {
        if (!_genuinePlaybackStarted && svc.position > Duration.zero) {
          _genuinePlaybackStarted = true;
          _lastKnownPosition = svc.position;
          _lastPositionTime = DateTime.now();
        }
        _interpolatedPositionNotifier.value = _genuinePlaybackStarted
            ? _interpolatedPosition
            : svc.position;
      }
    });
    _smoothTicker!.start();
  }


  void _stopSmoothTicker() {
    _smoothTicker?.stop();
    _smoothTicker?.dispose();
    _smoothTicker = null;
  }

  Duration get _interpolatedPosition {
    if (_isSeeking ||
        !widget.audioPlayerService.isPlaying ||
        widget.audioPlayerService.isBuffering ||
        !_genuinePlaybackStarted) {
      return _lastKnownPosition;
    }
    final elapsed = DateTime.now().difference(_lastPositionTime);
    return _lastKnownPosition + elapsed;
  }

  void _openSongAlbum(Song song) {
    if (song.isStation) return; // a live stream has no album page to open
    if (song.isPodcast) {
      _navigateToPodcast();
      return;
    }
    _pushBelowPlayer(MaterialPageRoute(
        builder: (context) => AlbumDetailScreen(
          albumId: song.albumId,
          audioPlayerService: widget.audioPlayerService,
          parentLabel: 'Now Playing',
        ),
      ),
    );
  }

  void _openSongArtist(Song song) {
    if (song.isStation) return; // a live stream has no artist page to open
    if (song.isPodcast) {
      _navigateToPodcast();
      return;
    }
    _pushBelowPlayer(MaterialPageRoute(
        builder: (context) => ArtistDetailScreen(
          artistId: song.artistId,
          audioPlayerService: widget.audioPlayerService,
          parentLabel: 'Now Playing',
        ),
      ),
    );
  }

  // Favorite button for the current item. Stations favorite as their own
  // type ('station') so they render in the Favorites screen and can't
  // collide with a song id. An unsaved radio-browser result (synthetic
  // negative id) is auto-saved on favorite — the backend upserts by URL
  // and returns the real station id.
  Widget _buildFavoriteButton(Song song, double size) {
    if (!song.isStation) {
      return FavoriteButton(itemType: 'song', itemId: song.id, size: size);
    }
    return FavoriteButton(
      key: ValueKey('fav_station_${song.id}'),
      itemType: 'station',
      itemId: song.id,
      stationUrl: song.filePath,
      size: size,
      resolveItemId: () async {
        // A station Song ALWAYS carries a negative id (saved: -dbId,
        // radio-browser: -urlHash — see stations_screen._toSong), so the
        // only reliable resolution is the URL upsert: the backend returns
        // the existing station's id for a known URL, or saves and returns
        // a new one. (song.artistName carries the genre for stations.)
        final saved = await _apiService.createStation(
          song.title,
          song.filePath,
          genre: song.artistName,
          favicon: song.stationArtworkUrl,
        );
        return (saved['id'] as num).toInt();
      },
    );
  }

  // Audio-format pill (FLAC/MP3/…) — mirrors the normal player. Reflects the
  // streamed quality: orange AAC/MP3 labels when transcoding, else the real
  // file format in its colour. Hidden for podcasts.
  Widget _buildFormatBadge(Song song) {
    if (widget.audioPlayerService.isPlayingPodcast) {
      return const SizedBox.shrink();
    }
    // Live radio: a LIVE badge instead of a file-format badge (song.fileFormat
    // is junk for a stream URL — it parses the query string).
    if (song.isStation) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.15),
          border: Border.all(color: Colors.red.withOpacity(0.6), width: 1.5),
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, color: Colors.red, size: 8),
            SizedBox(width: 6),
            Text('LIVE',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.red,
                  letterSpacing: 1.5,
                )),
          ],
        ),
      );
    }
    final quality = widget.audioPlayerService.streamQuality;
    final isTranscoding = quality != 'lossless';
    final badgeText = isTranscoding
        ? quality == 'high'
              ? 'AAC 320'
              : quality == 'medium'
              ? 'AAC 128'
              : 'MP3 96'
        : song.fileFormat;
    final badgeColor = isTranscoding ? Colors.orange : song.formatColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: badgeColor.withOpacity(0.2),
        border: Border.all(color: badgeColor, width: 1.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        badgeText,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: badgeColor,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  // "Up next" card — appears just above the scrubber during the last 15s of a
  // track, showing the next track's artwork, title/artist, and a countdown ring
  // that drains to the song's end. Tap to skip now. Driven by the position
  // notifier so only this card rebuilds (no per-frame cost). Hidden (zero size)
  // unless a real next track exists and the current one is genuinely about to end.
  Widget _buildUpNextOverlay(Song song, Duration duration) {
    const leadMs = 15000;
    return ValueListenableBuilder<Duration>(
      valueListenable: _interpolatedPositionNotifier,
      builder: (context, position, _) {
        final svc = widget.audioPlayerService;
        final queue = svc.queue;
        final idx = svc.currentIndex;
        // The track actually transitions when the crossfade STARTS — i.e.
        // crossfadeDuration before the nominal end. Count down to that point so
        // the ring hits zero exactly when the song changes, instead of finishing
        // ~5s after the next song has already begun.
        final crossfadeLeadMs =
            svc.crossfadeEnabled ? svc.crossfadeDuration.inMilliseconds : 0;
        final remainingMs =
            duration.inMilliseconds - position.inMilliseconds - crossfadeLeadMs;
        final show = !svc.isPlayingPodcast &&
            idx >= 0 &&
            idx < queue.length - 1 &&
            duration > Duration.zero &&
            remainingMs > 0 &&
            remainingMs <= leadMs;

        // Fade the card in/out. It's rendered in a Positioned overlay at the
        // call site, so showing/hiding it never shifts the surrounding layout.
        Widget child = const SizedBox.shrink(key: ValueKey('upnext-hidden'));
        if (show) {
          final next = queue[idx + 1];
          final secs = (remainingMs / 1000).ceil();
          final ringValue = (remainingMs / leadMs).clamp(0.0, 1.0);
          child = Padding(
            key: const ValueKey('upnext-card'),
            padding: const EdgeInsets.only(bottom: 8),
            child: Align(
              alignment: Alignment.centerRight,
              child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => svc.next(),
                child: Container(
                  width: 320,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xE60C1826),
                    border: Border.all(color: const Color(0x5900D4FF)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CachedNetworkImage(
                          imageUrl: _artworkUrlForSong(next),
                          width: 52,
                          height: 52,
                          fit: BoxFit.cover,
                          errorWidget: (c, u, e) => Container(
                            width: 52,
                            height: 52,
                            color: const Color(0xFF16273a),
                            child: const Icon(
                              Icons.music_note,
                              color: Color(0xFF00d4ff),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'UP NEXT',
                              style: TextStyle(
                                color: Color(0xFF00d4ff),
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 1.2,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              next.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                            Text(
                              next.artistsFormatted,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF9fb2c4),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              width: 40,
                              height: 40,
                              child: CircularProgressIndicator(
                                value: ringValue,
                                strokeWidth: 3,
                                backgroundColor: const Color(0x33FFFFFF),
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                  Color(0xFF00d4ff),
                                ),
                              ),
                            ),
                            Text(
                              '$secs',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
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

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          transitionBuilder: (c, anim) =>
              FadeTransition(opacity: anim, child: c),
          child: child,
        );
      },
    );
  }

  Widget _buildImmersiveFullScreen(
    Song song,
    bool isPlaying,
    Duration position,
    Duration duration,
  ) {
    final screenSize = MediaQuery.of(context).size;
    // Mobile landscape gets a side-by-side layout (artwork left, info
    // + controls right). The Column layout the desktop fullscreen uses
    // overflows on a short landscape phone screen — artwork alone eats
    // 45% of the ~430 px height and everything below "Album" is clipped.
    final isMobileLandscape =
        _isMobile && screenSize.width > screenSize.height;
    final artworkSize = isMobileLandscape
        ? screenSize.height * 0.82
        : screenSize.height * 0.45;
    final artistId = song.artists.isNotEmpty
        ? song.artists.first.id
        : song.artistId;
    final artistImageUrl = _apiService.getArtistImageUrl(artistId);
    final albumArtUrl = _artworkUrlForSong(song);

    // Artwork tile — same look in both layouts.
    final artworkWidget = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 40,
            spreadRadius: 10,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: CachedNetworkImage(
          imageUrl: albumArtUrl,
          width: artworkSize,
          height: artworkSize,
          fit: BoxFit.cover,
          errorWidget: (context, url, error) => Container(
            width: artworkSize,
            height: artworkSize,
            color: const Color(0xFF1a2332),
            child: const Icon(
              Icons.album,
              size: 80,
              color: Colors.white24,
            ),
          ),
        ),
      ),
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 800),
        child: Stack(
          key: ValueKey(song.id),
          fit: StackFit.expand,
          children: [
            // Background: Artist photo (for podcasts, use podcast artwork), blurred and darkened
            // Background: artist photo, pre-blurred via ImageFiltered (the blur
            // rasterizes once and is cached, since the image is static) then
            // darkened. Previously a live BackdropFilter re-blurred the WHOLE
            // screen every frame — that saturated the raster thread and froze
            // the view (scrubber stuck at 0:00 while audio kept playing; the
            // build-thread heartbeat couldn't see it because the GPU thread was
            // the one stalling).
            ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: CachedNetworkImage(
                // Stations & podcasts have no artist photo — use their own
                // artwork (station favicon / feed art) so the glassy backdrop
                // isn't the blue error-gradient. albumArtUrl == _artworkUrlForSong.
                imageUrl: (song.isPodcast || song.isStation) ? albumArtUrl : artistImageUrl,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                errorWidget: (context, url, error) => Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [const Color(0xFF1a2332), const Color(0xFF0d1b2a)],
                    ),
                  ),
                ),
              ),
            ),

            // Dark overlay for legibility (no per-frame blur — see above).
            Container(color: Colors.black.withOpacity(0.55)),

            // Exit button — overlaid in both layouts so it's always
            // reachable regardless of portrait/landscape branching.
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: IconButton(
                    icon: const Icon(
                      Icons.fullscreen_exit,
                      color: Colors.white70,
                      size: 28,
                    ),
                    tooltip: 'Exit Fullscreen (ESC)',
                    onPressed: _exitFullScreen,
                  ),
                ),
              ),
            ),

            // Remote-control badge ("Controlled by / Controlling X") — fades in
            // at top-center, mirroring the Cast indicator. Shrinks to nothing
            // when idle, so it never affects the immersive layout.
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: RemoteControlBadge(
                    service: globalDeviceSyncService,
                    onStopControl: () =>
                        globalDeviceSyncService.stopRemoteControl(),
                  ),
                ),
              ),
            ),

            // Content — layout branches on mobile landscape.
            SafeArea(
              child: isMobileLandscape
                  ? _buildLandscapeImmersive(
                      song,
                      isPlaying,
                      duration,
                      artworkWidget,
                    )
                  : Column(
                children: [
                  // Top-bar exit button placeholder — overlaid above,
                  // leave space here so portrait content alignment
                  // isn't disturbed.
                  const SizedBox(height: 60),

                  const Spacer(),

                  artworkWidget,

                  const SizedBox(height: 32),

                  // Song title
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () => _openSongAlbum(song),
                              child: Text(
                                _nowPlayingTitle(song),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 28,
                                  fontWeight: FontWeight.bold,
                                ),
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                        if (song.isExplicit) ...[
                          const SizedBox(width: 8),
                          const ExplicitBadge(fontSize: 12),
                        ],
                        if (song.isAtmos || song.isSurround) ...[
                          const SizedBox(width: 8),
                          SpatialBadge(song: song, fontSize: 12),
                        ],
                        if (song.isHdcd) ...[
                          const SizedBox(width: 8),
                          const HdcdBadge(fontSize: 12),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 8),

                  // Artist name — tap to open the artist
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => _openSongArtist(song),
                        child: Text(
                          _nowPlayingArtist(song),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 18,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 4),

                  // Album title — tap to open the album
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => _openSongAlbum(song),
                        child: Text(
                          _stationHasLiveTrack(song) ? song.title : song.albumTitle,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 14,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),


                  const SizedBox(height: 12),
                  _buildFormatBadge(song),

                  const Spacer(),

                  // Progress bar. Wrapped in ValueListenableBuilder so
                  // only the slider + elapsed-time text rebuild on
                  // each ticker frame — the controls, artwork, queue,
                  // lyrics, and BackdropFilter above us stay still.
                  //
                  // Stack so the "up next" card sits in a Positioned overlay
                  // above the bar — it takes no layout row, so nothing shifts.
                  if (!song.isStation) Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: ValueListenableBuilder<Duration>(
                      valueListenable: _interpolatedPositionNotifier,
                      builder: (context, position, _) {
                        final displayPosition =
                            position.inMilliseconds > duration.inMilliseconds
                                ? duration
                                : position;
                        return Column(
                          children: [
                            // Fullscreen scrubber: show the real waveform (and
                            // its lightsaber/DNA/EVH treatment) for music, just
                            // like the normal screen. Falls back to the plain
                            // slider for podcasts or before the waveform loads.
                            if (_hasUsableWaveform &&
                                !widget.audioPlayerService.isPlayingPodcast)
                              WaveformProgressBar(
                                waveformData: _waveformData,
                                position: displayPosition,
                                duration: duration,
                                onSeek: (newPosition) {
                                  widget.audioPlayerService.seek(newPosition);
                                },
                                lightsaberMode: _isStarWarsTrack(song),
                                lightsaberColor: _isStarWarsTrack(song)
                                    ? _getLightsaberColor(song)
                                    : null,
                                dnaMode: _isJurassicParkTrack(song),
                                evhStripesMode: _isVanHalenTrack(song),
                              )
                            else
                              SliderTheme(
                                data: SliderThemeData(
                                  trackHeight: 3,
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 6,
                                  ),
                                  overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 14,
                                  ),
                                  activeTrackColor: const Color(0xFF00d4ff),
                                  inactiveTrackColor: Colors.white24,
                                  thumbColor: const Color(0xFF00d4ff),
                                ),
                                child: Slider(
                                  value:
                                      position.inMilliseconds.toDouble().clamp(
                                            0,
                                            duration.inMilliseconds.toDouble(),
                                          ),
                                  max: duration.inMilliseconds.toDouble().clamp(
                                        1,
                                        double.infinity,
                                      ),
                                  onChanged: (value) {
                                    _isSeeking = true;
                                    final newPos =
                                        Duration(milliseconds: value.toInt());
                                    _lastKnownPosition = newPos;
                                    // Bump the notifier directly — only
                                    // this builder needs to know, no
                                    // full-screen setState.
                                    _interpolatedPositionNotifier.value =
                                        newPos;
                                  },
                                  onChangeEnd: (value) {
                                    _isSeeking = false;
                                    final newPos =
                                        Duration(milliseconds: value.toInt());
                                    widget.audioPlayerService.seek(newPos);
                                    _lastKnownPosition = newPos;
                                    _lastPositionTime = DateTime.now();
                                    _interpolatedPositionNotifier.value =
                                        newPos;
                                  },
                                ),
                              ),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    _formatDuration(displayPosition),
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 12,
                                    ),
                                  ),
                                  Text(
                                    _formatDuration(duration),
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                      // "Up next" overlay — Positioned with a negative top so it
                      // floats above the scrubber without taking a layout row.
                      Positioned(
                        top: -80,
                        left: 40,
                        right: 40,
                        child: _buildUpNextOverlay(song, duration),
                      ),
                    ],
                  ),

                  const SizedBox(height: 8),

                  // Playback controls
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: Icon(
                          widget.audioPlayerService.isShuffled
                              ? Icons.shuffle_on_outlined
                              : Icons.shuffle,
                          color: widget.audioPlayerService.isShuffled
                              ? const Color(0xFF00d4ff)
                              : Colors.white54,
                          size: 24,
                        ),
                        onPressed: () =>
                            widget.audioPlayerService.toggleShuffle(),
                      ),
                      const SizedBox(width: 16),
                      IconButton(
                        icon: const Icon(
                          Icons.skip_previous,
                          color: Colors.white,
                          size: 36,
                        ),
                        onPressed: () => widget.audioPlayerService.previous(),
                      ),
                      const SizedBox(width: 16),
                      Container(
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                        ),
                        child: widget.audioPlayerService.isBuffering
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 36,
                                  height: 36,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    color: Colors.black,
                                  ),
                                ),
                              )
                            : IconButton(
                                icon: Icon(
                                  isPlaying ? Icons.pause : Icons.play_arrow,
                                  color: Colors.black,
                                  size: 36,
                                ),
                                onPressed: () =>
                                    widget.audioPlayerService.togglePlayPause(),
                              ),
                      ),
                      const SizedBox(width: 16),
                      IconButton(
                        icon: const Icon(
                          Icons.skip_next,
                          color: Colors.white,
                          size: 36,
                        ),
                        onPressed: () => widget.audioPlayerService.next(),
                      ),
                      const SizedBox(width: 16),
                      IconButton(
                        icon: Icon(
                          widget.audioPlayerService.repeatMode == RepeatMode.one
                              ? Icons.repeat_one
                              : Icons.repeat,
                          color:
                              widget.audioPlayerService.repeatMode !=
                                  RepeatMode.off
                              ? const Color(0xFF00d4ff)
                              : Colors.white54,
                          size: 24,
                        ),
                        onPressed: () =>
                            widget.audioPlayerService.toggleRepeat(),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),
                  // Secondary actions — desktop full-screen has no app bar, so
                  // surface favorite + add-to-playlist here.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.lyrics,
                          color: _showLyrics
                              ? const Color(0xFF00d4ff)
                              : Colors.white70,
                          size: 24,
                        ),
                        tooltip: 'Lyrics',
                        onPressed: _toggleLyrics,
                      ),
                      const SizedBox(width: 28),
                      _buildFavoriteButton(song, 26),
                      const SizedBox(width: 28),
                      IconButton(
                        icon: const Icon(
                          Icons.playlist_add,
                          color: Colors.white70,
                          size: 24,
                        ),
                        tooltip: 'Add to playlist',
                        onPressed: () => _showAddToPlaylistDialog(song),
                      ),
                    ],
                  ),

                  const SizedBox(height: 40),
                ],
              ),
            ),
            // Lyrics overlay — floats over the whole player when toggled, with a
            // translucent scrim so the blurred art shows through. Fades in/out;
            // shared by both layouts since it lives in the outer Stack.
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_showLyrics,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: !_showLyrics
                      ? const SizedBox.shrink(key: ValueKey('lyrics-off'))
                      : GestureDetector(
                          key: const ValueKey('lyrics-on'),
                          onTap: () => setState(() => _showLyrics = false),
                          child: Container(
                            color: Colors.black.withOpacity(0.62),
                            child: SafeArea(
                              child: Column(
                                children: [
                                  Align(
                                    alignment: Alignment.topRight,
                                    child: Padding(
                                      padding: const EdgeInsets.all(8),
                                      child: IconButton(
                                        icon: const Icon(
                                          Icons.close,
                                          color: Colors.white70,
                                        ),
                                        tooltip: 'Close lyrics',
                                        onPressed: () => setState(
                                          () => _showLyrics = false,
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    // Absorb taps on the lyrics so scrolling/
                                    // tapping text doesn't dismiss the overlay.
                                    child: GestureDetector(
                                      onTap: () {},
                                      child: LyricsView(
                                        audioPlayerService:
                                            widget.audioPlayerService,
                                        songId: song.id,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Landscape-only immersive layout for phones. Column layout
  // overflows on a short landscape screen; split into artwork on
  // the left (square, vertically-filling), info + controls on the
  // right (stacked).
  Widget _buildLandscapeImmersive(
    Song song,
    bool isPlaying,
    Duration duration,
    Widget artworkWidget,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Left: artwork, centred vertically.
          Expanded(
            flex: 5,
            child: Center(child: artworkWidget),
          ),
          const SizedBox(width: 32),
          // Right: title, artist, album, progress bar, controls.
          Expanded(
            flex: 6,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title + badges
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () => _openSongAlbum(song),
                          child: Text(
                            song.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                    if (song.isExplicit) ...[
                      const SizedBox(width: 8),
                      const ExplicitBadge(fontSize: 11),
                    ],
                    if (song.isAtmos || song.isSurround) ...[
                      const SizedBox(width: 8),
                      SpatialBadge(song: song, fontSize: 11),
                    ],
                    if (song.isHdcd) ...[
                      const SizedBox(width: 8),
                      const HdcdBadge(fontSize: 11),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => _openSongArtist(song),
                    child: Text(
                      song.artistsFormatted,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 15),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => _openSongAlbum(song),
                    child: Text(
                      song.albumTitle,
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                _buildFormatBadge(song),
                const SizedBox(height: 16),
                // Progress. ExcludeFocus: Slider is focusable by default
                // and would intercept Fire TV d-pad arrows (Slider's
                // built-in semantics map left/right to "decrement /
                // increment value"). With it grabbing initial focus on
                // an immersive TV layout, the user couldn't navigate to
                // any of the playback buttons. Slider is still draggable
                // by touch on phones; just not part of d-pad traversal.
                // Scrubber + time row — both wrapped in
                // ValueListenableBuilders so only they rebuild at
                // 60Hz, not the surrounding controls/artwork/etc.
                // Stack so the up-next card overlays above the bar (no shift).
                if (!song.isStation) Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ExcludeFocus(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 14),
                      activeTrackColor: const Color(0xFF00d4ff),
                      inactiveTrackColor: Colors.white24,
                      thumbColor: const Color(0xFF00d4ff),
                    ),
                    child: ValueListenableBuilder<Duration>(
                      valueListenable: _interpolatedPositionNotifier,
                      builder: (context, position, _) => Slider(
                        value: position.inMilliseconds.toDouble().clamp(
                              0,
                              duration.inMilliseconds.toDouble(),
                            ),
                        max: duration.inMilliseconds.toDouble().clamp(
                              1,
                              double.infinity,
                            ),
                        onChanged: (value) {
                          _isSeeking = true;
                          final newPos =
                              Duration(milliseconds: value.toInt());
                          _lastKnownPosition = newPos;
                          // Notifier bump only — no full-screen rebuild.
                          _interpolatedPositionNotifier.value = newPos;
                        },
                        onChangeEnd: (value) {
                          _isSeeking = false;
                          final newPos =
                              Duration(milliseconds: value.toInt());
                          widget.audioPlayerService.seek(newPos);
                          _lastKnownPosition = newPos;
                          _lastPositionTime = DateTime.now();
                          _interpolatedPositionNotifier.value = newPos;
                        },
                      ),
                    ),
                  ),
                ),
                    // "Up next" overlay above the landscape scrubber (no shift).
                    Positioned(
                      top: -80,
                      left: 0,
                      right: 0,
                      child: _buildUpNextOverlay(song, duration),
                    ),
                  ],
                ),
                if (!song.isStation) Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      ValueListenableBuilder<Duration>(
                        valueListenable: _interpolatedPositionNotifier,
                        builder: (context, position, _) {
                          final displayPosition =
                              position.inMilliseconds > duration.inMilliseconds
                                  ? duration
                                  : position;
                          return Text(
                            _formatDuration(displayPosition),
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 11),
                          );
                        },
                      ),
                      Text(
                        _formatDuration(duration),
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // Controls
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: Icon(
                        widget.audioPlayerService.isShuffled
                            ? Icons.shuffle_on_outlined
                            : Icons.shuffle,
                        color: widget.audioPlayerService.isShuffled
                            ? const Color(0xFF00d4ff)
                            : Colors.white54,
                        size: 22,
                      ),
                      onPressed: () =>
                          widget.audioPlayerService.toggleShuffle(),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.skip_previous,
                          color: Colors.white, size: 32),
                      onPressed: () => widget.audioPlayerService.previous(),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                      ),
                      child: widget.audioPlayerService.isBuffering
                          ? const Padding(
                              padding: EdgeInsets.all(10),
                              child: SizedBox(
                                width: 32,
                                height: 32,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                  color: Colors.black,
                                ),
                              ),
                            )
                          : IconButton(
                              icon: Icon(
                                isPlaying
                                    ? Icons.pause
                                    : Icons.play_arrow,
                                color: Colors.black,
                                size: 32,
                              ),
                              onPressed: () => widget
                                  .audioPlayerService
                                  .togglePlayPause(),
                            ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.skip_next,
                          color: Colors.white, size: 32),
                      onPressed: () => widget.audioPlayerService.next(),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: Icon(
                        widget.audioPlayerService.repeatMode ==
                                RepeatMode.one
                            ? Icons.repeat_one
                            : Icons.repeat,
                        color: widget.audioPlayerService.repeatMode !=
                                RepeatMode.off
                            ? const Color(0xFF00d4ff)
                            : Colors.white54,
                        size: 22,
                      ),
                      onPressed: () =>
                          widget.audioPlayerService.toggleRepeat(),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Secondary controls row — only present in the landscape
                // immersive layout because the regular app bar with these
                // buttons is hidden in immersive mode. Without this row,
                // there is no path to lyrics, sleep timer, queue, or
                // black-screen mode at all in landscape.
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.lyrics,
                        color: _showLyrics
                            ? const Color(0xFF00d4ff)
                            : Colors.white70,
                        size: 22,
                      ),
                      onPressed: _toggleLyrics,
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: Icon(
                        Icons.bedtime,
                        color: widget.audioPlayerService.isSleepTimerActive
                            ? const Color(0xFF00d4ff)
                            : Colors.white70,
                        size: 22,
                      ),
                      onPressed: () => _showSleepTimerDialog(),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: Icon(
                        Icons.dark_mode,
                        color: _blackScreenActive
                            ? const Color(0xFF00d4ff)
                            : Colors.white70,
                        size: 22,
                      ),
                      onPressed: _toggleBlackScreen,
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(
                        Icons.queue_music,
                        color: Colors.white70,
                        size: 22,
                      ),
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
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(
                        Icons.info_outline,
                        color: Colors.white70,
                        size: 22,
                      ),
                      onPressed: () => _showSongStats(song),
                    ),
                    const SizedBox(width: 8),
                    _buildFavoriteButton(song, 22),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(
                        Icons.playlist_add,
                        color: Colors.white70,
                        size: 22,
                      ),
                      tooltip: 'Add to playlist',
                      onPressed: () => _showAddToPlaylistDialog(song),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    if (globalDeviceSyncService.onPodcastDownloadProgress == _onDownloadProgress) {
      globalDeviceSyncService.onPodcastDownloadProgress = null;
    }
    globalDeviceSyncService.removeListener(_onSyncControlChanged);
    widget.audioPlayerService.onRemoteLyricsToggle = null;
    widget.audioPlayerService.onRemoteBlackScreenToggle = null;
    _waveformPollTimer?.cancel();
    _pendingSkipResetTimer?.cancel();
    _stopSmoothTicker();
    // Fire-and-forget async fullscreen teardown — scheduled so its
    // setState + windowManager calls run on the next event-loop
    // tick, after this dispose() has returned and `mounted` is
    // false. Inside `_exitFullScreen` we rely on the updated
    // mounted check there to skip setState post-dispose. Previously
    // dispose was calling the async method directly and letting
    // late setStates fire against a disposed widget.
    if (_isFullScreen) {
      _isFullScreen = false; // stop _exitFullScreen's own early-return
      Future.microtask(() async {
        if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
          try {
            await windowManager.setFullScreen(false);
          } catch (_) {}
        } else {
          try {
            await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
          } catch (_) {}
        }
      });
    }
    _artworkPageController?.dispose();
    _focusNode.dispose();
    _interpolatedPositionNotifier.dispose();
    widget.audioPlayerService.removeListener(_onPlayerStateChanged);
    widget.audioPlayerService.setNowPlayingVisible(false);
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    final seconds = duration.inSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  void _navigateToSource() {
    // Podcast: navigate to podcast detail screen
    if (widget.audioPlayerService.isPlayingPodcast) {
      _navigateToPodcast();
      return;
    }

    final sourceType = widget.audioPlayerService.sourceType;
    final sourceId = widget.audioPlayerService.sourceId;

    if (sourceType == null) return;

    switch (sourceType) {
      case 'station':
        _pushBelowPlayer(MaterialPageRoute(
            builder: (context) => StationsScreen(
              audioPlayerService: widget.audioPlayerService,
            ),
          ),
        );
        break;
      case 'album':
        if (sourceId != null) {
          _pushBelowPlayer(MaterialPageRoute(
              builder: (context) => AlbumDetailScreen(
                albumId: sourceId,
                audioPlayerService: widget.audioPlayerService,
                parentLabel: 'Now Playing',
              ),
            ),
          );
        }
        break;
      case 'artist':
        if (sourceId != null) {
          _pushBelowPlayer(MaterialPageRoute(
              builder: (context) => ArtistDetailScreen(
                artistId: sourceId,
                audioPlayerService: widget.audioPlayerService,
                parentLabel: 'Now Playing',
              ),
            ),
          );
        }
        break;
      case 'playlist':
        if (sourceId != null) {
          _pushBelowPlayer(MaterialPageRoute(
              builder: (context) => PlaylistDetailScreen(
                playlistId: sourceId,
                audioPlayerService: widget.audioPlayerService,
              ),
            ),
          );
        }
        break;
      case 'favorites':
        _pushBelowPlayer(MaterialPageRoute(
            builder: (context) =>
                FavoritesScreen(audioPlayerService: widget.audioPlayerService),
          ),
        );
        break;
      case 'recently_played':
        _pushBelowPlayer(MaterialPageRoute(
            builder: (context) => RecentlyPlayedScreen(
              audioPlayerService: widget.audioPlayerService,
            ),
          ),
        );
        break;
      case 'most_played':
        _pushBelowPlayer(MaterialPageRoute(
            builder: (context) =>
                MostPlayedScreen(audioPlayerService: widget.audioPlayerService),
          ),
        );
        break;
      case 'all_songs':
        // Just pop back - no dedicated screen for all songs
        Navigator.pop(context);
        break;
      default:
        // 'single' or unknown - do nothing
        break;
    }
  }

  /// Load chapters for the current song into state. For podcasts we use
  /// the episode ID (virtual song IDs are negative and can't be looked up
  /// as a songs row directly). For music, we short-circuit — music doesn't
  /// have chapters in this feature yet.
  Future<void> _loadChaptersFor(dynamic song) async {
    if (song == null) return;
    // Skip work if we've already loaded for this song. Use song.id as the
    // cache key — it's unique per Song instance (even virtual ones).
    if (_chaptersForSongId == song.id) return;
    _chaptersForSongId = song.id;

    if (!song.isPodcast) {
      if (_chapters.isNotEmpty && mounted) {
        setState(() => _chapters = const []);
      }
      return;
    }

    final episodeId = song.podcastEpisodeId as int?;
    if (episodeId == null) return;

    final raw = await _apiService.getEpisodeChapters(episodeId);
    if (!mounted) return;
    // Guard against late responses — only apply if this is still the
    // current song on screen.
    if (_chaptersForSongId != song.id) return;
    setState(() {
      _chapters = raw.map((m) => SongChapter.fromJson(m)).toList();
    });
  }

  /// Chapter strip + "Chapters" button that opens a full-list modal.
  /// Shown only for podcasts with chapter data. The strip is great for
  /// scanning a few chapters ahead; the modal is faster when there are
  /// 20+ chapters (ASOT: 29 tracks) and you want to jump somewhere
  /// specific without scrolling sideways.
  Widget _buildChaptersRow() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildDownloadIndicator(),
        Row(
          children: [
        Expanded(
          // Drive the strip off the live position notifier (the same source the
          // progress bar uses) so the highlighted chapter tracks playback.
          // Previously it took _interpolatedPosition captured at full-screen
          // rebuild time — which is infrequent — so the highlight froze on the
          // chapter active at the last rebuild (usually the first one).
          child: ValueListenableBuilder<Duration>(
            valueListenable: _interpolatedPositionNotifier,
            builder: (_, livePos, __) => ChapterStrip(
              chapters: _chapters,
              position: livePos,
              onSeek: (pos) =>
                  widget.audioPlayerService.seek(pos, autoplay: true),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 12, left: 4),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1e2a3a),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white12),
            ),
            child: IconButton(
              icon: const Icon(Icons.list_alt, color: Color(0xFFff8c42)),
              tooltip: 'Chapter list',
              onPressed: () => ChaptersSheet.show(
                context,
                chapters: _chapters,
                currentPosition: _interpolatedPosition,
                onSeek: (pos) =>
                    widget.audioPlayerService.seek(pos, autoplay: true),
              ),
            ),
          ),
        ),
      ],
        ),
      ],
    );
  }

  /// Relative skip that handles rapid-fire presses correctly.
  ///
  /// The old inline handlers computed `pos + delta` from a closed-over
  /// `pos` that was captured at widget build time. While the player was
  /// still buffering the previous seek, no rebuild happened, so a second
  /// tap would compute from the same stale position and the two seeks
  /// effectively collapsed into one.
  ///
  /// We keep a `_pendingSkipTarget` that survives rebuilds: each press
  /// reads from it (if fresh) or from the live player position, applies
  /// the delta, clamps to [0, duration], and seeks. A 600 ms idle timer
  /// clears the accumulator so a later isolated tap starts from the
  /// real position again.
  void _skipRelative(Duration delta) {
    final player = widget.audioPlayerService;
    final duration = player.duration;

    final base = _pendingSkipTarget ?? player.position;
    var target = base + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;

    _pendingSkipTarget = target;
    _pendingSkipResetTimer?.cancel();
    _pendingSkipResetTimer = Timer(const Duration(milliseconds: 600), () {
      _pendingSkipTarget = null;
    });

    player.seek(target);
  }

  // --- Album-style chapter navigation (podcasts with chapters) ------------
  // The episode is one continuous file; "tracks" are chapter markers, so
  // next/prev = seek between chapter boundaries and loop = the A-B loop set
  // to the current chapter's bounds.

  bool get _podcastHasChapters =>
      widget.audioPlayerService.isPlayingPodcast && _chapters.isNotEmpty;

  /// Index of the chapter at the current position (or a pending skip target),
  /// or -1 if there are no chapters.
  int _activeChapterIndex() {
    if (_chapters.isEmpty) return -1;
    final secs =
        (_pendingSkipTarget ?? widget.audioPlayerService.position).inSeconds;
    int idx = 0;
    for (int i = 0; i < _chapters.length; i++) {
      if (secs >= _chapters[i].startTimeSeconds) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  /// End of chapter [i] = start of the next chapter, or the episode end.
  Duration _chapterEnd(int i) {
    if (i + 1 < _chapters.length) {
      return Duration(seconds: _chapters[i + 1].startTimeSeconds);
    }
    final d = widget.audioPlayerService.duration;
    return d > Duration.zero
        ? d
        : Duration(seconds: _chapters[i].startTimeSeconds + 3600);
  }

  void _seekToNextChapter() {
    final i = _activeChapterIndex();
    if (i < 0 || i + 1 >= _chapters.length) return; // already on the last one
    widget.audioPlayerService
        .seek(Duration(seconds: _chapters[i + 1].startTimeSeconds));
  }

  void _seekToPrevChapter() {
    final i = _activeChapterIndex();
    if (i < 0) return;
    final player = widget.audioPlayerService;
    final start = _chapters[i].startTimeSeconds;
    // Standard "previous track" feel: restart the current chapter if we're
    // more than 3s in, otherwise jump to the previous one.
    if (player.position.inSeconds - start > 3 || i == 0) {
      player.seek(Duration(seconds: start));
    } else {
      player.seek(Duration(seconds: _chapters[i - 1].startTimeSeconds));
    }
  }

  bool _isLoopingActiveChapter() {
    final svc = widget.audioPlayerService;
    if (svc.loopPointA == null || svc.loopPointB == null) return false;
    final i = _activeChapterIndex();
    if (i < 0) return false;
    return svc.loopPointA!.inSeconds == _chapters[i].startTimeSeconds;
  }

  void _toggleChapterLoop() {
    final svc = widget.audioPlayerService;
    if (_isLoopingActiveChapter()) {
      svc.clearLoop();
    } else {
      final i = _activeChapterIndex();
      if (i < 0) return;
      svc.setLoopRegion(
        Duration(seconds: _chapters[i].startTimeSeconds),
        _chapterEnd(i),
      );
    }
    setState(() {});
  }

  Future<void> _loadWaveform(int songId) async {
    if (_waveformLoading) return;
    if (!mounted) return;
    // Skip reload if we already have waveform data for this exact song
    // (e.g. shuffle toggle fires song change but same song keeps playing)
    if (_waveformSongId == songId && _waveformData.isNotEmpty) return;

    // Set loading state synchronously if possible, defer if called during build
    _waveformLoading = true;
    _waveformSongId = songId;
    _waveformData = [];
    try {
      setState(() {});
    } catch (_) {
      // setState during build — schedule a rebuild for next frame
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }

    final loadStart = DateTime.now();
    AppLogger.instance.info('📊 [NowPlaying] Waveform fetch START song=$songId');
    try {
      // Check pre-fetch cache first
      final cached = widget.audioPlayerService.prefetchedWaveforms.remove(
        songId,
      );
      final waveform = cached ?? await _apiService.getWaveform(songId);
      final ms = DateTime.now().difference(loadStart).inMilliseconds;
      if (cached != null) {
        AppLogger.instance.info('🔮 [NowPlaying] Waveform cache HIT song=$songId (${ms}ms)');
      } else {
        AppLogger.instance.info(
          '📊 [NowPlaying] Waveform fetch DONE song=$songId '
          '(${ms}ms, samples=${waveform.length})',
        );
      }
      if (mounted) {
        setState(() {
          _waveformData = waveform;
          _waveformLoading = false;
        });

        // Poll if backend returned placeholder (still generating)
        final isPlaceholder = waveform.every((v) => v == 0.5);
        if (isPlaceholder) {
          _waveformPollTimer?.cancel();
          int retries = 0;
          const maxRetries = 12; // 60 seconds max polling
          _waveformPollTimer = Timer.periodic(const Duration(seconds: 5), (
            timer,
          ) async {
            retries++;
            if (!mounted || _waveformSongId != songId || retries > maxRetries) {
              timer.cancel();
              return;
            }
            try {
              final refreshed = await _apiService.getWaveform(songId);
              final stillPlaceholder = refreshed.every((v) => v == 0.5);
              if (!stillPlaceholder && mounted) {
                timer.cancel();
                setState(() {
                  _waveformData = refreshed;
                });
              }
            } catch (_) {}
          });
        }
      }
    } catch (e) {
      final ms = DateTime.now().difference(loadStart).inMilliseconds;
      AppLogger.instance.warning(
        '❌ [NowPlaying] Waveform fetch FAILED song=$songId after ${ms}ms: $e',
      );
      if (mounted) {
        setState(() {
          _waveformData = List.filled(1000, 0.5);
          _waveformLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.audioPlayerService.currentSong;
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    // Mobile only: on every orientation change, flip the fullscreen
    // layout + Android system UI to match. Scheduled post-frame so
    // we don't call setState during build.
    if (_isMobile) {
      final orientation = MediaQuery.of(context).orientation;
      if (orientation != _lastOrientation) {
        _lastOrientation = orientation;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _syncMobileFullScreenToOrientation(orientation);
        });
      }
    }
    final artworkSize = _isMobile
        ? (screenWidth * 0.65).clamp(200.0, 280.0)
        : (screenHeight * 0.35).clamp(200.0, 500.0);

    // Waveform + chapters + disc-names are all loaded from
    // `_onPlayerStateChanged` on song change. The priming for a
    // screen that opens with a song already playing is handled
    // in `initState` (see `_primeCurrentSongData`), not here.
    // Calling loader methods from build() historically caused
    // redundant API requests and had subtle rebuild-loop risk.

    final isPlaying = widget.audioPlayerService.isPlaying;
    final position = widget.audioPlayerService.position;
    // The audio engine occasionally reports a zero duration for a track whose
    // length it never resolves (some streamed/transcoded files don't expose it
    // in the container). A zero duration clamps the whole scrubber to 0:00/0:00
    // — position is shown as min(position, duration) = 0 even mid-song. Fall
    // back to the song's known metadata length (seconds, from the DB) so the
    // scrubber and time readouts work regardless of what the decoder reports.
    var duration = widget.audioPlayerService.duration;
    if (duration <= Duration.zero && song != null && song.duration > 0) {
      duration = Duration(seconds: song.duration);
    }

    if (song == null) {
      return MouseBackButtonWrapper(
        child: Scaffold(
          appBar: AppBar(title: const Text('Now Playing')),
          body: const Center(child: Text('No song playing')),
        ),
      );
    }

    // Black-screen overlay (bedtime / OLED-friendly mode). Shown above
    // every layout — wraps the entire Now Playing widget tree in a Stack
    // so the overlay covers fullscreen artwork, secondary controls, and
    // anything else regardless of which layout branch rendered. Tapping
    // anywhere on the overlay dismisses it.
    final blackScreenOverlay = _blackScreenActive
        ? Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                setState(() => _blackScreenActive = false);
                if (widget.audioPlayerService.isCasting) {
                  globalCastService.setBlackScreen(false);
                }
              },
              child: FocusableActionDetector(
                autofocus: true,
                actions: <Type, Action<Intent>>{
                  ActivateIntent: CallbackAction<ActivateIntent>(
                    onInvoke: (_) {
                      setState(() => _blackScreenActive = false);
                      if (widget.audioPlayerService.isCasting) {
                        globalCastService.setBlackScreen(false);
                      }
                      return null;
                    },
                  ),
                },
                child: Container(color: Colors.black),
              ),
            ),
          )
        : const SizedBox.shrink();

    return Stack(
      children: [
        KeyboardListener(
      focusNode: _focusNode,
      // Desktop needs autofocus so F11 (toggle fullscreen) and Escape
      // (exit fullscreen / pop) reach the onKeyEvent handler below.
      // Android (phone + Fire TV) does NOT — KeyboardListener doesn't
      // render anything visible, so claiming focus here means the
      // user's d-pad presses bounce off an invisible widget and Now
      // Playing becomes unnavigable. Fire TV doesn't need F11 (no
      // fullscreen toggle) or Escape (system Back button pops the
      // route via Navigator's default), so losing key handling on
      // Android is fine.
      autofocus: !_isMobile,
      onKeyEvent: (event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.f11) {
            // Guard against rapid double-press firing two async
            // toggleFullScreen calls concurrently. The method
            // itself serializes via `_fullscreenInFlight`.
            if (!_fullscreenInFlight) _toggleFullScreen();
          } else if (event.logicalKey == LogicalKeyboardKey.escape) {
            if (_isFullScreen) {
              if (!_fullscreenInFlight) _exitFullScreen();
            } else {
              Navigator.pop(context);
            }
          }
        }
      },
      child: _isFullScreen
          ? _buildImmersiveFullScreen(song, isPlaying, position, duration)
          : MouseBackButtonWrapper(
              child: Scaffold(
                extendBodyBehindAppBar: true,
                appBar: AppBar(
                  title: _isMobile
                      ? (widget.audioPlayerService.playingFromDisplay != null
                            ? GestureDetector(
                                onTap: () => _navigateToSource(),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text(
                                      'PLAYING FROM',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey,
                                        letterSpacing: 1.2,
                                      ),
                                    ),
                                    Text(
                                      widget
                                          .audioPlayerService
                                          .playingFromDisplay!,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: Color(0xFF00d4ff),
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : null)
                      : const Text('Now Playing'),
                  centerTitle: true,
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  leadingWidth: _isMobile ? 96 : null,
                  leading: _isMobile
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.arrow_back),
                              tooltip: 'Back',
                              onPressed: () => Navigator.pop(context),
                            ),
                            const SizedBox(width: 48), // Balance the cast + menu buttons
                          ],
                        )
                      : IconButton(
                          icon: const Icon(Icons.arrow_back),
                          tooltip: 'Back',
                          onPressed: () => Navigator.pop(context),
                        ),
                  actions: _isMobile
                      ? [
                          if (_showLyrics)
                            IconButton(
                              icon: const Icon(Icons.lyrics, color: Color(0xFF00d4ff)),
                              tooltip: 'Close Lyrics',
                              onPressed: () {
                                setState(() => _showLyrics = false);
                                if (widget.audioPlayerService.isCasting) {
                                  globalCastService.toggleLyrics(false);
                                }
                              },
                            ),
                          CastButton(
                            castService: globalCastService,
                            audioPlayerService: widget.audioPlayerService,
                            iconSize: 24,
                          ),
                          PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert),
                            color: const Color(0xFF1a2332),
                            onSelected: (value) {
                              switch (value) {
                                case 'info':
                                  _showSongStats(song);
                                  break;
                                case 'sleep':
                                  _showSleepTimerDialog();
                                  break;
                                case 'album':
                                  _pushBelowPlayer(MaterialPageRoute(
                                      builder: (context) => AlbumDetailScreen(
                                        albumId: song.albumId,
                                        audioPlayerService:
                                            widget.audioPlayerService,
                                        parentLabel: 'Now Playing',
                                      ),
                                    ),
                                  );
                                  break;
                                case 'artist':
                                  _pushBelowPlayer(MaterialPageRoute(
                                      builder: (context) => ArtistDetailScreen(
                                        artistId: song.artistId,
                                        audioPlayerService:
                                            widget.audioPlayerService,
                                        parentLabel: 'Now Playing',
                                      ),
                                    ),
                                  );
                                  break;
                                case 'add_to_playlist':
                                  _showAddToPlaylistDialog(song);
                                  break;
                                case 'black_screen':
                                  _toggleBlackScreen();
                                  break;
                                case 'quality':
                                  _showQualityDialog();
                                  break;
                                case 'devices':
                                  showModalBottomSheet(
                                    context: context,
                                    backgroundColor: Colors.transparent,
                                    isScrollControlled: true,
                                    builder: (_) => DevicesSheet(
                                      audioPlayerService: widget.audioPlayerService,
                                    ),
                                  );
                                  break;
                              }
                            },
                            itemBuilder: (context) => [
                              const PopupMenuItem(
                                value: 'album',
                                child: ListTile(
                                  leading: Icon(
                                    Icons.album,
                                    color: Colors.white,
                                  ),
                                  title: Text('Go to Album'),
                                  contentPadding: EdgeInsets.zero,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                              const PopupMenuItem(
                                value: 'artist',
                                child: ListTile(
                                  leading: Icon(
                                    Icons.person,
                                    color: Colors.white,
                                  ),
                                  title: Text('Go to Artist'),
                                  contentPadding: EdgeInsets.zero,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                              const PopupMenuItem(
                                value: 'add_to_playlist',
                                child: ListTile(
                                  leading: Icon(
                                    Icons.playlist_add,
                                    color: Colors.white,
                                  ),
                                  title: Text('Add to Playlist'),
                                  contentPadding: EdgeInsets.zero,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                              const PopupMenuItem(
                                value: 'devices',
                                child: ListTile(
                                  leading: Icon(
                                    Icons.devices,
                                    color: Colors.white,
                                  ),
                                  title: Text('Devices'),
                                  contentPadding: EdgeInsets.zero,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                              const PopupMenuItem(
                                value: 'info',
                                child: ListTile(
                                  leading: Icon(
                                    Icons.info_outline,
                                    color: Colors.white,
                                  ),
                                  title: Text('Song Info'),
                                  contentPadding: EdgeInsets.zero,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                              PopupMenuItem(
                                value: 'sleep',
                                child: ListTile(
                                  leading: Icon(
                                    Icons.bedtime,
                                    color:
                                        widget
                                            .audioPlayerService
                                            .isSleepTimerActive
                                        ? const Color(0xFF00d4ff)
                                        : Colors.white,
                                  ),
                                  title: const Text('Sleep Timer'),
                                  contentPadding: EdgeInsets.zero,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                              if (widget.audioPlayerService.isCasting)
                                PopupMenuItem(
                                  value: 'black_screen',
                                  child: ListTile(
                                    leading: Icon(
                                      _blackScreenActive
                                          ? Icons.visibility_off
                                          : Icons.dark_mode,
                                      color: _blackScreenActive
                                          ? const Color(0xFF00d4ff)
                                          : Colors.white,
                                    ),
                                    title: Text(_blackScreenActive
                                        ? 'Screen On'
                                        : 'Screen Off'),
                                    contentPadding: EdgeInsets.zero,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ),
                              if (_isMobile)
                                PopupMenuItem(
                                  value: 'quality',
                                  child: ListTile(
                                    leading: Icon(
                                      Icons.high_quality,
                                      color: widget.audioPlayerService.qualityPreference != 'auto'
                                          ? const Color(0xFF00d4ff)
                                          : Colors.white,
                                    ),
                                    title: Text('Stream Quality (${widget.audioPlayerService.streamQuality})'),
                                    contentPadding: EdgeInsets.zero,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ),
                            ],
                          ),
                        ]
                      : [
                          IconButton(
                            icon: const Icon(Icons.info_outline),
                            tooltip: 'Song Info',
                            onPressed: () => _showSongStats(song),
                          ),
                          IconButton(
                            icon: const Icon(Icons.devices, size: 22),
                            tooltip: 'Devices',
                            onPressed: () {
                              showModalBottomSheet(
                                context: context,
                                backgroundColor: Colors.transparent,
                                isScrollControlled: true,
                                builder: (_) => DevicesSheet(
                                  audioPlayerService: widget.audioPlayerService,
                                ),
                              );
                            },
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.lyrics,
                              color: _showLyrics
                                  ? const Color(0xFF00d4ff)
                                  : Colors.white,
                            ),
                            tooltip: 'Lyrics',
                            onPressed: _toggleLyrics,
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.bedtime,
                              color:
                                  widget.audioPlayerService.isSleepTimerActive
                                  ? const Color(0xFF00d4ff)
                                  : Colors.white,
                            ),
                            tooltip: 'Sleep Timer',
                            onPressed: () => _showSleepTimerDialog(),
                          ),
                          IconButton(
                            icon: const Icon(Icons.queue_music),
                            tooltip: 'Queue',
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => QueueScreen(
                                    audioPlayerService:
                                        widget.audioPlayerService,
                                  ),
                                ),
                              );
                            },
                          ),
                          IconButton(
                            icon: Icon(
                              _isFullScreen
                                  ? Icons.fullscreen_exit
                                  : Icons.fullscreen,
                            ),
                            tooltip: _isFullScreen
                                ? 'Exit Fullscreen (F11)'
                                : 'Fullscreen (F11)',
                            onPressed: _toggleFullScreen,
                          ),
                        ],
                ),
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Blurred album art background
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 800),
                      child: Container(
                        key: ValueKey('bg_${song.id}'),
                        decoration: const BoxDecoration(
                          color: Color(0xFF0a0e27),
                        ),
                        child: CachedNetworkImage(
                          // Station-/podcast-aware: getArtworkUrl(albumId) 404s
                          // for stations & podcasts (albumId 0) → solid blue.
                          imageUrl: _artworkUrlForSong(song),
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: double.infinity,
                          placeholder: (context, url) => Container(
                            color: const Color(0xFF0a0e27),
                          ),
                          errorWidget: (context, url, error) => Container(
                            color: const Color(0xFF0a0e27),
                          ),
                        ),
                      ),
                    ),
                    // Dark overlay + blur
                    ClipRect(
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 80, sigmaY: 80),
                        child: Container(
                          color: const Color(0xFF0a0e27).withOpacity(0.65),
                        ),
                      ),
                    ),
                    // Actual content
                    _showLyrics
                        ? LyricsView(
                            audioPlayerService: widget.audioPlayerService,
                            songId: song.id,
                          )
                        : _isMobile
                        ? _buildMobileBody(
                            song,
                            artworkSize,
                            isPlaying,
                            position,
                            duration,
                          )
                        : _buildDesktopBody(
                            song,
                            artworkSize,
                            isPlaying,
                            position,
                            duration,
                          ),
                  ],
                ),
              ),
            ),
        ),
        blackScreenOverlay,
      ],
    );
  }

  void _navigateToPodcast() async {
    final player = widget.audioPlayerService;
    if (!player.isPlayingPodcast || player.podcastFeedId == 0) return;
    try {
      final feedData = await _apiService.getRssFeed(player.podcastFeedId);
      final feed = RssFeed.fromJson(feedData['feed']);
      if (mounted) {
        _pushBelowPlayer(MaterialPageRoute(
            builder: (context) => RssFeedDetailScreen(
              feed: feed,
              audioPlayerService: widget.audioPlayerService,
            ),
          ),
        );
      }
    } catch (e) {
      // Log to combined.log instead of swallowing into print().
      // Show a snackbar so the user knows the tap did something
      // and didn't just get ignored.
      AppLogger.instance.warning(
          'Failed to navigate to podcast feed ${player.podcastFeedId}: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text("Couldn't open podcast feed — try again."),
            backgroundColor: Colors.red.shade800,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  // ── B3: live-station now-playing display ──────────────────────────────
  // When the backend poll has a current track for the playing station,
  // promote it to the headline; otherwise everything falls back to the
  // station's own name/genre, so non-stations and data-less stations look
  // exactly as they did before.
  bool _stationHasLiveTrack(Song song) =>
      song.isStation &&
      (widget.audioPlayerService.stationTrackTitle?.isNotEmpty ?? false);

  String _nowPlayingTitle(Song song) => _stationHasLiveTrack(song)
      ? widget.audioPlayerService.stationTrackTitle!
      : song.title;

  // Secondary line (immersive layout): the broadcaster's artist for a live
  // track, or the station name when the artist is unknown.
  String _nowPlayingArtist(Song song) {
    if (_stationHasLiveTrack(song)) {
      final a = widget.audioPlayerService.stationTrackArtist;
      return (a != null && a.isNotEmpty) ? a : song.title;
    }
    return song.artistsFormatted;
  }

  // Secondary line (regular layout, which has no album row): fold the station
  // name in so it's not lost — "Artist • Station", or just the station name
  // when the artist is unknown.
  String _nowPlayingStationLine(Song song) {
    if (!_stationHasLiveTrack(song)) return song.artistsFormatted;
    final a = widget.audioPlayerService.stationTrackArtist;
    return (a != null && a.isNotEmpty) ? '$a • ${song.title}' : song.title;
  }

  String _artworkUrlForSong(Song song) {
    // Live stations carry their own artwork (favicon) — albumId is 0 and would
    // fall through to the default disc.
    if (song.isStation &&
        song.stationArtworkUrl != null &&
        song.stationArtworkUrl!.isNotEmpty) {
      return song.stationArtworkUrl!;
    }
    // For podcasts, use the podcast artwork URL instead of the album
    // art endpoint. Gate on `song.isPodcast` (the song's own type),
    // NOT the service's `isPlayingPodcast` — the service reflects
    // the currently-playing item, which drifts out of sync when
    // we're rendering prev/next swipeable tiles, a just-switched
    // track, or the queue sheet. Podcast album IDs are encoded as
    // -feedId and would fail `getArtworkUrl()` if we fell through.
    if (song.isPodcast) {
      final podcastUrl = widget.audioPlayerService.podcastArtworkUrl;
      if (podcastUrl != null) return podcastUrl;
      // Fallback is imperfect (podcasts don't map cleanly onto
      // the album-art endpoint) but at least avoids a null crash.
    }
    return _apiService.getArtworkUrl(song.albumId);
  }

  Widget _buildSwipeableArtwork(Song song, double artworkSize) {
    final queue = widget.audioPlayerService.queue;
    final currentIndex = widget.audioPlayerService.currentIndex;
    final hasPrev = currentIndex > 0;
    final hasNext = currentIndex < queue.length - 1;

    // Build the 3 pages: [previous, current, next]
    // If no prev/next, use the current song's art as placeholder (won't swipe there)
    final prevSong = hasPrev ? queue[currentIndex - 1] : song;
    final nextSong = hasNext ? queue[currentIndex + 1] : song;

    // Initialize or re-initialize the page controller at page 1 (center = current)
    if (_artworkPageController == null || !_artworkPageController!.hasClients) {
      _artworkPageController?.dispose();
      _artworkPageController = PageController(initialPage: 1);
      _artworkPageIndex = 1;
    }

    return SizedBox(
      height: artworkSize,
      child: PageView(
        controller: _artworkPageController!,
        // Only allow swiping in directions where there's a song
        physics: const BouncingScrollPhysics(),
        onPageChanged: (page) {
          if (_isAnimatingPage) return;
          _isAnimatingPage = true;

          if (page == 0 && hasPrev) {
            // Swiped to previous — always go to previous song (skip 3-second restart)
            widget.audioPlayerService.previous(force: true);
          } else if (page == 2 && hasNext) {
            // Swiped to next
            widget.audioPlayerService.next();
          } else {
            // Swiped to an edge with no song — bounce back
            _artworkPageController!.animateToPage(
              1,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }

          // _onPlayerStateChanged will reset to page 1 after song changes
          Future.delayed(const Duration(milliseconds: 400), () {
            _isAnimatingPage = false;
          });
        },
        children: [
          // Page 0: Previous song artwork
          GestureDetector(
            onTap: () => _showFullArtwork(prevSong.albumId),
            child: Center(
              child: _MobileArtwork(
                artworkUrl: _artworkUrlForSong(prevSong),
                size: artworkSize,
              ),
            ),
          ),
          // Page 1: Current song artwork
          GestureDetector(
            onTap: () => _showFullArtwork(song.albumId, artworkUrl: _artworkUrlForSong(song)),
            child: Center(
              child: _MobileArtwork(
                artworkUrl: _artworkUrlForSong(song),
                size: artworkSize,
              ),
            ),
          ),
          // Page 2: Next song artwork
          GestureDetector(
            onTap: () => _showFullArtwork(nextSong.albumId),
            child: Center(
              child: _MobileArtwork(
                artworkUrl: _artworkUrlForSong(nextSong),
                size: artworkSize,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileBody(
    Song song,
    double artworkSize,
    bool isPlaying,
    Duration position,
    Duration duration,
  ) {
    final topPadding = MediaQuery.of(context).padding.top + kToolbarHeight;
    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.only(left: 16, right: 16, top: topPadding + 8, bottom: 8),
        child: Column(
          children: [
            // Remote-control badge in-flow above the artwork (takes no space
            // when idle), so it never overlaps the album art.
            RemoteControlBadge(
              service: globalDeviceSyncService,
              onStopControl: () => globalDeviceSyncService.stopRemoteControl(),
            ),
            const SizedBox(height: 4),
            _buildSwipeableArtwork(song, artworkSize),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 280),
                      child: GestureDetector(
                        onTap: () => _openSongAlbum(song),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 500),
                          child: Row(
                            key: ValueKey(song.id),
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: MarqueeText(
                                  text: _nowPlayingTitle(song),
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              if (song.isExplicit) ...[
                                const SizedBox(width: 8),
                                const ExplicitBadge(fontSize: 10),
                              ],
                              if (song.isAtmos || song.isSurround) ...[
                                const SizedBox(width: 8),
                                SpatialBadge(song: song, fontSize: 10),
                              ],
                              if (song.isHdcd) ...[
                                const SizedBox(width: 8),
                                const HdcdBadge(fontSize: 10),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (!widget.audioPlayerService.isPlayingPodcast)
                  Positioned(
                    right: 0,
                    child: _buildFavoriteButton(song, 24),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _buildFormatBadge(song),
            const SizedBox(height: 8),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 500),
              child: Padding(
                key: ValueKey('${song.id}_artist'),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: GestureDetector(
                  onTap: () => _openSongArtist(song),
                  child: Text(
                    _nowPlayingStationLine(song),
                    style: TextStyle(
                      fontSize: 14,
                      color: Color(0xFF00d4ff),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Wrap waveform/chapter slider + time row in a single
            // ValueListenableBuilder — these are the visible scrubber
            // in the immersive fullscreen layout (the one simpson1045 was
            // using when it appeared "stuck"). Without the wrapper
            // they only updated when the screen rebuilt on song/play
            // state change, because the parent no longer rebuilds on
            // position events.
            if (!song.isStation) ValueListenableBuilder<Duration>(
              valueListenable: _interpolatedPositionNotifier,
              builder: (context, livePosition, _) {
                final cappedPosition =
                    livePosition.inMilliseconds > duration.inMilliseconds
                        ? duration
                        : livePosition;
                return Column(
                  children: [
                    if (_hasUsableWaveform && !widget.audioPlayerService.isPlayingPodcast)
                      WaveformProgressBar(
                        waveformData: _waveformData,
                        position: cappedPosition,
                        duration: duration,
                        onSeek: (newPosition) {
                          widget.audioPlayerService.seek(newPosition);
                        },
                        lightsaberMode: _isStarWarsTrack(song),
                        lightsaberColor: _isStarWarsTrack(song)
                            ? _getLightsaberColor(song)
                            : null,
                        dnaMode: _isJurassicParkTrack(song),
                        evhStripesMode: _isVanHalenTrack(song),
                      )
                    else
                      // Clean slider — orange for podcasts, blue for music. If
                      // the podcast has chapter data, tick marks show where each
                      // chapter starts. Skippable chapters (ads) get a red tick.
                      ChapteredSlider(
                        value: livePosition.inSeconds.toDouble(),
                        max: duration.inSeconds > 0 ? duration.inSeconds.toDouble() : 1,
                        onChanged: (v) => widget.audioPlayerService.seek(Duration(seconds: v.toInt())),
                        chapters: widget.audioPlayerService.isPlayingPodcast ? _chapters : const [],
                        activeTrackColor: widget.audioPlayerService.isPlayingPodcast
                            ? Colors.orange
                            : const Color(0xFF00d4ff),
                        inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
                        thumbColor: widget.audioPlayerService.isPlayingPodcast
                            ? Colors.orange
                            : const Color(0xFF00d4ff),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatDuration(cappedPosition),
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          Text(
                            _formatDuration(duration),
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
            if (_chapters.isNotEmpty) ...[
              const SizedBox(height: 8),
              _buildChaptersRow(),
            ],
            const SizedBox(height: 4),
            _buildMobileControls(isPlaying),
            const SizedBox(height: 8),
            _buildMobileSecondaryControls(),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopBody(
    Song song,
    double artworkSize,
    bool isPlaying,
    Duration position,
    Duration duration,
  ) {
    // Extra top padding to account for AppBar since body extends behind it
    final topPadding = MediaQuery.of(context).padding.top + kToolbarHeight;
    return Padding(
      padding: EdgeInsets.only(left: 20, right: 20, top: topPadding),
      child: Column(
        children: [
          // Remote-control badge in-flow at the top (no space when idle).
          RemoteControlBadge(
            service: globalDeviceSyncService,
            onStopControl: () => globalDeviceSyncService.stopRemoteControl(),
          ),
          if (widget.audioPlayerService.playingFromDisplay != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: GestureDetector(
                onTap: () => _navigateToSource(),
                child: Text(
                  'Playing from ${widget.audioPlayerService.playingFromDisplay}',
                  style: const TextStyle(
                    color: Color(0xFF00d4ff),
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          const Spacer(flex: 2),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            child: GestureDetector(
              key: ValueKey(song.albumId),
              onTap: () => _showFullArtwork(song.albumId, artworkUrl: _artworkUrlForSong(song)),
              child: _ArtworkWithHover(
                artworkUrl: _artworkUrlForSong(song),
                onTap: () => _showFullArtwork(song.albumId, artworkUrl: _artworkUrlForSong(song)),
                size: artworkSize,
              ),
            ),
          ),
          const Spacer(flex: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 500),
                    child: GestureDetector(
                      onTap: () => _openSongAlbum(song),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 500),
                        child: Row(
                          key: ValueKey(song.id),
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: MarqueeText(
                                text: _nowPlayingTitle(song),
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            if (song.isExplicit) ...[
                              const SizedBox(width: 8),
                              const ExplicitBadge(fontSize: 11),
                            ],
                            if (song.isAtmos || song.isSurround) ...[
                              const SizedBox(width: 8),
                              SpatialBadge(song: song, fontSize: 11),
                            ],
                            if (song.isHdcd) ...[
                              const SizedBox(width: 8),
                              const HdcdBadge(fontSize: 11),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (!song.isPodcast)
                  Positioned(
                    right: 0,
                    child: _buildFavoriteButton(song, 28),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Shared badge helper — LIVE pill for stations, quality/format pill
          // for music, hidden for podcasts. (Was a duplicated inline copy that
          // predated stations — same gotcha as the mobile body once had.)
          _buildFormatBadge(song),
          const SizedBox(height: 8),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            child: Padding(
              key: ValueKey('${song.id}_artist'),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                alignment: WrapAlignment.center,
                children: [
                  GestureDetector(
                    onTap: () => _openSongArtist(song),
                    child: Text(
                      _nowPlayingArtist(song),
                      style: const TextStyle(
                        fontSize: 16,
                        color: Color(0xFF00d4ff),
                      ),
                    ),
                  ),
                  const Text(
                    ' • ',
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                  GestureDetector(
                    onTap: () => _openSongAlbum(song),
                    child: Text(
                      _stationHasLiveTrack(song) ? song.title : song.albumTitle,
                      style: const TextStyle(
                        fontSize: 16,
                        color: Color(0xFF00d4ff),
                      ),
                    ),
                  ),
                  if (song.discNumber > 1)
                    Text(
                      _discNames.containsKey(song.discNumber)
                          ? ' • ${_discNames[song.discNumber]}'
                          : ' • Disc ${song.discNumber}',
                      style: const TextStyle(fontSize: 16, color: Colors.grey),
                    ),
                ],
              ),
            ),
          ),
          const Spacer(flex: 2),
          // Desktop fullscreen scrubber + time row. Same ValueListenable
          // pattern as the mobile immersive layout above — only this
          // subtree rebuilds on each position tick. Hidden for live
          // stations (no duration, not seekable) like the mobile body.
          if (!song.isStation) ValueListenableBuilder<Duration>(
            valueListenable: _interpolatedPositionNotifier,
            builder: (context, livePosition, _) {
              final cappedPosition =
                  livePosition.inMilliseconds > duration.inMilliseconds
                      ? duration
                      : livePosition;
              return Column(
                children: [
                  if (_hasUsableWaveform && !widget.audioPlayerService.isPlayingPodcast)
                    WaveformProgressBar(
                      waveformData: _waveformData,
                      position: cappedPosition,
                      duration: duration,
                      onSeek: (newPosition) {
                        widget.audioPlayerService.seek(newPosition);
                      },
                      lightsaberMode: _isStarWarsTrack(song),
                      lightsaberColor: _isStarWarsTrack(song)
                          ? _getLightsaberColor(song)
                          : null,
                      dnaMode: _isJurassicParkTrack(song),
                      evhStripesMode: _isVanHalenTrack(song),
                    )
                  else
                    ChapteredSlider(
                      value: livePosition.inSeconds.toDouble(),
                      max: duration.inSeconds > 0 ? duration.inSeconds.toDouble() : 1,
                      onChanged: (v) => widget.audioPlayerService.seek(Duration(seconds: v.toInt())),
                      chapters: widget.audioPlayerService.isPlayingPodcast ? _chapters : const [],
                      activeTrackColor: widget.audioPlayerService.isPlayingPodcast
                          ? Colors.orange
                          : const Color(0xFF00d4ff),
                      inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
                      thumbColor: widget.audioPlayerService.isPlayingPodcast
                          ? Colors.orange
                          : const Color(0xFF00d4ff),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatDuration(cappedPosition),
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        Text(
                          _formatDuration(duration),
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          if (_chapters.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildChaptersRow(),
          ],
          const Spacer(flex: 1),
          _buildPlaybackControls(isPlaying, widget.audioPlayerService.isBuffering),
          const SizedBox(height: 8),
          _buildSecondaryControls(),
          const Spacer(flex: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Row(
              children: [
                const Icon(Icons.volume_down, color: Colors.white70),
                Expanded(
                  child: Slider(
                    value: widget.audioPlayerService.getVolume(),
                    min: 0.0,
                    max: 1.0,
                    activeColor: const Color(0xFF00d4ff),
                    onChanged: (value) {
                      setState(() {
                        widget.audioPlayerService.setVolume(value);
                      });
                    },
                  ),
                ),
                const Icon(Icons.volume_up, color: Colors.white70),
              ],
            ),
          ),
          const Spacer(flex: 1),
        ],
      ),
    );
  }

  // Mobile: All controls in one row
  Widget _buildMobileControls(bool isPlaying) {
    final isPodcast = widget.audioPlayerService.isPlayingPodcast;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Shuffle / -10s rewind
        isPodcast
            ? IconButton(
                icon: const Icon(Icons.replay_10, color: Colors.white),
                iconSize: 32,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => _skipRelative(const Duration(seconds: -10)),
              )
            : IconButton(
                icon: Icon(
                  Icons.shuffle,
                  color: widget.audioPlayerService.isShuffled
                      ? const Color(0xFF00d4ff)
                      : Colors.white54,
                ),
                iconSize: 22,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => widget.audioPlayerService.toggleShuffle(),
              ),
        // Previous: queue-previous normally; previous-chapter for chaptered
        // podcasts. Still hidden for podcasts without chapters.
        if (!isPodcast || _podcastHasChapters)
          IconButton(
            icon: const Icon(Icons.skip_previous),
            iconSize: 36,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            tooltip: isPodcast ? 'Previous track' : null,
            onPressed: () {
              if (isPodcast) {
                _seekToPrevChapter();
              } else {
                widget.audioPlayerService.previous();
              }
            },
          ),
        // Play/Pause (or loading spinner when buffering)
        widget.audioPlayerService.isBuffering
            ? const SizedBox(
                width: 56,
                height: 56,
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: Colors.white,
                  ),
                ),
              )
            : IconButton(
                icon: Icon(isPlaying ? Icons.pause_circle : Icons.play_circle),
                iconSize: 56,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => widget.audioPlayerService.togglePlayPause(),
              ),
        // Next: queue-next normally; next-chapter for chaptered podcasts.
        if (!isPodcast || _podcastHasChapters)
          IconButton(
            icon: const Icon(Icons.skip_next),
            iconSize: 36,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            tooltip: isPodcast ? 'Next track' : null,
            onPressed: () {
              if (isPodcast) {
                _seekToNextChapter();
              } else {
                widget.audioPlayerService.next();
              }
            },
          ),
        // Repeat / +30s forward
        isPodcast
            ? IconButton(
                icon: const Icon(Icons.forward_30, color: Colors.white),
                iconSize: 32,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => _skipRelative(const Duration(seconds: 30)),
              )
            : IconButton(
                icon: Icon(
                  widget.audioPlayerService.repeatMode == RepeatMode.one
                      ? Icons.repeat_one
                      : Icons.repeat,
                  color: widget.audioPlayerService.repeatMode != RepeatMode.off
                      ? const Color(0xFF00d4ff)
                      : Colors.white54,
                ),
                iconSize: 22,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () =>
                    setState(() => widget.audioPlayerService.toggleRepeat()),
              ),
      ],
    );
  }

  // Mobile: Secondary controls (A-B loop, speed, lyrics, queue)
  Widget _buildMobileSecondaryControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // A-B Loop
        TextButton(
          onPressed: () =>
              setState(() => widget.audioPlayerService.toggleLoop()),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            widget.audioPlayerService.loopPointA == null
                ? 'A-B'
                : widget.audioPlayerService.loopPointB == null
                ? 'A •'
                : 'A • B',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: widget.audioPlayerService.loopPointA != null
                  ? const Color(0xFF00d4ff)
                  : Colors.white54,
            ),
          ),
        ),
        // Playback Speed
        TextButton(
          onPressed: () => _showSpeedDialog(),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            '${widget.audioPlayerService.playbackSpeed}x',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: widget.audioPlayerService.playbackSpeed != 1.0
                  ? const Color(0xFF00d4ff)
                  : Colors.white54,
            ),
          ),
        ),
        // Lyrics (hidden for podcasts)
        if (!widget.audioPlayerService.isPlayingPodcast)
        IconButton(
          icon: Icon(
            Icons.lyrics,
            color: _showLyrics ? const Color(0xFF00d4ff) : Colors.white54,
          ),
          iconSize: 22,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: _toggleLyrics,
        ),
        // Sleep timer (promoted for podcasts — long episodes are the
        // primary use case; hidden behind the three-dot menu for music).
        if (widget.audioPlayerService.isPlayingPodcast)
          IconButton(
            icon: Icon(
              Icons.bedtime,
              color: widget.audioPlayerService.isSleepTimerActive
                  ? const Color(0xFF00d4ff)
                  : Colors.white54,
            ),
            iconSize: 22,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            tooltip: 'Sleep timer',
            onPressed: () => _showSleepTimerDialog(),
          ),
        // Queue
        IconButton(
          icon: const Icon(Icons.queue_music, color: Colors.white54),
          iconSize: 22,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) =>
                    QueueScreen(audioPlayerService: widget.audioPlayerService),
              ),
            );
          },
        ),
      ],
    );
  }

  // Desktop: Main playback controls only
  Widget _buildPlaybackControls(bool isPlaying, bool isBuffering) {
    final isPodcast = widget.audioPlayerService.isPlayingPodcast;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Previous chapter (album-style track nav) for chaptered podcasts.
        if (_podcastHasChapters)
          IconButton(
            icon: const Icon(Icons.skip_previous, color: Colors.white),
            iconSize: 40,
            tooltip: 'Previous track',
            onPressed: _seekToPrevChapter,
          ),
        if (isPodcast)
          IconButton(
            icon: const Icon(Icons.replay_10, color: Colors.white),
            iconSize: 40,
            onPressed: () => _skipRelative(const Duration(seconds: -10)),
          )
        else
          IconButton(
            icon: const Icon(Icons.skip_previous),
            iconSize: 48,
            onPressed: () => widget.audioPlayerService.previous(),
          ),
        const SizedBox(width: 20),
        isBuffering
            ? const SizedBox(
                width: 64,
                height: 64,
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: Colors.white,
                  ),
                ),
              )
            : IconButton(
                icon: Icon(
                    isPlaying ? Icons.pause_circle : Icons.play_circle),
                iconSize: 64,
                onPressed: () =>
                    widget.audioPlayerService.togglePlayPause(),
              ),
        const SizedBox(width: 20),
        if (isPodcast)
          IconButton(
            icon: const Icon(Icons.forward_30, color: Colors.white),
            iconSize: 40,
            onPressed: () => _skipRelative(const Duration(seconds: 30)),
          )
        else
          IconButton(
            icon: const Icon(Icons.skip_next),
            iconSize: 48,
            onPressed: () => widget.audioPlayerService.next(),
          ),
        // Next chapter (album-style track nav) for chaptered podcasts.
        if (_podcastHasChapters)
          IconButton(
            icon: const Icon(Icons.skip_next, color: Colors.white),
            iconSize: 40,
            tooltip: 'Next track',
            onPressed: _seekToNextChapter,
          ),
      ],
    );
  }

  Widget _buildSecondaryControls() {
    final isPodcast = widget.audioPlayerService.isPlayingPodcast;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: _isMobile ? 4 : 10,
      children: [
        if (!isPodcast)
          IconButton(
            icon: Icon(
              Icons.shuffle,
              color: widget.audioPlayerService.isShuffled
                  ? const Color(0xFF00d4ff)
                  : Colors.white54,
            ),
            iconSize: _isMobile ? 24 : 32,
            onPressed: () async {
              await widget.audioPlayerService.toggleShuffle();
              setState(() {});
            },
          ),
        if (!isPodcast)
          IconButton(
            icon: Icon(
              widget.audioPlayerService.repeatMode == RepeatMode.one
                  ? Icons.repeat_one
                  : Icons.repeat,
              color: widget.audioPlayerService.repeatMode != RepeatMode.off
                  ? const Color(0xFF00d4ff)
                  : Colors.white54,
            ),
            iconSize: _isMobile ? 24 : 32,
            onPressed: () {
              widget.audioPlayerService.toggleRepeat();
              setState(() {});
            },
          ),
        // Loop the current track (chapter) — one tap sets the A-B loop to the
        // active chapter's bounds. Only for chaptered podcasts.
        if (_podcastHasChapters)
          IconButton(
            icon: Icon(
              Icons.repeat_one,
              color: _isLoopingActiveChapter()
                  ? const Color(0xFF00d4ff)
                  : Colors.white54,
            ),
            iconSize: _isMobile ? 24 : 32,
            tooltip: 'Loop this track',
            onPressed: _toggleChapterLoop,
          ),
        IconButton(
          icon: Text(
            widget.audioPlayerService.loopPointA == null
                ? 'A'
                : widget.audioPlayerService.loopPointB == null
                ? 'A•'
                : 'A•B',
            style: TextStyle(
              fontSize: _isMobile ? 12 : 16,
              fontWeight: FontWeight.bold,
              color: widget.audioPlayerService.loopPointA != null
                  ? const Color(0xFF00d4ff)
                  : Colors.white54,
            ),
          ),
          onPressed: () =>
              setState(() => widget.audioPlayerService.toggleLoop()),
        ),
        IconButton(
          icon: Text(
            '${widget.audioPlayerService.playbackSpeed}x',
            style: TextStyle(
              fontSize: _isMobile ? 11 : 14,
              fontWeight: FontWeight.bold,
              color: widget.audioPlayerService.playbackSpeed != 1.0
                  ? const Color(0xFF00d4ff)
                  : Colors.white54,
            ),
          ),
          onPressed: () => _showSpeedDialog(),
        ),
      ],
    );
  }

  void _showQualityDialog() {
    final options = [
      ('auto', 'Auto', 'Lossless on WiFi, AAC 320k on cellular'),
      ('lossless', 'Lossless', 'Original file (FLAC/WAV)'),
      ('high', 'High', 'AAC 320kbps'),
      ('medium', 'Medium', 'AAC 128kbps'),
      ('low', 'Low', 'MP3 96kbps'),
    ];

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF0d1b2a),
          title: const Text('Stream Quality', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: options.map((opt) {
              final isSelected = widget.audioPlayerService.qualityPreference == opt.$1;
              return ListTile(
                leading: Icon(
                  isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  color: isSelected ? const Color(0xFF00d4ff) : Colors.grey,
                ),
                title: Text(opt.$2, style: TextStyle(
                  color: isSelected ? const Color(0xFF00d4ff) : Colors.white,
                )),
                subtitle: Text(opt.$3, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                onTap: () {
                  widget.audioPlayerService.setQualityPreference(opt.$1);
                  setDialogState(() {});
                  setState(() {});
                },
              );
            }).toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done', style: TextStyle(color: Color(0xFF00d4ff))),
            ),
          ],
        ),
      ),
    );
  }

  void _showSleepTimerDialog() {
    final isActive = widget.audioPlayerService.isSleepTimerActive;
    final remaining = widget.audioPlayerService.sleepTimeRemaining;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: Row(
          children: [
            const Icon(Icons.bedtime, color: Color(0xFF00d4ff)),
            const SizedBox(width: 12),
            Text(isActive ? 'Sleep Timer Active' : 'Sleep Timer'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isActive) ...[
              Text(
                '${remaining.inMinutes}:${(remaining.inSeconds % 60).toString().padLeft(2, '0')}',
                style: const TextStyle(
                  fontSize: 48,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF00d4ff),
                ),
              ),
              const SizedBox(height: 8),
              const Text('remaining', style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                  ),
                  onPressed: () {
                    widget.audioPlayerService.cancelSleepTimer();
                    Navigator.pop(context);
                    setState(() {});
                  },
                  child: const Text('Cancel Timer'),
                ),
              ),
            ] else ...[
              const Text(
                'Stop playing after:',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              _buildTimerOption(
                context,
                '15 minutes',
                const Duration(minutes: 15),
              ),
              _buildTimerOption(
                context,
                '30 minutes',
                const Duration(minutes: 30),
              ),
              _buildTimerOption(
                context,
                '45 minutes',
                const Duration(minutes: 45),
              ),
              _buildTimerOption(context, '1 hour', const Duration(hours: 1)),
              _buildTimerOption(
                context,
                '1.5 hours',
                const Duration(minutes: 90),
              ),
              _buildTimerOption(context, '2 hours', const Duration(hours: 2)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<List<int>> _getPlaylistAlbumIds(int playlistId) async {
    if (_playlistAlbumCache.containsKey(playlistId)) {
      return _playlistAlbumCache[playlistId]!;
    }
    try {
      final data = await _apiService.getPlaylist(playlistId);
      final songs = data['songs'] as List;
      final albumIds = <int>[];
      final seen = <int>{};
      for (final song in songs) {
        final albumId = song['album_id'] as int;
        if (!seen.contains(albumId)) {
          seen.add(albumId);
          albumIds.add(albumId);
          if (albumIds.length >= 4) break;
        }
      }
      _playlistAlbumCache[playlistId] = albumIds;
      return albumIds;
    } catch (e) {
      return [];
    }
  }

  void _showAddToPlaylistDialog(Song song) async {
    try {
      final playlists = await _apiService.getPlaylists();
      if (!mounted) return;

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1a2332),
          title: const Row(
            children: [
              Icon(Icons.playlist_add, color: Color(0xFF00d4ff)),
              SizedBox(width: 12),
              Text('Add to Playlist'),
            ],
          ),
          content: playlists.isEmpty
              ? const Text('No playlists yet. Create one first!')
              : SizedBox(
                  width: double.maxFinite,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: playlists.length,
                    itemBuilder: (context, index) {
                      final playlist = playlists[index];
                      return ListTile(
                        leading: FutureBuilder<List<int>>(
                          future: _getPlaylistAlbumIds(playlist.id),
                          builder: (context, snapshot) {
                            const size = 45.0;
                            if (!snapshot.hasData || snapshot.data == null || snapshot.data!.isEmpty) {
                              return Container(
                                width: size,
                                height: size,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1a2332),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Icon(Icons.playlist_play, color: Color(0xFF00d4ff), size: 28),
                              );
                            }
                            final albumIds = snapshot.data!;
                            if (albumIds.length < 4) {
                              return ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: CachedNetworkImage(
                                  imageUrl: _apiService.getArtworkUrl(albumIds.first),
                                  width: size,
                                  height: size,
                                  fit: BoxFit.cover,
                                  placeholder: (context, url) => Container(width: size, height: size, color: const Color(0xFF1a2332)),
                                  errorWidget: (context, url, error) => Container(
                                    width: size, height: size, color: const Color(0xFF1a2332),
                                    child: const Icon(Icons.playlist_play, color: Color(0xFF00d4ff), size: 28),
                                  ),
                                ),
                              );
                            }
                            return ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: SizedBox(
                                width: size,
                                height: size,
                                child: GridView.count(
                                  crossAxisCount: 2,
                                  physics: const NeverScrollableScrollPhysics(),
                                  children: albumIds.take(4).map((albumId) {
                                    return CachedNetworkImage(
                                      imageUrl: _apiService.getArtworkUrl(albumId),
                                      fit: BoxFit.cover,
                                      placeholder: (context, url) => Container(color: const Color(0xFF1a2332)),
                                      errorWidget: (context, url, error) => Container(color: const Color(0xFF1a2332)),
                                    );
                                  }).toList(),
                                ),
                              ),
                            );
                          },
                        ),
                        title: Text(playlist.name),
                        subtitle: Text(
                          '${playlist.songCount} songs',
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 12,
                          ),
                        ),
                        onTap: () async {
                          Navigator.pop(context);
                          try {
                            await _apiService.addSongToPlaylist(
                              playlist.id,
                              song.id,
                            );
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Added to ${playlist.name}'),
                                  backgroundColor: const Color(0xFF1a2332),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            }
                          } catch (e) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Failed to add: $e'),
                                  backgroundColor: Colors.red.shade700,
                                ),
                              );
                            }
                          }
                        },
                      );
                    },
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
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load playlists: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    }
  }

  Widget _buildTimerOption(
    BuildContext context,
    String label,
    Duration duration,
  ) {
    void activate() {
      widget.audioPlayerService.startSleepTimer(duration);
      Navigator.pop(context);
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Sleep timer set for $label'),
          backgroundColor: const Color(0xFF1a2332),
          duration: const Duration(seconds: 2),
        ),
      );
    }

    return GestureDetector(
      onTap: activate,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                ),
              ),
            ),
            const Icon(
              Icons.arrow_forward_ios,
              size: 16,
              color: Colors.grey,
            ),
          ],
        ),
      ),
    );
  }

  void _showSpeedDialog() {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1a2332),
          title: const Row(
            children: [
              Icon(Icons.speed, color: Color(0xFF00d4ff)),
              SizedBox(width: 12),
              Text('Playback Speed'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Vinyl Mode toggle
              SwitchListTile(
                title: const Text('Vinyl Mode'),
                subtitle: Text(
                  'Pitch changes with speed',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
                value: !widget.audioPlayerService.pitchCorrectionEnabled,
                activeThumbColor: const Color(0xFF00d4ff),
                onChanged: (value) {
                  widget.audioPlayerService.setPitchCorrectionEnabled(!value);
                  setDialogState(() {});
                  setState(() {});
                },
              ),
              const Divider(color: Colors.grey),
              const SizedBox(height: 16),
              // Speed display
              Text(
                '${widget.audioPlayerService.playbackSpeed.toStringAsFixed(2)}x',
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF00d4ff),
                ),
              ),
              const SizedBox(height: 8),
              // Speed slider
              Slider(
                value: widget.audioPlayerService.playbackSpeed,
                min: 0.5,
                max: 2.0,
                divisions: 30, // 0.05 increments
                activeColor: const Color(0xFF00d4ff),
                onChanged: (value) {
                  widget.audioPlayerService.setPlaybackSpeed(value);
                  setDialogState(() {});
                  setState(() {});
                },
              ),
              // Labels
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '0.5x',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    Text(
                      '1.0x',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    Text(
                      '1.5x',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    Text(
                      '2.0x',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Reset button
              TextButton(
                onPressed: () {
                  widget.audioPlayerService.setPlaybackSpeed(1.0);
                  setDialogState(() {});
                  setState(() {});
                },
                child: const Text('Reset to 1.0x'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  void _showSongStats(Song song) async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Row(
          children: [
            Icon(Icons.info_outline, color: Color(0xFF00d4ff)),
            SizedBox(width: 12),
            Expanded(child: Text('Song Info')),
          ],
        ),
        content: FutureBuilder<Map<String, dynamic>>(
          future: _apiService.getSongStats(song.id),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                height: 200,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) return Text('Error: ${snapshot.error}');
            if (!snapshot.hasData || snapshot.data == null) {
              return const SizedBox(
                height: 200,
                child: Center(child: Text('No stats available', style: TextStyle(color: Colors.grey))),
              );
            }

            final stats = snapshot.data!;
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildStatRow('Title', stats['title']),
                  _buildStatRow('Artist', stats['artist_name']),
                  _buildStatRow('Album', stats['album_title']),
                  _buildStatRow(
                    'Track',
                    'Disc ${stats['disc_number']}, Track ${stats['track_number']}',
                  ),
                  const Divider(color: Colors.grey),
                  _buildStatRow('Play Count', '${stats['play_count']} plays'),
                  _buildStatRow(
                    'Last Played',
                    _formatDateTime(stats['last_played']),
                  ),
                  _buildStatRow(
                    'First Played',
                    _formatDateTime(stats['first_played']),
                  ),
                  const Divider(color: Colors.grey),
                  _buildStatRow('Format', song.fileFormat),
                  _buildStatRow('Duration', song.durationFormatted),
                  _buildStatRow(
                    'File Size',
                    _formatFileSize(stats['file_size']),
                  ),
                  _buildStatRow('Bitrate', '${stats['bitrate']} kbps'),
                  _buildStatRow('Added', _formatDateTime(stats['created_at'])),
                  const Divider(color: Colors.grey),
                  const Text(
                    'File Path',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    stats['file_path'] ?? 'Unknown',
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  String _formatDateTime(String? dateStr) {
    if (dateStr == null) return 'Never';
    try {
      final date = DateTime.parse(dateStr);
      final now = DateTime.now();
      final diff = now.difference(date);
      if (diff.inDays == 0) {
        return 'Today at ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
      }
      if (diff.inDays == 1) return 'Yesterday';
      if (diff.inDays < 7) return '${diff.inDays} days ago';
      return '${date.month}/${date.day}/${date.year}';
    } catch (e) {
      return dateStr;
    }
  }

  String _formatFileSize(int? bytes) {
    if (bytes == null || bytes == 0) return 'Unknown';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  void _showFullArtwork(int albumId, {String? artworkUrl}) {
    final screenSize = MediaQuery.of(context).size;
    final maxSize = _isMobile
        ? screenSize.width * 0.9
        : screenSize.height * 0.75;
    // Cap the in-memory decoded bitmap size at the actual rendered pixel
    // dimensions (logical size × device pixel ratio). Without this,
    // Flutter decodes the source image at whatever resolution it is —
    // FLAC-embedded artwork is often 2000×2000+, which means ~16MB of
    // RGBA decoded synchronously on the UI thread when this dialog
    // opens. The result is a multi-second UI freeze that looks like a
    // crash but doesn't actually throw, so the crash handlers never
    // fire (which is why nasradio_crash.log was empty after the
    // 2026-05-25 "tapped artwork and the app crashed" report).
    // _MobileArtwork already does this for the small in-grid tiles;
    // this fullscreen path was missed because of the assumption that
    // desktop had spare resources for a single full-res decode.
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cachePx = (maxSize * dpr).ceil();

    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(20),
          child: Stack(
            alignment: Alignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: CachedNetworkImage(
                  imageUrl: artworkUrl ??
                      (widget.audioPlayerService.isPlayingPodcast && widget.audioPlayerService.podcastArtworkUrl != null
                          ? widget.audioPlayerService.podcastArtworkUrl!
                          : _apiService.getArtworkUrl(albumId)),
                  width: maxSize,
                  height: maxSize,
                  memCacheWidth: cachePx,
                  memCacheHeight: cachePx,
                  fit: BoxFit.cover,
                  placeholder: (context, url) => Container(
                    width: 300,
                    height: 300,
                    color: const Color(0xFF1a2332),
                  ),
                  errorWidget: (context, url, error) => Container(
                    width: 300,
                    height: 300,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1a2332),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.album,
                      size: 150,
                      color: Color(0xFF00d4ff),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  icon: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Icon(Icons.close, color: Colors.white),
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Simple mobile artwork without hover effects
class _MobileArtwork extends StatelessWidget {
  final String artworkUrl;
  final double size;

  const _MobileArtwork({
    super.key,
    required this.artworkUrl,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    // Mobile only — cap the decoded bitmap size at the rendered
    // pixel size (logical size × device pixel ratio). Without this,
    // Flutter decodes whatever the source resolution is (often
    // 2000×2000 FLAC embedded artwork), holding ~16 MB in memory
    // for a 280 dp tile. Desktop + cast use separate widgets /
    // paths and still get full resolution by design (TV looks
    // great on the blurred background, cast receiver pulls art
    // straight from the backend URL, neither goes through this
    // widget).
    final pixelSize = (size * MediaQuery.of(context).devicePixelRatio).ceil();
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 15),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.network(
          artworkUrl,
          width: size,
          height: size,
          cacheWidth: pixelSize,
          cacheHeight: pixelSize,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.high,
          errorBuilder: (context, error, stackTrace) {
            return Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: const Color(0xFF1a2332),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.album,
                size: size * 0.5,
                color: const Color(0xFF00d4ff),
              ),
            );
          },
        ),
      ),
    );
  }
}

// Desktop artwork with hover effect
class _ArtworkWithHover extends StatefulWidget {
  final String artworkUrl;
  final VoidCallback onTap;
  final double size;

  const _ArtworkWithHover({
    required this.artworkUrl,
    required this.onTap,
    this.size = 300,
  });

  @override
  State<_ArtworkWithHover> createState() => _ArtworkWithHoverState();
}

class _ArtworkWithHoverState extends State<_ArtworkWithHover> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          transform: Matrix4.identity()..scale(_isHovered ? 1.03 : 1.0),
          transformAlignment: Alignment.center,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: _isHovered
                      ? const Color(0xFF00d4ff).withOpacity(0.4)
                      : Colors.black.withOpacity(0.3),
                  blurRadius: _isHovered ? 30 : 15,
                  spreadRadius: _isHovered ? 5 : 0,
                ),
              ],
            ),
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    widget.artworkUrl,
                    width: widget.size,
                    height: widget.size,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        width: widget.size,
                        height: widget.size,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1a2332),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.album,
                          size: 150,
                          color: Color(0xFF00d4ff),
                        ),
                      );
                    },
                  ),
                ),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _isHovered ? 1.0 : 0.0,
                  child: Container(
                    width: widget.size,
                    height: widget.size,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: Colors.black.withOpacity(0.3),
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.fullscreen,
                        color: Colors.white,
                        size: 48,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

}
