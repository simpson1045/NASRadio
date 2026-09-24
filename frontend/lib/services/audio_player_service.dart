import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'app_logger.dart';
import 'dart:math' show pi, cos, sin, pow;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'playback_engine.dart';
import 'playback_engine_mediakit.dart';
import 'playback_engine_just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/song.dart';
import '../models/rss_feed.dart';
import 'api_service.dart';
import 'cast_service.dart';
import 'widget_service.dart';
import 'windows_wakelock.dart';
import 'package:flutter/foundation.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:audio_session/audio_session.dart';

enum RepeatMode { off, one, all }

class AudioPlayerService extends ChangeNotifier {
  // Chromecast integration
  CastService? _castService;
  set castService(CastService service) {
    _castService = service;
    service.addListener(_onCastStateChanged);
  }
  bool get isCasting => _castService?.isConnected ?? false;

  /// True when the cast owns (or is about to own) audio: connected, OR a
  /// startup rejoin is still in flight. Automatic playback paths must
  /// check THIS, not isCasting — during the first seconds after launch
  /// isCasting is false while the rejoin runs, and that window is where
  /// the app-open hiss lived.
  bool get _castOwnsAudio =>
      isCasting || (_castService?.resumePending ?? false);
  CastService get castServiceInstance => _castService!;

  // Device sync service for multi-device support
  dynamic _syncService;
  set syncService(dynamic service) => _syncService = service;

  /// True while this device is remote-controlling another instance. When set,
  /// the state getters below mirror the TARGET (so the real Now Playing screen
  /// shows what the target is doing) and the playback methods route to remote
  /// commands instead of local playback — exactly parallel to `isCasting`. The
  /// private _-fields stay local, so persistence/restore are unaffected.
  bool get isControlling => _syncService?.isController ?? false;

  // Screen-level remote commands. Lyrics / black-screen target the now-playing
  // SCREEN state, not the audio service, so the now-playing screen registers
  // these and executeRemoteCommand fires them when a controller sends
  // toggle_lyrics / toggle_black_screen to this (target) device.
  void Function()? onRemoteLyricsToggle;
  void Function()? onRemoteBlackScreenToggle;

  // Tracks the previous cast-connection state so we can detect the
  // disconnect EDGE (drop or TV-side kill — the phone-side disconnect
  // button goes through stopCasting instead and doesn't need this).
  bool _wasCastConnected = false;

  // Joined-cast bookkeeping: the receiver's songId we're currently
  // fetching/adopting (dedupes the async fetch), and the phone's own queue
  // parked while joined so "take over" can bring it back.
  int? _adoptingRemoteId;
  List<Song>? _preJoinQueue;
  int _preJoinIndex = 0;

  void _onCastStateChanged() {
    // Joined someone else's cast: follow whatever the receiver is on.
    if (isCasting && _castService!.joinedExisting) {
      final rx = _castService!.receiverSongId;
      if (rx != null && rx != _currentSong?.id && rx != _adoptingRemoteId) {
        _adoptingRemoteId = rx;
        adoptRemoteSong(rx);
      }
    }
    // Sync cast state back to UI — isPlaying, position, etc.
    if (!isCasting && _wasCastConnected) {
      // Cast ended WITHOUT the user pressing our disconnect button
      // (unexpected drop, or the TV remote killed the receiver). Nothing
      // is audible anymore — reflect that instead of leaving the UI
      // showing a phantom "playing" state. Local engine stays untouched:
      // a drop may auto-reconnect and resume on the TV; pressing play
      // meanwhile starts local playback at the cast's last position.
      _wasCastConnected = false;
      _isPlaying = false;
      notifyListeners();
      return;
    }
    if (isCasting) {
      if (!_wasCastConnected && _hasLoadedCurrent) {
        // Cast (re)connected — the TV owns audio now. HARD-stop the
        // local engine: a play command landing in a drop window can
        // leave it rendering (the 2026-08-13 incident: phone hissing
        // static while every UI control routed to the cast — an
        // orphaned player with no reachable stop button).
        _active.stop();
        _hasLoadedCurrent = false;
        AppLogger.instance.info(
            '📺 [Cast] Connected — local engine force-stopped');
      }
      _wasCastConnected = true;
      _isPlaying = _castService!.isPlaying;
      // Only sync position FROM cast when cast actually has media
      // loaded. A freshly-connected cast session reports position=0
      // with no media yet — letting that clobber `_position` would
      // wipe out the position we might want to resume from (e.g. the
      // previous cast session's last known position if a cast drop
      // triggered a reconnect). Heuristic: cast has media when its
      // duration is non-zero. Once LOAD has been processed by the
      // receiver and a MEDIA_STATUS comes back with media, duration
      // is populated and this gate opens.
      if (_castService!.duration.inSeconds > 0) {
        _position = _castService!.position;
        _duration = _castService!.duration;
      }
    }
    notifyListeners();
  }

  /// Called when Chromecast connects — pause local, send current song to TV
  Future<void> startCasting() async {
    if (!isCasting) return;
    if (_currentSong == null) return;

    // Take the max of the engine's position and the cached _position — if
    // local was never actually played (e.g. casting reconnect right after a
    // restore), the engine reports Duration.zero, so we want to fall back to
    // the cached value as the resume point.
    final localPos = _hasLoadedCurrent ? _active.position : Duration.zero;
    final resumePosition = localPos.inMilliseconds >= _position.inMilliseconds
        ? localPos
        : _position;
    AppLogger.instance.info(
      '📺 [Cast] startCasting song="${_currentSong!.title}" '
      'resume=${resumePosition.inMilliseconds}ms '
      'localPos=${localPos.inMilliseconds}ms '
      'cachedPos=${_position.inMilliseconds}ms '
      'isPlayingPodcast=$isPlayingPodcast',
    );
    if (_hasLoadedCurrent) {
      // STOP, not pause: a paused-but-loaded deck is a parked decoder
      // that Android can squawk through, and a drop-window play() turns
      // it into an orphaned noise source. Disconnect reloads the deck
      // from scratch anyway (stopCasting → _playCurrentIndex), so
      // releasing here costs nothing.
      await _active.stop();
      _hasLoadedCurrent = false;
    }
    await _castService!.loadAndPlay(_currentSong!,
        quality: _streamQuality,
        startPosition: resumePosition,
        podcastArtworkUrl: _podcastArtworkUrl);

    // Casting a station whose current track we already know? The poll only
    // pushes NOW_PLAYING on a track CHANGE, so without this the TV shows
    // the static station name until the broadcast rotates (minutes).
    // Deferred 3s so the receiver is done processing the LOAD — same
    // reasoning as the deferred badge/waveform send in cast_service.
    if (_currentSong!.isStation && _stationTrackTitle != null) {
      Future.delayed(const Duration(seconds: 3), () {
        if (isCasting &&
            _currentSong?.isStation == true &&
            _stationTrackTitle != null) {
          _castService?.updateStationNowPlaying(displayTitle, displayArtist,
              artworkUrl: _stationTrackArtwork);
        }
      });
    }

    // Party already running when the cast started? Put the QR on the TV.
    if (_partyActive && _partyQrUrl != null) {
      Future.delayed(const Duration(seconds: 3), () {
        if (isCasting && _partyActive) {
          _castService?.sendPartyMode(
              active: true, qrUrl: _partyQrUrl, code: _partyCode);
        }
      });
    }
  }

  /// Called when Chromecast disconnects — re-sync local engine to whatever
  /// song/position the cast session left off at. During casting,
  /// next/previous mutated _currentSong/_currentIndex/_position without
  /// touching the local deck.
  ///
  /// [resumeLocal]: true when the USER disconnected from the phone (cast
  /// button) — simpson1045's rule: phone-side disconnect should hand playback
  /// straight back to the phone, playing, from where the TV left off.
  /// False (default) keeps the old paused-reload for programmatic callers.
  void stopCasting({bool resumeLocal = false}) {
    _isPlaying = false;
    _wasCastConnected = false;
    _cancelCrossfade();
    if (_queue.isNotEmpty && _currentSong != null) {
      print('📺 [Cast] Disconnect: reloading local engine at index $_currentIndex '
          '(${_currentSong?.title}) resumeLocal=$resumeLocal');
      _playCurrentIndex(autoPlay: resumeLocal, startPosition: _position);
    }
    savePlaybackState();
    notifyListeners();
  }

  /// Next music tracks for the receiver's UP_NEXT self-advance list.
  /// Stops at the first station/podcast — those never self-advance.
  List<Song> get upcomingCastQueue {
    if (_queue.isEmpty || _currentIndex < 0) return const [];
    final start = _currentIndex + 1;
    if (start >= _queue.length) return const [];
    return _queue
        .sublist(start)
        .takeWhile((s) => !s.isStation && !s.isPodcast)
        .take(10)
        .toList();
  }

  /// Joined a cast we didn't start (e.g. Claude's headless cast). The
  /// song isn't in our queue, so fetch it and show it as the current
  /// track; transport controls then steer the receiver. The phone's own
  /// queue is parked for takeOverCast().
  Future<void> adoptRemoteSong(int songId) async {
    try {
      final song = await _apiService.getSongById(songId);
      if (!isCasting || !(_castService?.joinedExisting ?? false)) return;
      _preJoinQueue ??= List<Song>.from(_queue);
      if (_preJoinQueue!.isNotEmpty && _preJoinQueue!.length == _queue.length) {
        _preJoinIndex = _currentIndex;
      }
      _queue = [song];
      _currentIndex = 0;
      _currentSong = song;
      _position = _castService?.position ?? Duration.zero;
      _duration = _castService?.duration ?? Duration(seconds: song.duration);
      _isPlaying = _castService?.isPlaying ?? true;
      AppLogger.instance.info(
          '📺 [Cast] Following joined cast: "${song.title}" (id=$songId)');
      notifyListeners();
    } catch (e) {
      AppLogger.instance.warning(
          '📺 [Cast] adoptRemoteSong($songId) failed: $e');
    } finally {
      if (_adoptingRemoteId == songId) _adoptingRemoteId = null;
    }
  }

  /// Leave a joined cast: the TV keeps playing, the phone goes quiet.
  void leaveJoinedCast() {
    _castService?.disconnect(); // no STOP while joined
    _isPlaying = false;
    _wasCastConnected = false;
    _restorePreJoinQueue();
    savePlaybackState();
    notifyListeners();
  }

  /// Replace the joined cast with the phone's own queue: the phone becomes
  /// the sender again and LOADs what it had before joining.
  Future<void> takeOverCast() async {
    _castService?.takeOver();
    _restorePreJoinQueue();
    await startCasting();
  }

  void _restorePreJoinQueue() {
    final parked = _preJoinQueue;
    _preJoinQueue = null;
    if (parked == null || parked.isEmpty) return;
    _queue = parked;
    _currentIndex = _preJoinIndex.clamp(0, _queue.length - 1);
    _currentSong = _queue[_currentIndex];
    _position = Duration.zero;
  }

  /// Sync the app to the song the RECEIVER is on. With UP_NEXT the TV
  /// can self-advance through the queue while the app is closed or off
  /// the network — on rejoin/reconnect we follow the TV instead of
  /// yanking it back to where WE last were.
  void adoptCastSong(int songId) {
    final idx = _queue.indexWhere((s) => s.id == songId);
    if (idx < 0) {
      AppLogger.instance.warning(
          '📺 [Cast] adoptCastSong: song $songId not in local queue — ignoring');
      return;
    }
    _currentIndex = idx;
    _currentSong = _queue[idx];
    _position = _castService?.position ?? _position;
    _duration = _castService?.duration ?? _duration;
    _isPlaying = _castService?.isPlaying ?? _isPlaying;
    AppLogger.instance.info(
        '📺 [Cast] Adopted receiver song "${_currentSong!.title}" '
        '(id=$songId, queue idx=$idx, pos=${_position.inSeconds}s)');
    savePlaybackState();
    notifyListeners();
  }

  // Platform detection - use just_audio on Android/iOS, media_kit on desktop
  bool get _useJustAudio => Platform.isAndroid || Platform.isIOS;

  // ===================================================================
  // PLAYBACK-ENGINE (2-slot, app-driven)
  // -------------------------------------------------------------------
  // The app is the single source of truth for the queue. Each "deck" is a
  // dumb 2-slot PlaybackEngine that only ever holds [current, next]; the app
  // promotes _currentIndex on the engine's onAdvanced and refreshes the
  // lookahead via setNext. Two decks (A active, B incoming) exist so crossfade
  // can fade volume between them — non-crossfade playback uses only deck A.
  PlaybackEngine? _deckAEngine;
  PlaybackEngine? _deckBEngine;
  String _activeDeckSlot = 'a'; // 'a' or 'b' — which deck is currently active

  /// The queue index currently loaded into the active deck's lookahead
  /// (slot 1), or null if no lookahead is set. On onAdvanced the app promotes
  /// _currentIndex to this value — the engine physically cannot advance to
  /// anything else, which is the whole point of the rewrite.
  int? _lookaheadIndex;

  /// True once the active deck has a source loaded in slot 0. Lets
  /// togglePlayPause detect "first play after restore" (queue restored from
  /// disk but the engine is empty) without reaching into engine internals.
  bool _hasLoadedCurrent = false;

  /// Active deck (the one driving the UI / current song).
  PlaybackEngine get _active =>
      (_activeDeckSlot == 'a' ? _deckAEngine : _deckBEngine)!;

  /// Inactive deck (the crossfade incoming deck).
  PlaybackEngine get _inactive =>
      (_activeDeckSlot == 'a' ? _deckBEngine : _deckAEngine)!;

  /// Per-deck stream subscriptions, re-wired whenever the active deck changes.
  final List<StreamSubscription> _engineSubs = [];

  /// Build the right engine for this platform. Both implement the same
  /// PlaybackEngine contract, so the rest of the service is platform-agnostic.
  PlaybackEngine _createEngine(String tag) =>
      _useJustAudio ? JustAudioEngine() : MediaKitEngine();

  /// Map a queue Song to an EngineItem (the engine's minimal play unit),
  /// carrying display metadata so the mobile engine can populate the OS
  /// media-notification tag.
  EngineItem _engineItemFor(Song song) {
    // Podcasts ALWAYS stream through the backend proxy (getRssStreamUrl), never
    // song.filePath (the raw tracker-wrapped URL). The proxy serves the cached
    // resolved CDN URL — or the local downloaded file once it exists — so it's
    // fast and seekable. Using filePath here was why resume-after-restart
    // re-chased the whole tracker chain and took forever every time.
    final String url;
    if (song.isStation) {
      // Live radio: play the Icecast/Shoutcast URL straight from filePath —
      // never the backend /stream/<id> proxy (there's no library row for it).
      url = song.filePath;
    } else if (song.isPodcast) {
      url = _apiService.getRssStreamUrl(song.podcastEpisodeId ?? -song.id);
    } else {
      url = _apiService.getStreamUrl(song.id, quality: _streamQuality);
    }
    return EngineItem(
      id: song.id,
      url: url,
      isPodcast: song.isPodcast,
      knownDuration: song.duration > 0
          ? Duration(seconds: song.duration)
          : null,
      title: song.title,
      artist: song.artistName,
      album: song.albumTitle,
      artUri: song.isPodcast ? _podcastArtworkUrl : null,
    );
  }

  final ApiService _apiService = ApiService();
  final WidgetService _widgetService = WidgetService();
  Timer? _widgetProgressTimer;
  DateTime? _lastWidgetUpdate;

  Song? _currentSong;
  List<Song> _queue = [];
  int _currentIndex = 0;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  // Backed by a getter/setter (see below) so every transition routes through a
  // single point that drives the Windows keep-awake wakelock.
  bool _isPlayingValue = false;
  bool get _isPlaying => _isPlayingValue;
  set _isPlaying(bool playing) {
    if (playing == _isPlayingValue) return;
    _isPlayingValue = playing;
    // Windows desktop only: hold the system + display awake while audio is
    // actually playing (ELKO box was sleeping mid-song); release on pause/stop.
    // WindowsWakelock no-ops on other platforms, but skip the call entirely
    // on mobile to avoid the needless FFI resolve.
    if (Platform.isWindows) {
      WindowsWakelock.setEnabled(playing);
    }
  }
  bool _isBuffering = false;
  bool _isShuffled = false;
  RepeatMode _repeatMode = RepeatMode.off;
  DateTime? _lastPreviousPress;
  double _volume = 0.7;
  List<Song> _originalQueue = [];
  bool _isNowPlayingVisible = false;

  // Podcast episode playback
  int? _currentEpisodeId;
  String? _podcastTitle;
  String? _podcastEpisodeTitle;
  String? _podcastArtworkUrl;
  int _podcastFeedId = 0;
  int _podcastIntroSkipSeconds = 0;
  int _podcastOutroSkipSeconds = 0;
  bool _didApplyIntroSkip = false; // Per-episode guard so the skip fires once.
  bool _didApplyOutroAdvance = false;
  Timer? _podcastProgressTimer;
  bool get isPlayingPodcast => _currentEpisodeId != null;
  int? get currentEpisodeId => _currentEpisodeId;
  String? get podcastTitle => _podcastTitle;
  String? get podcastEpisodeTitle => _podcastEpisodeTitle;
  String? get podcastArtworkUrl => _podcastArtworkUrl;
  int get podcastFeedId => _podcastFeedId;

  // ── Live station now-playing (polled from backend while a station plays) ──
  // The current track a live radio station is broadcasting. Populated by a
  // poll timer against /api/stations/<id>/now-playing; null when unknown, in
  // which case the UI falls back to the station's own name/genre.
  String? _stationTrackTitle;
  String? _stationTrackArtist;
  String? _stationTrackArtwork;
  Timer? _stationMetaTimer;
  String? get stationTrackTitle => _stationTrackTitle;
  String? get stationTrackArtist => _stationTrackArtist;
  String? get stationTrackArtwork => _stationTrackArtwork;

  /// Title/artist to surface to EXTERNAL now-playing consumers — the OS media
  /// session (Android Auto, lock screen, notification), Windows SMTC, and the
  /// cast receiver (via updateStationNowPlaying on poll change + cast start).
  /// For a live station with a polled track that's the track; otherwise the
  /// item's own title/artist.
  String get displayTitle {
    final s = _currentSong;
    if (s == null) return '';
    if (s.isStation && (_stationTrackTitle?.isNotEmpty ?? false)) {
      return _stationTrackTitle!;
    }
    return s.title;
  }

  String get displayArtist {
    final s = _currentSong;
    if (s == null) return '';
    if (s.isStation && (_stationTrackTitle?.isNotEmpty ?? false)) {
      final a = _stationTrackArtist;
      return (a != null && a.isNotEmpty) ? a : s.title;
    }
    return s.artistsFormatted;
  }

  // Stream retry tracking
  int _streamRetryCount = 0;
  static const int _maxStreamRetries = 3;
  bool _isRetrying = false;

  // Waveform pre-fetch cache. Capped — see _trimPrefetchedWaveforms.
  // Without a cap this grows forever as the user listens; after a few
  // hundred songs the memory cost is non-trivial (each waveform is
  // typically ~8 KB but the count compounds).
  static const int _maxPrefetchedWaveforms = 50;
  final Map<int, List<double>> prefetchedWaveforms = {};
  int? _prefetchingSongId;

  /// Evict oldest entries to keep prefetchedWaveforms under the cap.
  /// Dart Map preserves insertion order, so the first key is the oldest.
  void _trimPrefetchedWaveforms() {
    while (prefetchedWaveforms.length > _maxPrefetchedWaveforms) {
      prefetchedWaveforms.remove(prefetchedWaveforms.keys.first);
    }
  }

  // Stream warm-up tracking (HTTP HEAD to prime TCP connection for next song)
  int? _warmedUpSongId;

  // Queue source tracking (for "Playing from" display and fallback restore)
  String?
  _sourceType; // 'playlist', 'album', 'artist', 'favorites', 'all_songs', 'recently_played', 'most_played', 'single'
  int?
  _sourceId; // ID of playlist/album/artist (null for favorites, all_songs, etc.)
  String? _sourceName; // Display name: "Abbey Road", "Summer Vibes", etc.

  // Loading state - true while restoring playback state
  bool _isLoading = false;

  // Track the last index to detect track changes
  int _lastPlaylistIndex = -1;

  // Flag to indicate user-initiated track change (bypass spurious check)
  bool _userInitiatedChange = false;

  // Flag to ignore spurious zero position/duration during shuffle toggle
  bool _isTogglingShuffle = false;

  // Flag to ignore spurious playlist changes during resume from pause
  bool _isResuming = false;

  // Flag to ignore index changes during player initialization (restore)
  // Set before async player operations — always check _justAudioPlayer != null after awaits
  bool _isInitializingPlayer = false;

  // Playback speed
  double _playbackSpeed = 1.0;

  // Pitch correction (false = vinyl mode where pitch changes with speed)
  bool _pitchCorrectionEnabled = true;

  // Crossfade settings and state
  Duration _crossfadeDuration = const Duration(seconds: 5);
  bool _crossfadeEnabled = true;
  bool _isCrossfading = false; // Accessed from async contexts (timers, futures) — always clear in finally/cancel paths
  bool _crossfadeTriggered = false; // Prevents re-triggering for same song
  Timer? _crossfadeTimer;
  StreamSubscription? _crossfadeBufferSub; // watches the incoming deck until it produces audio, then starts the fade
  int? _crossfadeNextIndex; // Target song index (for completing if main song ends early)
  Song? _crossfadeNextSong; // Target song (for completing if main song ends early)
  bool _crossfadeUITransitioned = false; // True when UI should show the incoming song
  DateTime _lastSongChangeTime = DateTime.now(); // Cooldown to prevent stale-position crossfade triggers

  // Playback state persistence
  String? _deviceId;
  Timer? _saveTimer;
  bool _isRestoring = false;

  // Sleep timer
  Timer? _sleepTimer;
  Timer? _fadeTimer;
  Duration _sleepTimeRemaining = Duration.zero;
  double _volumeBeforeSleep = 1.0;

  // A-B Loop
  Duration? _loopPointA;
  Duration? _loopPointB;

  // ReplayGain normalization.
  //
  // Two-pass design: songs analyzed AFTER the 2026-05-25 Essentia upgrade
  // expose `integratedLoudnessLufs` (proper EBU R128 LUFS, the same value
  // Spotify/Apple Music/YouTube use). Songs analyzed BEFORE that upgrade
  // only have the legacy `loudness` field (Steven's-power-law, arbitrary
  // positive scale). We prefer LUFS, fall back to legacy.
  //
  // - LUFS math:    gain_dB = target_LUFS - actual_LUFS; linear = 10^(gain_dB/20)
  // - Legacy math:  gain_linear = target_legacy / actual_legacy
  bool _replayGainEnabled = true;
  // LUFS target — Spotify uses -14, Apple Music -16, YouTube -14, broadcast -23.
  // -14 is the practical default for streaming-style playback.
  double _targetLufs = -14.0;
  // Legacy target — only used when a song has no LUFS yet (pre-upgrade
  // analyses). Matches the original 5500.0 default simpson1045 was tuned to.
  double _targetLoudness = 5500.0;

  // Mobile data compression / auto quality switching
  String _streamQuality = 'lossless';
  String _qualityPreference = 'auto'; // auto, lossless, high, medium, low
  StreamSubscription? _connectivitySubscription;

  // Stale connection watchdog (one-shot, runs on play-after-idle)
  DateTime _lastActivityTime = DateTime.now();
  Timer? _playWatchdog;

  // Continuous stall watchdog. Catches the case where the engine claims
  // playing=true and !buffering, but position has frozen for several seconds
  // — i.e. media_kit / just_audio's audio thread stalled silently with no
  // `completed` or `error` event. Recovery: force-advance via next(), which
  // routes through _playCurrentIndex(), hard-loading the next track. Without
  // this the UI sits forever showing pause-icon at the frozen position.
  //
  // Detection: every _stallCheckInterval, compare DateTime.now() to the last
  // moment the position stream emitted a value different from the previous
  // one. If that gap exceeds _stallThreshold while playing & not buffering,
  // declare a stall.
  Timer? _stallCheckTimer;
  Duration _lastObservedPosition = Duration.zero;
  DateTime? _lastPositionAdvance;
  bool _isHandlingStall = false;
  // Mid-playback freeze threshold: a song that WAS advancing and then stuck.
  static const Duration _stallThreshold = Duration(seconds: 8);
  // Initial-load threshold: a song still at position 0 hasn't frozen, it's
  // opening. A large hi-res FLAC over a cold NAS/SMB session can take 10-15s
  // to produce its first sample — force-advancing at 8s wrongly skips big
  // files (e.g. a 119 MB lossless track). Give the open a long leash; the
  // engine's own 30s network-timeout handles a genuinely dead stream first,
  // and this only catches a true never-starts freeze as a last resort.
  static const Duration _initialLoadStallThreshold = Duration(seconds: 35);
  static const Duration _stallCheckInterval = Duration(seconds: 2);

  // Position update throttling for mobile performance
  DateTime _lastPositionNotify = DateTime.now();
  static const _mobileThrottleMs = 250; // Only notify every 250ms on mobile
  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  // Stream subscriptions
  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;
  StreamSubscription? _playingSubscription;
  StreamSubscription? _playlistSubscription;

  // Getters
  bool get isLoading => _isLoading;

  // Platform-agnostic stream for external listeners (the media-session
  // bridge in main.dart / NASRadioAudioHandler). Merges both decks so
  // updates flow regardless of which deck is active after a crossfade swap.
  Stream<bool> get playingStream {
    final controller = StreamController<bool>.broadcast();
    _deckAEngine?.playingStream.listen((v) => controller.add(v));
    _deckBEngine?.playingStream.listen((v) => controller.add(v));
    return controller.stream;
  }

  /// Find a song in any of our queues by ID
  Song? _findSongById(int id) {
    // Check _queue first (most common), then _originalQueue
    for (final s in _queue) {
      if (s.id == id) return s;
    }
    for (final s in _originalQueue) {
      if (s.id == id) return s;
    }
    return null;
  }

  Song? get currentSong {
    // Controlling another instance: mirror the target's track.
    if (isControlling) return _syncService.targetSong ?? _currentSong;
    // During a crossfade, show the incoming song once the fade begins.
    if (_crossfadeUITransitioned && _crossfadeNextSong != null) {
      return _crossfadeNextSong;
    }
    // App is the single source of truth: _currentSong is kept in sync by the
    // play paths, onAdvanced, toggleShuffle and the cast/podcast handlers.
    return _currentSong;
  }

  List<Song> get queue => _queue;

  int get currentIndex {
    if (_crossfadeUITransitioned && _crossfadeNextIndex != null) {
      return _crossfadeNextIndex!;
    }
    return _currentIndex;
  }

  Duration get duration {
    if (isControlling) return _syncService.targetDuration;
    // During a crossfade, report the incoming deck's duration.
    if (_crossfadeUITransitioned && _isCrossfading) {
      return _inactive.duration;
    }
    return _duration;
  }

  Duration get position {
    if (isControlling) return _syncService.targetPosition;
    // During a crossfade, report the incoming deck's position.
    if (_crossfadeUITransitioned && _isCrossfading) {
      return _inactive.position;
    }
    return _position;
  }
  bool get isPlaying => isControlling ? _syncService.targetIsPlaying : _isPlaying;
  bool get isBuffering => _isBuffering;
  bool get isShuffled => isControlling ? _syncService.targetIsShuffled : _isShuffled;
  RepeatMode get repeatMode =>
      isControlling ? _syncService.targetRepeatMode : _repeatMode;
  bool get isNowPlayingVisible => _isNowPlayingVisible;
  String? get deviceId => _deviceId;
  String _deviceName = 'Unknown Device';
  String get deviceName => _deviceName;

  void updateDeviceName(String name) {
    _deviceName = name;
    notifyListeners();
  }
  Duration get sleepTimeRemaining => _sleepTimeRemaining;
  bool get isSleepTimerActive => _sleepTimer != null;
  Duration? get loopPointA => _loopPointA;
  Duration? get loopPointB => _loopPointB;
  bool get isLoopActive => _loopPointA != null && _loopPointB != null;
  bool get crossfadeEnabled => _crossfadeEnabled;
  Duration get crossfadeDuration => _crossfadeDuration;
  double get playbackSpeed => _playbackSpeed;
  bool get replayGainEnabled => _replayGainEnabled;
  double get targetLoudness => _targetLoudness;
  bool get pitchCorrectionEnabled => _pitchCorrectionEnabled;
  String get streamQuality => _streamQuality;
  String get qualityPreference => _qualityPreference;

  // Source tracking getters
  String? get sourceType => _sourceType;
  int? get sourceId => _sourceId;
  String? get sourceName => _sourceName;

  String? get playingFromDisplay {
    if (isPlayingPodcast) return _podcastTitle;
    if (_sourceName != null) return _sourceName;
    if (_sourceType == 'favorites') return 'Favorites';
    if (_sourceType == 'all_songs') return 'All Songs';
    if (_sourceType == 'recently_played') return 'Recently Played';
    if (_sourceType == 'most_played') return 'Most Played';
    if (_sourceType == 'single' && _currentSong != null) {
      return _currentSong!.title;
    }
    return null;
  }

  AudioPlayerService() {
    print('🎵 AudioPlayerService init — platform: ${Platform.operatingSystem}, useJustAudio: $_useJustAudio');
    // Two dumb 2-slot decks (A active / B the crossfade incoming deck). Each
    // _createEngine picks MediaKitEngine (desktop) or JustAudioEngine (mobile)
    // internally, so the rest of the service is platform-agnostic. We only
    // ever subscribe to the active deck (see _setupDeckListeners).
    _deckAEngine = _createEngine('a');
    _deckBEngine = _createEngine('b');
    _activeDeckSlot = 'a';
    _setupDeckListeners(_active);
    if (_useJustAudio) {
      _setupAudioSession();
    }
    _initializeDevice();
    _loadVolume();
    _loadQualityPreference();
    _setupConnectivityMonitoring();
    _loadPlaybackSpeed();
    _loadCrossfadeSettings();
    _loadReplayGainSettings();
  }


  // ===================================================================
  // UNIFIED DECK LISTENER (rewrite) — replaces _setupMediaKitListeners +
  // _setupJustAudioListeners. We subscribe ONLY to the active deck, so all
  // the old "slot != _activePlayerSlot" / index-mapping / _lastPlaylistIndex
  // gymnastics disappear: the engine fires onAdvanced exactly when it rolls
  // current→lookahead, and the app owns the queue index. Re-invoked (after
  // cancelling _engineSubs) whenever the active deck changes (crossfade swap).
  // ===================================================================
  void _setupDeckListeners(PlaybackEngine deck) {
    for (final s in _engineSubs) {
      s.cancel();
    }
    _engineSubs.clear();
    // Drop the prior deck's stall watchdog; a fresh one is started at the
    // bottom of this method. Also re-anchor the position-advance timestamp
    // so we don't immediately flag a stall on the new deck.
    _stallCheckTimer?.cancel();
    _lastObservedPosition = Duration.zero;
    _lastPositionAdvance = null;

    // ---- position ----------------------------------------------------
    _engineSubs.add(deck.positionStream.listen((position) {
      if (_isBuffering) return;
      _position = position;
      _lastActivityTime = DateTime.now();
      // Stall watchdog: track the last time position genuinely *advanced*
      // (not just the last time the stream fired). If the engine emits the
      // same value repeatedly while claiming to play, that's a stall.
      if (position != _lastObservedPosition) {
        _lastObservedPosition = position;
        _lastPositionAdvance = DateTime.now();
      }

      // A-B loop
      if (_loopPointA != null && _loopPointB != null) {
        if (position >= _loopPointB!) {
          deck.seek(_loopPointA!);
        }
      }

      // Prefetch waveform + warm up the stream for the upcoming song when
      // <15s remain. Target the lookahead the engine is actually holding.
      if (_duration.inSeconds > 0 && !isPlayingPodcast) {
        final remaining = _duration.inSeconds - position.inSeconds;
        if (remaining <= 15 && remaining > 0) {
          final nextIndex = _lookaheadIndex ?? (_currentIndex + 1);
          if (nextIndex >= 0 && nextIndex < _queue.length) {
            final nextSong = _queue[nextIndex];
            if (!prefetchedWaveforms.containsKey(nextSong.id) &&
                _prefetchingSongId != nextSong.id) {
              _prefetchingSongId = nextSong.id;
              _apiService.getWaveform(nextSong.id).then((waveform) {
                prefetchedWaveforms[nextSong.id] = waveform;
                _trimPrefetchedWaveforms();
              }).catchError((e) {});
            }
            if (_warmedUpSongId != nextSong.id) {
              _warmedUpSongId = nextSong.id;
              final warmUpUrl =
                  _apiService.getStreamUrl(nextSong.id, quality: _streamQuality);
              http.head(Uri.parse(warmUpUrl)).timeout(
                const Duration(seconds: 5),
                onTimeout: () => http.Response('', 408),
              ).then((_) {}).catchError((e) {});
            }
          }
        }
      }

      // Crossfade detection — dual-deck ping-pong (task #5, implemented).
      _maybeStartCrossfade(position);

      // Throttle UI updates on mobile.
      if (_useJustAudio) {
        final now = DateTime.now();
        if (now.difference(_lastPositionNotify).inMilliseconds <
            _mobileThrottleMs) {
          return;
        }
        _lastPositionNotify = now;
      }
      notifyListeners();
    }));

    // ---- duration ----------------------------------------------------
    _engineSubs.add(deck.durationStream.listen((duration) {
      // Mobile transcoded streams report unreliable durations — lock to the
      // DB value for non-lossless. (Desktop keeps the decoder's value.)
      if (_useJustAudio &&
          _streamQuality != 'lossless' &&
          _currentSong != null &&
          _currentSong!.duration > 0) {
        final dbDuration = Duration(seconds: _currentSong!.duration);
        if (_duration != dbDuration) {
          _duration = dbDuration;
          notifyListeners();
        }
        return;
      }
      if (duration != null && duration.inMilliseconds > 0) {
        _duration = duration;
      } else if (_currentSong != null && _currentSong!.duration > 0) {
        _duration = Duration(seconds: _currentSong!.duration);
      } else {
        _duration = Duration.zero;
      }
      notifyListeners();
    }));

    // ---- playing -----------------------------------------------------
    _engineSubs.add(deck.playingStream.listen((playing) {
      if (playing == _isPlaying) return;
      // Ignore the brief "false" the engine emits during a track transition
      // (skip/next reloads slot 0). Gapless rolls never stop playback.
      if (!playing) {
        if (_isCrossfading) return;
        final msSinceChange =
            DateTime.now().difference(_lastSongChangeTime).inMilliseconds;
        if (msSinceChange < 1500) return;
      }
      _isPlaying = playing;
      notifyListeners();
    }));

    // ---- buffering ---------------------------------------------------
    _engineSubs.add(deck.bufferingStream.listen((buffering) {
      if (buffering == _isBuffering) return;
      _isBuffering = buffering;
      AppLogger.instance.info(
        '[player.buffering] $buffering '
        'queueIdx=$_currentIndex/${_queue.length} song="${_currentSong?.title}"',
      );
      notifyListeners();
    }));

    // ---- onAdvanced: slot 0 ended, engine rolled to the lookahead -----
    _engineSubs.add(deck.onAdvanced.listen((_) {
      if (_isCrossfading) return;
      final prevSong = _currentSong;
      if (prevSong != null) {
        _apiService.trackComplete(prevSong.id, 100).catchError((e) {});
      }

      // Promote to exactly the index we put in the lookahead — the engine
      // could not have advanced to anything else.
      final promoted = _lookaheadIndex;
      if (promoted != null && promoted >= 0 && promoted < _queue.length) {
        _currentIndex = promoted;
      } else if (_currentIndex < _queue.length - 1) {
        _currentIndex++;
      }
      if (_queue.isEmpty) return;
      if (_currentIndex >= _queue.length) _currentIndex = _queue.length - 1;
      _currentSong = _queue[_currentIndex];

      _position = Duration.zero;
      _lastSongChangeTime = DateTime.now();
      // Fresh track — re-anchor the stall watchdog so the previous track's
      // last-advance timestamp doesn't bleed forward.
      _lastObservedPosition = Duration.zero;
      _lastPositionAdvance = DateTime.now();
      if (_currentSong!.duration > 0) {
        _duration = Duration(seconds: _currentSong!.duration);
      }
      _crossfadeTriggered = false;
      _loopPointA = null;
      _loopPointB = null;
      _applyVolume();

      AppLogger.instance.info(
        '[player.advance] onAdvanced → queueIdx=$_currentIndex '
        'song="${_currentSong!.title}"',
      );
      _apiService.trackPlay(_currentSong!.id).catchError((e) {});

      // Hand the engine the next-next lookahead.
      _refreshLookahead();
      notifyListeners();
      savePlaybackState();
    }));

    // ---- onCompleted: slot 0 ended with NO lookahead ------------------
    _engineSubs.add(deck.onCompleted.listen((_) {
      if (_isCrossfading) return;
      AppLogger.instance.info(
        '[player.complete] onCompleted queueIdx=$_currentIndex/${_queue.length} '
        'repeatMode=$_repeatMode podcast=$isPlayingPodcast',
      );
      if (isPlayingPodcast) {
        _advanceToNextPodcastEpisode();
        return;
      }
      if (_repeatMode == RepeatMode.one) {
        deck.seek(Duration.zero);
        deck.play();
        return;
      }
      if (_currentIndex >= _queue.length - 1 &&
          _repeatMode == RepeatMode.all &&
          _queue.isNotEmpty) {
        // Wrap to the start of the queue.
        _currentIndex = 0;
        _currentSong = _queue[0];
        _position = Duration.zero;
        _lastSongChangeTime = DateTime.now();
        deck.loadCurrent(_engineItemFor(_queue[0]), autoPlay: true).then((_) {
          _applyVolume();
          _refreshLookahead();
        });
        notifyListeners();
        return;
      }
      // End of queue, no repeat — stop.
      _isPlaying = false;
      notifyListeners();
    }));

    // ---- onError -----------------------------------------------------
    _engineSubs.add(deck.onError.listen((error) async {
      AppLogger.instance.error('[player.error] $error');
      final completionRatio = _duration.inMilliseconds > 0
          ? _position.inMilliseconds / _duration.inMilliseconds
          : 0.0;
      if (completionRatio >= 0.95) {
        _streamRetryCount = 0;
        return;
      }
      if (_isCrossfading) return;
      final errorStr = error.toLowerCase();
      final retryable = errorStr.contains('tcp') ||
          errorStr.contains('ffurl') ||
          errorStr.contains('failed to open') ||
          errorStr.contains('connection') ||
          errorStr.contains('404') ||
          errorStr.contains('http') ||
          _useJustAudio; // just_audio errors are less classifiable; retry.
      if (retryable &&
          _currentSong != null &&
          !_isRetrying &&
          _streamRetryCount < _maxStreamRetries) {
        _isRetrying = true;
        _streamRetryCount++;
        final backoffMs = 500 * _streamRetryCount;
        AppLogger.instance.info(
          '[player.stream-retry] start attempt $_streamRetryCount/'
          '$_maxStreamRetries backoff=${backoffMs}ms song="${_currentSong!.title}"',
        );
        await Future.delayed(Duration(milliseconds: backoffMs));
        try {
          if (_useJustAudio) await ApiService.detectNetwork();
          final savedPosition = _position;
          // Unified: reload the current song into slot 0 and re-establish the
          // lookahead. loadCurrent handles both backends — no _buildPlaylist /
          // setAudioSource branching.
          await deck.loadCurrent(
            _engineItemFor(_currentSong!),
            startPosition: savedPosition,
            autoPlay: true,
          );
          _applyVolume();
          await _refreshLookahead();
          AppLogger.instance.info(
            '[player.stream-retry] OK resumed at ${_formatDuration(savedPosition)}',
          );
        } catch (e) {
          AppLogger.instance.error('[player.stream-retry] failed: $e');
        }
        _isRetrying = false;
      } else if (_streamRetryCount >= _maxStreamRetries &&
          _currentIndex < _queue.length - 1) {
        AppLogger.instance.warning(
          '[player.stream-retry] exhausted — skipping: ${_currentSong?.title}',
        );
        _streamRetryCount = 0;
        next();
      }
    }));

    // ---- continuous stall watchdog -----------------------------------
    // Polls every _stallCheckInterval; recovery action lives in
    // _checkForStall(). Cancelled on deck swap (top of this method) and
    // in dispose().
    _stallCheckTimer?.cancel();
    _stallCheckTimer = Timer.periodic(_stallCheckInterval, (_) => _checkForStall());
  }

  /// Continuous stall detector. Fires when the engine claims to be playing
  /// but position has not actually advanced for [_stallThreshold]. The known
  /// trigger is media_kit's audio thread silently halting on certain files —
  /// no `completed`, no `error`, no `buffering=true`. Recovery: call next(),
  /// which routes through _playCurrentIndex and hard-loads the next track
  /// (or wraps / stops based on repeat state).
  void _checkForStall() {
    if (!_isPlaying) return;
    if (_isBuffering) return;
    if (_isCrossfading) return;
    if (_isHandlingStall) return;
    if (_isRetrying) return;
    if (isCasting) return;
    if (isPlayingPodcast) return; // podcast advance handled in onCompleted
    if (_queue.isEmpty || _currentSong == null) return;
    final lastAdvance = _lastPositionAdvance;
    if (lastAdvance == null) return; // no data yet
    // A song still at position 0 is opening, not frozen — give a slow large
    // file room to load instead of skipping it. Once it has played past 0,
    // revert to the short freeze threshold for genuine mid-playback stalls.
    final neverStarted = _position == Duration.zero;
    final threshold =
        neverStarted ? _initialLoadStallThreshold : _stallThreshold;
    if (DateTime.now().difference(lastAdvance) < threshold) return;

    _isHandlingStall = true;
    AppLogger.instance.warning(
      '[player.stall] no position advance in '
      '${_stallThreshold.inSeconds}s — forcing advance. '
      'queueIdx=$_currentIndex/${_queue.length} song="${_currentSong?.title}" '
      'pos=${_position.inSeconds}s dur=${_duration.inSeconds}s '
      'isPlaying=$_isPlaying isBuffering=$_isBuffering',
    );
    next().whenComplete(() {
      _isHandlingStall = false;
    });
  }

  /// Compute which queue index should occupy the lookahead (slot 1), given
  /// the current index and repeat mode. Returns null when there should be no
  /// lookahead (repeat-one, or end-of-queue with no repeat) — in which case
  /// the engine fires onCompleted and we handle it there.
  int? _computeNextIndex() {
    if (_repeatMode == RepeatMode.one) return null;
    if (_currentIndex < _queue.length - 1) return _currentIndex + 1;
    if (_repeatMode == RepeatMode.all && _queue.isNotEmpty) return 0;
    return null;
  }

  /// Recompute and hand the active deck its lookahead. This is the single
  /// reconciliation point: every queue mutation and every advance routes
  /// through here, so the engine's slot 1 is ALWAYS exactly what the app's
  /// queue says comes next. Avoids redundant setNext when already loaded.
  Future<void> _refreshLookahead() async {
    if (_deckAEngine == null) return; // not yet wired
    if (isPlayingPodcast || _queue.isEmpty) {
      _lookaheadIndex = null;
      await _active.setNext(null);
      return;
    }
    final ni = _computeNextIndex();
    _lookaheadIndex = ni;
    if (ni == null) {
      await _active.setNext(null);
      return;
    }
    final desired = _engineItemFor(_queue[ni]);
    if (_active.nextItem == desired) return; // already loaded (==, on id+url)
    await _active.setNext(desired);
  }

  /// THE single explicit-play primitive. Loads _queue[_currentIndex] into the
  /// active deck (slot 0), pre-buffers the lookahead (slot 1), and tracks a
  /// play start. Every user-initiated transition — setQueue, playSong,
  /// playFromQueue, next, previous — funnels through here after setting
  /// _currentIndex. Gapless advances do NOT come here (the engine rolls
  /// slot0→slot1 and we react in onAdvanced).
  Future<void> _playCurrentIndex({
    bool autoPlay = true,
    Duration startPosition = Duration.zero,
  }) async {
    if (_queue.isEmpty || _currentIndex < 0 || _currentIndex >= _queue.length) {
      return;
    }
    final song = _queue[_currentIndex];
    _currentSong = song;
    _position = startPosition;
    _lastSongChangeTime = DateTime.now();
    _crossfadeTriggered = false;
    if (song.duration > 0) {
      _duration = Duration(seconds: song.duration);
    }
    _streamRetryCount = 0;
    _apiService.trackPlay(song.id).catchError((e) {});
    try {
      await _active.loadCurrent(
        _engineItemFor(song),
        startPosition: startPosition,
        autoPlay: autoPlay,
      );
      _hasLoadedCurrent = true;
      _applyVolume();
      await _refreshLookahead();
      // Podcast resume routes through here (first play after restore), NOT
      // playPodcastEpisode — so do the podcast-specific setup it would miss:
      // start the progress timer (position save + outro skip) and kick off the
      // background download (instant seeking + the progress indicator).
      if (song.isPodcast) {
        _startPodcastProgressTimer();
        final epId = song.podcastEpisodeId ?? -song.id;
        Timer(const Duration(seconds: 20), () {
          if (_currentEpisodeId == epId) {
            _apiService.downloadEpisode(epId).catchError((_) {});
          }
        });
      }
    } catch (e) {
      AppLogger.instance.error('[player] _playCurrentIndex loadCurrent failed: $e');
    }
  }

  // Set queue and start playback using the 2-slot engine
  void setQueue(
    List<Song> songs,
    int startIndex, {
    String? sourceType,
    int? sourceId,
    String? sourceName,
  }) {
    _cancelCrossfade(); // Cancel any in-progress crossfade
    _crossfadeTriggered = false;

    // Clear podcast mode when switching to regular music
    if (songs.isNotEmpty && !songs.first.isPodcast) {
      _clearPodcastMode();
    }

    // Track queue source for "Playing from" display and restore fallback
    _sourceType = sourceType;
    _sourceId = sourceId;
    _sourceName = sourceName;

    _queue = songs;
    _originalQueue = List.from(songs);
    _currentIndex = startIndex;
    _isShuffled = false; // Reset shuffle when starting new queue

    if (songs.isEmpty || startIndex < 0 || startIndex >= songs.length) return;

    _currentSong = songs[startIndex];
    _position = Duration.zero;
    _lastSongChangeTime = DateTime.now();
    if (_currentSong!.duration > 0) {
      _duration = Duration(seconds: _currentSong!.duration);
    }

    // Chromecast: send current song to cast device (no local engine).
    if (isCasting) {
      _isPlaying = true;
      _apiService.trackPlay(_currentSong!.id).catchError((e) {});
      _castService!.loadAndPlay(_currentSong!,
          quality: _streamQuality, podcastArtworkUrl: _podcastArtworkUrl);
      _startSaveTimer();
      if (!_isRestoring) savePlaybackState();
      notifyListeners();
      return;
    }

    // App-driven 2-slot engine: load current, pre-buffer next. No platform
    // branch, no full-playlist dump, no _isInitializingPlayer gymnastics.
    print('🎵 Queue set (${songs.length} songs) → "${_currentSong!.title}" @ $startIndex');
    _playCurrentIndex(autoPlay: true);
    _prefetchNextSong();

    _startSaveTimer();
    if (!_isRestoring) savePlaybackState();
    notifyListeners();
  }

  // Play a song — loads full album as queue, starting at this track
  Future<void> playSong(Song song) async {
    // Switching to real music — release podcast mode so the playlist
    // listener and gapless advance aren't blocked, and the podcast
    // progress timer stops firing for a now-defunct episode.
    if (!song.isPodcast) {
      _clearPodcastMode();
    }
    // Any play switches off the previous station's metadata polling; the
    // station branch below restarts it when the new item is itself a station.
    _stopStationMetaPolling();

    // Stations: a single live stream — no album/queue to load. Play it locally
    // (no album fetch, no gapless next, no seekable position).
    if (song.isStation) {
      _queue = [song];
      _originalQueue = [song];
      _currentIndex = 0;
      _lastPlaylistIndex = 0;
      _currentSong = song;
      _sourceType = 'station';
      _sourceName = 'Stations';
      _position = Duration.zero;
      _duration = Duration.zero;
      _lastSongChangeTime = DateTime.now();
      if (isCasting) {
        _isPlaying = true;
        await _castService!.loadAndPlay(song, quality: _streamQuality);
      } else {
        await _playCurrentIndex(autoPlay: true);
      }
      _loopPointA = null;
      _loopPointB = null;
      _startStationMetaPolling();
      _startSaveTimer();
      if (!_isRestoring) savePlaybackState();
      notifyListeners();
      return;
    }

    // Try to load the full album as the queue
    List<Song> albumSongs = [song];
    int songIndex = 0;
    String sourceType = 'single';
    String? sourceName;

    try {
      final albumData = await _apiService.getAlbum(song.albumId);
      final songsJson = albumData['songs'] as List<dynamic>? ?? [];
      if (songsJson.isNotEmpty) {
        albumSongs = songsJson.map((s) => Song.fromJson(s)).toList();
        songIndex = albumSongs.indexWhere((s) => s.id == song.id);
        if (songIndex < 0) {
          // Song not found in album (shouldn't happen), prepend it
          albumSongs.insert(0, song);
          songIndex = 0;
        }
        sourceType = 'album';
        sourceName = albumData['title'] as String?;
        print('🎵 Loaded album "${sourceName}" with ${albumSongs.length} tracks, starting at track ${songIndex + 1}');
      }
    } catch (e) {
      print('⚠️ Failed to load album for song, falling back to single: $e');
    }

    _queue = List.from(albumSongs);
    _originalQueue = List.from(albumSongs);
    _currentIndex = songIndex;
    _lastPlaylistIndex = songIndex;
    _currentSong = song;
    _sourceType = sourceType;
    _sourceName = sourceName;

    print('🎵 Playing: ${song.title}');

    // Pre-set duration from song metadata and reset position
    _position = Duration.zero;
    _lastSongChangeTime = DateTime.now();
    if (_useJustAudio && song.duration > 0) {
      _duration = Duration(seconds: song.duration);
    }

    // Chromecast: send to cast device instead of local engine.
    if (isCasting) {
      _isPlaying = true;
      _apiService.trackPlay(song.id).catchError((e) {});
      await _castService!.loadAndPlay(song,
          quality: _streamQuality, podcastArtworkUrl: _podcastArtworkUrl);
      // Tuning to a station WHILE casting: re-push the live track once the
      // receiver has finished processing the LOAD. The poll's immediate
      // push races the LOAD — the receiver's post-LOAD repaint overwrites
      // it with the static station name and the poll won't re-send until
      // the broadcast rotates. Same 3s heuristic as startCasting's push
      // (that path only covers cast-start, not mid-cast station changes).
      if (song.isStation) {
        Future.delayed(const Duration(seconds: 3), () {
          if (isCasting &&
              _currentSong?.isStation == true &&
              _stationTrackTitle != null) {
            _castService?.updateStationNowPlaying(displayTitle, displayArtist,
                artworkUrl: _stationTrackArtwork);
          }
        });
      }
      _startSaveTimer();
      if (!_isRestoring) savePlaybackState();
      notifyListeners();
      return;
    }

    // App-driven 2-slot engine: load the chosen track, pre-buffer the next.
    // The whole album is already in _queue, so next/previous and gapless
    // advance work off the queue — no full-playlist dump into the player.
    await _playCurrentIndex(autoPlay: true);

    // Clear A-B loop on song change
    _loopPointA = null;
    _loopPointB = null;

    _startSaveTimer();
    if (!_isRestoring) savePlaybackState();

    notifyListeners();
  }

  // Play/Pause toggle
  Future<void> togglePlayPause() async {
    if (isControlling) {
      _syncService.sendRemoteCommand('toggle_play_pause');
      return;
    }
    // Chromecast: delegate play/pause
    if (isCasting) {
      if (_castService!.isPlaying) {
        _castService!.pause();
      } else if (_castService!.mediaSessionId == null && _currentSong != null) {
        // Rejoined a receiver with nothing loaded (the song ended while
        // the app was swiped away) — play means "pick the queue back up
        // on the TV from where we left off," not a no-op PLAY into a
        // dead media session.
        await _castService!.loadAndPlay(_currentSong!,
            quality: _streamQuality,
            startPosition: _position,
            podcastArtworkUrl: _podcastArtworkUrl);
      } else {
        _castService!.play();
      }
      return;
    }

    // Don't allow play if we're still loading or queue isn't ready
    if (_isLoading || (_currentSong != null && _queue.isEmpty)) {
      print(
        '⏳ Play blocked - still loading (isLoading: $_isLoading, queue empty: ${_queue.isEmpty})',
      );
      return;
    }

    // First play after restore: the queue/index/position were restored from
    // disk but the engine has nothing loaded yet. Load the current song at
    // the saved position — uniform across platforms and music/podcast, no
    // 2-song-container / full-playlist rebuild, no _isInitializingPlayer.
    if (!_hasLoadedCurrent && _queue.isNotEmpty && _currentSong != null) {
      final savedPosition = _position;
      _isBuffering = true;
      notifyListeners(); // Show spinner immediately
      if (_currentIndex >= _queue.length) {
        _currentIndex = _queue.isEmpty ? 0 : _queue.length - 1;
      }
      if (!_isShuffled) _originalQueue = List.from(_queue);
      await _playCurrentIndex(autoPlay: true, startPosition: savedPosition);
      _isBuffering = false;
      if (_currentEpisodeId != null) {
        _startPodcastProgressTimer();
      }
      _startSaveTimer();
      notifyListeners();
      return;
    }

    // Normal toggle.
    if (_active.playing) {
      await _active.pause();
    } else {
      await _active.play();
    }

    if (!_isPlaying) {
      _cancelCrossfade(); // Cancel crossfade on pause
      _stopSaveTimer();
      savePlaybackState();
    } else {
      _startSaveTimer();
      // If idle for 5+ minutes, start watchdog to detect stale connections
      if (DateTime.now().difference(_lastActivityTime).inMinutes >= 5) {
        _startPlayWatchdog();
      }
    }
  }

  /// Explicit (non-toggling) play/pause for MediaSession callbacks.
  /// Android delivers DISTINCT play and pause commands (lock screen,
  /// notification, Bluetooth, Android Auto, TV-remote round trips) —
  /// routing both through togglePlayPause() inverted the command any
  /// time our mirrored state was momentarily stale. Worst case while
  /// casting: LG remote pauses the receiver, phone gets the PAUSED
  /// status, then a queued "pause" command toggles → we send PLAY and
  /// the music un-pauses itself (the Aug 12 log shows the receiver
  /// getting PAUSE then PLAY 211ms later). Explicit semantics make the
  /// stale-state case a harmless no-op instead.
  Future<void> playExplicit() async {
    if (isCasting) {
      _castService!.play();
      return;
    }
    if (!isPlaying) await togglePlayPause();
  }

  Future<void> pauseExplicit() async {
    if (isCasting) {
      _castService!.pause();
      return;
    }
    if (isPlaying) await togglePlayPause();
  }

  // Stop
  Future<void> stop() async {
    await _active.stop();
    _hasLoadedCurrent = false;
    _stopSaveTimer();
    savePlaybackState();
  }

  // Seek to position
  Future<void> seek(Duration position, {bool? autoplay}) async {
    if (isControlling) {
      _syncService.sendRemoteCommand('seek',
          args: {'position_ms': position.inMilliseconds});
      return;
    }
    // Chromecast: delegate seek
    if (isCasting) {
      _castService!.seekTo(position);
      return;
    }
    // Fresh app open: restore only sets metadata — nothing is loaded into the
    // engine yet, so a raw seek() is a no-op. That made the scrubber, chapter
    // taps, and previous button all look dead until the first "play". Load the
    // current song at the requested position so these controls work on open.
    // autoplay: chapter taps pass true ("play this chapter"); the scrubber
    // leaves it null so a restored-paused session just repositions and stays
    // paused until you hit play.
    if (!_hasLoadedCurrent && _currentSong != null) {
      _crossfadeTriggered = false;
      await _playCurrentIndex(
        startPosition: position,
        autoPlay: autoplay ?? _isPlaying,
      );
      return;
    }
    // Allow crossfade to re-trigger after seeking (user may seek near end)
    _crossfadeTriggered = false;
    await _active.seek(position);
  }

  // Play song at specific index in queue
  /// Play a podcast episode via its stream URL.
  /// Pauses current music, loads the episode URL into the player,
  /// and starts a periodic timer to save playback progress.
  /// Play a podcast episode. Pass allEpisodes (oldest-first) to build a queue.
  Future<void> playPodcastEpisode(
    RssEpisode episode,
    String streamUrl, {
    String? artworkUrl,
    String? podcastAuthor,
    String? podcastTitle,
    int feedId = 0,
    List<RssEpisode>? allEpisodes,
    int introSkipSeconds = 0,
    int outroSkipSeconds = 0,
  }) async {
    // Clear previous podcast timer
    _stopPodcastProgressTimer();

    final author = podcastAuthor ?? episode.feedAuthor ?? 'Podcast';
    final showName = podcastTitle ?? episode.feedTitle ?? 'Podcast';

    // Store podcast metadata
    _currentEpisodeId = episode.id;
    _podcastTitle = showName;
    _podcastEpisodeTitle = episode.title;
    _podcastArtworkUrl = artworkUrl ?? episode.artworkUrl;
    _podcastFeedId = feedId;
    _podcastIntroSkipSeconds = introSkipSeconds;
    _podcastOutroSkipSeconds = outroSkipSeconds;
    _didApplyIntroSkip = false;
    _didApplyOutroAdvance = false;

    // Build virtual Song for this episode. Negative IDs are legacy — the
    // sourceType/podcastEpisodeId/podcastFeedId fields are the new identity
    // source of truth and will replace the negative-ID check in Step 2.
    Song episodeToSong(RssEpisode ep) => Song(
      id: -ep.id,
      title: ep.title,
      artistId: 0,
      artistName: author,
      albumId: -feedId,
      albumTitle: showName,
      trackNumber: 0,
      duration: ep.audioDuration ?? 0,
      filePath: ep.audioUrl ?? _apiService.getRssStreamUrl(ep.id),
      fileSize: ep.audioSize ?? 0,
      bitrate: 0,
      sourceType: 'podcast',
      podcastFeedId: feedId,
      podcastEpisodeId: ep.id,
      playedPosition: ep.playedPosition,
      isCompleted: ep.isCompleted,
    );

    _currentSong = episodeToSong(episode);

    // Build queue from all episodes (oldest to newest) so playback continues
    if (allEpisodes != null && allEpisodes.isNotEmpty) {
      _queue = allEpisodes.map(episodeToSong).toList();
      _currentIndex = _queue.indexWhere((s) => s.id == _currentSong!.id);
      if (_currentIndex < 0) _currentIndex = 0;
    } else {
      _queue = [_currentSong!];
      _currentIndex = 0;
    }
    _originalQueue = List.from(_queue);

    // Fetch authoritative played_position from the backend. The passed-in
    // RssEpisode may be from a cached list view whose progress is stale
    // (another device has advanced further, or we completed locally but
    // the list wasn't refreshed).
    int startPosition = episode.playedPosition;
    try {
      final epData = await _apiService.getRssEpisode(episode.id);
      final fresh = epData['episode'] ?? epData;
      final freshPos = fresh['played_position'];
      if (freshPos is int) {
        startPosition = freshPos;
      } else if (freshPos is num) {
        startPosition = freshPos.toInt();
      }
      print('🎙️ Resume position: stale=${episode.playedPosition}s, fresh=${startPosition}s');
    } catch (e) {
      print('⚠️ Could not fetch fresh episode progress, using cached: $e');
    }

    // Auto-skip intro: only when starting fresh. If we're resuming mid-
    // episode (startPosition > 0), the user was already past the intro,
    // so don't surprise them by jumping further forward.
    if (startPosition == 0 && introSkipSeconds > 0) {
      startPosition = introSkipSeconds;
      _didApplyIntroSkip = true;
      print('🎙️ Auto-skip intro: jumping to ${introSkipSeconds}s');
    }

    try {
      // Pre-set position so the UI shows the resume point during buffering.
      _position = startPosition > 0
          ? Duration(seconds: startPosition)
          : Duration.zero;
      _isBuffering = true;
      notifyListeners();

      // Load the episode into slot 0 at the saved position. Podcasts have no
      // gapless lookahead — onCompleted hands off to _advanceToNextPodcastEpisode.
      await _active.loadCurrent(
        EngineItem(
          id: _currentSong!.id,
          url: streamUrl,
          isPodcast: true,
          knownDuration: _currentSong!.duration > 0
              ? Duration(seconds: _currentSong!.duration)
              : null,
          title: _currentSong!.title,
          artist: _currentSong!.artistName,
          album: _currentSong!.albumTitle,
          artUri: _podcastArtworkUrl,
        ),
        startPosition: _position,
        autoPlay: true,
      );
      _hasLoadedCurrent = true;
      _lookaheadIndex = null;
      await _active.setNext(null);
      _applyVolume();
      _isBuffering = false;
      _isPlaying = true;

      // Save progress every 15 seconds + handle outro auto-advance
      _startPodcastProgressTimer();
      // Persist the now-playing pointer the same way the music paths do: start
      // the 3s save timer AND write once immediately. Without this the podcast
      // resume pointer goes stale — starting an episode (or rolling to the next)
      // never updates last_podcast_episode_id / last_song_json, so on next launch
      // the app restores the OLD episode even after the previous one completed.
      _startSaveTimer();
      savePlaybackState();
      // Download the episode to the NAS so seeking becomes instant (the stream
      // endpoint serves the local file once it's there). DELAYED ~20s: firing
      // it immediately stole bandwidth from the initial stream buffer and made
      // first-play take ~30s. By the time you'd seek, it's downloading/done.
      // Only fires if still on this episode. Idempotent + auto-deleted on done.
      final epId = episode.id;
      Timer(const Duration(seconds: 20), () {
        if (_currentEpisodeId == epId) {
          _apiService.downloadEpisode(epId).catchError((_) {});
        }
      });
    } catch (e) {
      print('Error playing podcast episode: $e');
      AppLogger.instance.error('Podcast play failed: ${episode.title} — $e');
      // Don't clear _currentEpisodeId — keep podcast mode so the listener
      // guard stays active and doesn't overwrite _currentSong
    }

    notifyListeners();
  }

  void _stopPodcastProgressTimer() {
    _podcastProgressTimer?.cancel();
    _podcastProgressTimer = null;
    // Save final position if we were playing a podcast
    if (_currentEpisodeId != null && _position.inSeconds > 0) {
      _apiService.updateEpisodeProgress(
        _currentEpisodeId!,
        _position.inSeconds,
        isCompleted: _duration.inSeconds > 0 &&
            _position.inSeconds > _duration.inSeconds * 0.9,
      ).catchError((e) => print('⚠️ Podcast progress save failed: $e'));
    }
  }

  void _clearPodcastMode() {
    _stopPodcastProgressTimer();
    _currentEpisodeId = null;
    _podcastTitle = null;
    _podcastEpisodeTitle = null;
    _podcastArtworkUrl = null;
    _podcastFeedId = 0;
  }

  // ── Live station now-playing polling ──────────────────────────────────
  // Poll the backend for the station's current track. The timer is
  // self-healing: every tick re-checks that a station is still playing and
  // cancels itself otherwise, so leaving the station by ANY play path (song,
  // podcast, stop) reliably ends polling even if we miss an explicit stop.
  void _startStationMetaPolling() {
    _stationMetaTimer?.cancel();
    // Blank out the previous station's track so a freshly-tuned station
    // doesn't briefly show the old one before the first poll lands.
    _stationTrackTitle = null;
    _stationTrackArtist = null;
    _stationTrackArtwork = null;
    _pollStationMeta(); // immediate first fetch — don't wait 15s to show a track
    _stationMetaTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _pollStationMeta());
  }

  void _pollStationMeta() {
    final song = _currentSong;
    if (song == null || !song.isStation) {
      _stationMetaTimer?.cancel();
      _stationMetaTimer = null;
      return;
    }
    // The app negates station DB ids to build synthetic Song ids, so the
    // real station id is -song.id.
    final stationId = -song.id;
    _apiService.getStationNowPlaying(stationId).then((data) {
      if (_currentSong?.isStation != true) return; // switched away mid-request
      String? clean(dynamic v) {
        final s = (v as String?)?.trim();
        return (s == null || s.isEmpty) ? null : s;
      }

      final title = clean(data['title']);
      final artist = clean(data['artist']);
      final artwork = clean(data['artwork_url']);
      if (title != _stationTrackTitle ||
          artist != _stationTrackArtist ||
          artwork != _stationTrackArtwork) {
        _stationTrackTitle = title;
        _stationTrackArtist = artist;
        _stationTrackArtwork = artwork;
        notifyListeners();
        // Casting this station? Push the new track to the receiver (the OS
        // media session / SMTC pick it up automatically via displayTitle).
        if (isCasting) {
          _castService?.updateStationNowPlaying(displayTitle, displayArtist,
              artworkUrl: _stationTrackArtwork);
        }
      }
    }).catchError((_) {}); // best-effort; a failed tick keeps the last track
  }

  void _stopStationMetaPolling() {
    _stationMetaTimer?.cancel();
    _stationMetaTimer = null;
    _stationTrackTitle = null;
    _stationTrackArtist = null;
    _stationTrackArtwork = null;
  }

  bool _isAdvancingPodcast = false;

  /// Advance to next podcast episode when the current one ends.
  /// Podcasts load as a single Media item (not a Playlist), so gapless
  /// advance doesn't happen automatically — detect completion and load
  /// the next episode manually.
  Future<void> _advanceToNextPodcastEpisode() async {
    if (!isPlayingPodcast || _isAdvancingPodcast) return;
    final nextIndex = _currentIndex + 1;
    if (nextIndex >= _queue.length) {
      print('🎙️ Last episode finished, nothing to advance to');
      return;
    }
    final nextSong = _queue[nextIndex];
    if (!nextSong.isPodcast) return; // Next item isn't a podcast

    _isAdvancingPodcast = true;
    try {
      print('🎙️ Advancing to next episode: ${nextSong.title}');
      _currentIndex = nextIndex;
      _lastPlaylistIndex = nextIndex;
      _currentSong = nextSong;
      _position = Duration.zero;
      _duration = nextSong.duration > 0
          ? Duration(seconds: nextSong.duration)
          : Duration.zero;

      // Updates _currentEpisodeId, marks prev completed, restarts timer
      _updatePodcastEpisodeFromSong(nextSong);
      _podcastEpisodeTitle = nextSong.title;

      notifyListeners(); // UI flips to new episode immediately

      // Use the backend proxy URL, NOT nextSong.filePath. The Song's
      // filePath was populated at queue-build time; if it's a resolved CDN
      // URL, the TTL may have expired by the time the previous episode
      // completed → 403/404 → load hangs forever. The proxy endpoint
      // re-resolves on every hit, so it's always fresh.
      final episodeId = nextSong.podcastEpisodeId ?? -nextSong.id;
      final freshUrl = _apiService.getRssStreamUrl(episodeId);

      await _active.loadCurrent(
        EngineItem(
          id: nextSong.id,
          url: freshUrl,
          isPodcast: true,
          knownDuration: nextSong.duration > 0
              ? Duration(seconds: nextSong.duration)
              : null,
          title: nextSong.title,
          artist: nextSong.artistName,
          album: nextSong.albumTitle,
          artUri: _podcastArtworkUrl,
        ),
        autoPlay: true,
      );
      _hasLoadedCurrent = true;
      _lookaheadIndex = null;
      await _active.setNext(null); // podcasts: no gapless lookahead
      _applyVolume();
      // Reset progress-timer flags for the new episode and restart it.
      _didApplyIntroSkip = false;
      _didApplyOutroAdvance = false;
      _startPodcastProgressTimer();
      // Persist the now-playing pointer to the NEW episode immediately so a
      // restart resumes here, not on the episode that just finished.
      savePlaybackState();
      // Background-download the newly-advanced episode for instant seeking,
      // delayed so it doesn't fight the new episode's initial buffer.
      Timer(const Duration(seconds: 20), () {
        if (_currentEpisodeId == episodeId) {
          _apiService.downloadEpisode(episodeId).catchError((_) {});
        }
      });
    } catch (e) {
      print('❌ Episode advance failed: $e');
      AppLogger.instance.error('Podcast episode advance failed: $e');
      // Critical: clear buffering so the UI doesn't get stuck on a
      // forever-spinner if setAudioSource threw or the source URL
      // 403/404'd. Otherwise users hit "play" and get a silent
      // spinner with no recovery path.
      if (_isBuffering) {
        _isBuffering = false;
        notifyListeners();
      }
    } finally {
      _isAdvancingPodcast = false;
    }
  }

  /// Start (or restart) the 15-second podcast progress timer.
  ///
  /// Responsibilities:
  ///   1. Save played_position to the backend every 15s.
  ///   2. Mark episode completed when position > 90% of duration.
  ///   3. Auto-advance early if the current feed has outro_skip_seconds
  ///      > 0 and we're within that window of the end. Equivalent to the
  ///      user hitting "skip to next" at the right moment.
  ///
  /// Prior to this helper there were four copies of the timer creation
  /// scattered across resume, restore, advance, and initial play paths —
  /// all near-identical. Extracted here so the outro logic only has to
  /// live in one place.
  void _startPodcastProgressTimer() {
    _podcastProgressTimer?.cancel();
    _podcastProgressTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      final epId = _currentEpisodeId;
      if (epId == null || _position.inSeconds <= 0) return;
      final dur = _duration.inSeconds;
      final pos = _position.inSeconds;

      // Outro auto-advance. Guarded so we only fire once per episode.
      if (!_didApplyOutroAdvance &&
          _podcastOutroSkipSeconds > 0 &&
          dur > 0 &&
          pos >= dur - _podcastOutroSkipSeconds) {
        _didApplyOutroAdvance = true;
        print('🎙️ Auto-skip outro: advancing early with '
            '${dur - pos}s left');
        _advanceToNextPodcastEpisode();
        return;
      }

      _apiService.updateEpisodeProgress(
        epId,
        pos,
        isCompleted: dur > 0 && pos > dur * 0.9,
      ).catchError((e) => print('Podcast progress save error: $e'));
    });
  }

  /// Update podcast episode tracking when queue advances to next episode
  void _updatePodcastEpisodeFromSong(Song song) {
    if (!song.isPodcast) return;
    final newEpisodeId = song.podcastEpisodeId;
    if (newEpisodeId == null) return;

    // Mark previous episode as completed before switching
    if (_currentEpisodeId != null && _currentEpisodeId != newEpisodeId) {
      _apiService.updateEpisodeProgress(
        _currentEpisodeId!,
        _duration.inSeconds > 0 ? _duration.inSeconds : _position.inSeconds,
        isCompleted: true,
      ).catchError((e) => print('⚠️ Mark previous episode completed failed: $e'));
    }
    _currentEpisodeId = newEpisodeId;
    _podcastEpisodeTitle = song.title;
    // New episode → reset per-episode auto-skip guards and restart
    // the timer. Intro skip doesn't re-fire on queue advance (user
    // would hear the first N seconds before the skip trigger catches
    // up — not worth it).
    _didApplyIntroSkip = true;
    _didApplyOutroAdvance = false;
    _startPodcastProgressTimer();
  }

  Future<void> playFromQueue(int index) async {
    if (index < 0 || index >= _queue.length) return;
    // Only clear podcast mode if switching to real music.
    if (!_queue[index].isPodcast) {
      _clearPodcastMode();
    }

    // Track skip if leaving the current song early.
    if (_currentSong != null) {
      final pct = _duration.inSeconds > 0
          ? (_position.inSeconds / _duration.inSeconds * 100).round()
          : 0;
      if (pct < 80) {
        _apiService.trackSkip(_currentSong!.id).catchError((e) {});
      }
    }

    _currentIndex = index;
    _currentSong = _queue[index];
    _crossfadeTriggered = false;

    if (_currentSong!.isPodcast) {
      _updatePodcastEpisodeFromSong(_currentSong!);
    }

    // Chromecast: load the new song on the cast device.
    if (isCasting) {
      _position = Duration.zero;
      if (_currentSong!.duration > 0) {
        _duration = Duration(seconds: _currentSong!.duration);
      }
      _isPlaying = true;
      await _castService!.loadAndPlay(_currentSong!,
          quality: _streamQuality, podcastArtworkUrl: _podcastArtworkUrl);
      savePlaybackState();
      notifyListeners();
      return;
    }

    // Podcast queue jump: resolve a fresh proxy URL + played_position (the
    // Song.filePath may carry a CDN URL whose TTL expired and would 403),
    // then load it directly. No lookahead — podcasts advance via onCompleted.
    if (_currentSong!.isPodcast) {
      final episodeId = _currentSong!.podcastEpisodeId ?? -_currentSong!.id;
      final freshUrl = _apiService.getRssStreamUrl(episodeId);
      int startSeconds = _currentSong!.playedPosition;
      try {
        final epData = await _apiService.getRssEpisode(episodeId);
        final fresh = epData['episode'] ?? epData;
        final freshPos = fresh['played_position'];
        if (freshPos is int) {
          startSeconds = freshPos;
        } else if (freshPos is num) {
          startSeconds = freshPos.toInt();
        }
      } catch (_) {/* fall back to stale played_position from the queue Song */}

      try {
        _position =
            startSeconds > 0 ? Duration(seconds: startSeconds) : Duration.zero;
        await _active.loadCurrent(
          EngineItem(
            id: _currentSong!.id,
            url: freshUrl,
            isPodcast: true,
            knownDuration: _currentSong!.duration > 0
                ? Duration(seconds: _currentSong!.duration)
                : null,
            title: _currentSong!.title,
            artist: _currentSong!.artistName,
            album: _currentSong!.albumTitle,
            artUri: _podcastArtworkUrl,
          ),
          startPosition: _position,
          autoPlay: true,
        );
        _hasLoadedCurrent = true;
        _lookaheadIndex = null;
        await _active.setNext(null);
        _applyVolume();
        _didApplyIntroSkip = false;
        _didApplyOutroAdvance = false;
        _startPodcastProgressTimer();
        print('🎙️ Podcast queue jump: ${_currentSong!.title} (start=${startSeconds}s)');
      } catch (e) {
        AppLogger.instance.error('Podcast queue jump failed: $e');
        _isBuffering = false;
      }

      savePlaybackState();
      notifyListeners();
      return;
    }

    // Music: app-driven load of the new current + pre-buffered lookahead.
    await _playCurrentIndex(autoPlay: true);
    _prefetchNextSong();
    print('🎵 Jumped to: ${_currentSong!.title}');
    savePlaybackState();
    notifyListeners();
  }

  // Clear the queue and stop playback
  void clearQueue() {
    _queue = [];
    _originalQueue = [];
    _currentIndex = 0;
    _lookaheadIndex = null;
    _currentSong = null;
    _active.stop();
    _hasLoadedCurrent = false;
    _stopSaveTimer();
    savePlaybackState();
    notifyListeners();
  }

  // Remove a song from the queue by index
  void removeFromQueue(int index) {
    if (index < 0 || index >= _queue.length) return;
    if (index == _currentIndex) return;

    _queue.removeAt(index);
    if (index < _currentIndex) {
      _currentIndex--;
    }
    // App is the source of truth — just refresh the engine's lookahead in
    // case the removed item was the upcoming one. No player playlist to keep
    // in sync anymore. (_originalQueue preserves the source album order.)
    if (!isCasting) _refreshLookahead();
    notifyListeners();
  }

  // Reorder queue
  void reorderQueue(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    if (oldIndex < 0 ||
        oldIndex >= _queue.length ||
        newIndex < 0 ||
        newIndex >= _queue.length) {
      return;
    }

    final song = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, song);

    if (oldIndex == _currentIndex) {
      _currentIndex = newIndex;
    } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
      _currentIndex--;
    } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
      _currentIndex++;
    }
    // Refresh lookahead in case the move changed what comes next.
    if (!isCasting) _refreshLookahead();
    notifyListeners();
  }

  // ── Party mode (host side) ─────────────────────────────────────────
  // Guests join via the TV's QR and add tracks through the backend; the
  // adds arrive here over the existing socket (device_sync_service) and
  // land at the END of the real queue with attribution. This phone stays
  // the queue authority — party adds flow into UP_NEXT like everything
  // else, so they survive a dead sender too.
  bool _partyActive = false;
  String? _partyCode;
  String? _partyQrUrl;
  String? _partyJoinUrl;
  final Map<int, String> _partyAttribution = {}; // songId -> guest name

  bool get partyActive => _partyActive;
  String? get partyCode => _partyCode;
  String? get partyQrUrl => _partyQrUrl;
  String? get partyJoinUrl => _partyJoinUrl;
  String? partyAttributionFor(int songId) => _partyAttribution[songId];

  /// UI hook: "Kayla added Panama" toast material.
  void Function(String guest, String title)? onPartyTrackAdded;
  void Function(String guest)? onPartyGuestJoined;

  Future<bool> startParty() async {
    try {
      final r = await _apiService.startParty();
      _partyActive = true;
      _partyCode = r['code'] as String?;
      _partyQrUrl = r['qr_url'] as String?;
      _partyJoinUrl = r['join_url'] as String?;
      _partyAttribution.clear();
      if (isCasting) {
        _castService?.sendPartyMode(
            active: true, qrUrl: _partyQrUrl, code: _partyCode);
      }
      AppLogger.instance.info('🎉 [Party] Started — code=$_partyCode');
      notifyListeners();
      return true;
    } catch (e) {
      AppLogger.instance.warning('🎉 [Party] Start failed: $e');
      return false;
    }
  }

  Future<void> endParty() async {
    try {
      await _apiService.endParty();
    } catch (e) {
      AppLogger.instance.warning('🎉 [Party] End call failed: $e');
    }
    _partyActive = false;
    _partyCode = null;
    _partyQrUrl = null;
    _partyJoinUrl = null;
    if (isCasting) _castService?.sendPartyMode(active: false);
    AppLogger.instance.info('🎉 [Party] Ended');
    notifyListeners();
  }

  /// Socket relay target for guest adds ('party_track_added').
  Future<void> handlePartyTrackAdded(Map<String, dynamic> data) async {
    if (!_partyActive || data['code'] != _partyCode) return;
    final songId = (data['song_id'] as num?)?.toInt();
    final guest = (data['guest'] as String?) ?? 'Guest';
    if (songId == null) return;
    try {
      final song = await _apiService.getSongById(songId);
      final alreadyAhead = _queue.indexWhere((s) => s.id == songId);
      if (alreadyAhead > _currentIndex) {
        // Already queued and not yet played — attribute, don't duplicate.
        _partyAttribution[songId] = guest;
      } else {
        addToQueue(song);
        _partyAttribution[songId] = guest;
      }
      AppLogger.instance
          .info('🎉 [Party] $guest added "${song.title}" (id=$songId)');
      onPartyTrackAdded?.call(guest, song.title);
      // Keep the TV's self-advance list current with the new tail.
      if (isCasting) _castService?.refreshUpNext();
      savePlaybackState();
      notifyListeners();
    } catch (e) {
      AppLogger.instance.warning('🎉 [Party] Add failed for song $songId: $e');
    }
  }

  // Add to queue
  void addToQueue(Song song) {
    _queue.add(song);
    if (_originalQueue.isNotEmpty) _originalQueue.add(song);
    // If this song is now the immediate next, the engine needs it pre-buffered.
    if (!isCasting) _refreshLookahead();
    notifyListeners();
  }

  /// Queue a podcast episode for "Listen Later" — adds to the end of the
  /// current queue if one exists, or creates a single-item queue. Doesn't
  /// start playback. Accepts the episode plus feed context so we can
  /// populate the virtual podcast Song correctly (author, show name,
  /// feed id for the podcastFeedId field added in Phase 3a).
  void enqueuePodcastEpisode(
    RssEpisode episode, {
    required int feedId,
    required String author,
    required String showName,
    String? artworkUrl,
  }) {
    final url = episode.audioUrl ?? _apiService.getRssStreamUrl(episode.id);
    final song = Song(
      id: -episode.id,
      title: episode.title,
      artistId: 0,
      artistName: author,
      albumId: -feedId,
      albumTitle: showName,
      trackNumber: 0,
      duration: episode.audioDuration ?? 0,
      filePath: url,
      fileSize: episode.audioSize ?? 0,
      bitrate: 0,
      sourceType: 'podcast',
      podcastFeedId: feedId,
      podcastEpisodeId: episode.id,
      playedPosition: episode.playedPosition,
      isCompleted: episode.isCompleted,
    );
    // If nothing's playing, fall back to playing immediately so the user
    // doesn't just "queue and nothing happens". Matches typical "Listen
    // Later" behavior when the queue is empty.
    if (_currentSong == null) {
      playPodcastEpisode(
        episode,
        url,
        artworkUrl: artworkUrl,
        podcastAuthor: author,
        podcastTitle: showName,
        feedId: feedId,
        allEpisodes: [episode],
      );
      return;
    }
    addToQueue(song);
  }

  // Add to play next.
  //
  // THE STEAMROLL BUG, now structurally impossible: "play album next" /
  // "add to queue next" used to mutate only the visible `_queue`, never the
  // player's real playlist — so the player advanced to the ORIGINAL next
  // track when the current song ended. With the 2-slot engine the app owns
  // the queue and the only thing the player holds is the lookahead, which
  // _refreshLookahead re-points at _queue[_currentIndex+1] = the inserted
  // song. There is no second playlist to drift out of sync.
  void addToQueueNext(Song song) {
    if (_queue.isEmpty) {
      addToQueue(song);
      return;
    }
    final insertIndex = _currentIndex + 1;
    _queue.insert(insertIndex, song);
    _originalQueue.add(song);
    if (!isCasting) _refreshLookahead();
    notifyListeners();
  }

  // Add multiple to play next
  void addMultipleToQueueNext(List<Song> songs) {
    if (_queue.isEmpty) {
      addMultipleToQueue(songs);
      return;
    }
    final insertIndex = _currentIndex + 1;
    // Insert in reverse so the final _queue order matches `songs` order.
    for (int i = songs.length - 1; i >= 0; i--) {
      _queue.insert(insertIndex, songs[i]);
    }
    _originalQueue.addAll(songs);
    if (!isCasting) _refreshLookahead();
    notifyListeners();
  }

  // Add multiple to queue
  void addMultipleToQueue(List<Song> songs) {
    _queue.addAll(songs);
    if (_originalQueue.isNotEmpty) _originalQueue.addAll(songs);
    if (!isCasting) _refreshLookahead();
    notifyListeners();
  }

  // Next song
  Future<void> next() async {
    if (isControlling) {
      _syncService.sendRemoteCommand('next');
      return;
    }
    // Joined a headless cast: the backend owns that queue.
    if (isCasting &&
        _castService!.joinedExisting &&
        _castService!.receiverHeadless) {
      await _apiService.castJump(next: true);
      return;
    }
    _cancelCrossfade(); // Cancel any in-progress crossfade
    _crossfadeTriggered = false;

    // Track skip / complete for the outgoing song.
    if (_currentSong != null) {
      final pct = _duration.inSeconds > 0
          ? (_position.inSeconds / _duration.inSeconds * 100).round()
          : 0;
      if (pct < 80) {
        _apiService.trackSkip(_currentSong!.id).catchError((e) {});
      } else {
        _apiService.trackComplete(_currentSong!.id, pct).catchError((e) {});
      }
    }

    // Repeat-one: restart the current song.
    if (_repeatMode == RepeatMode.one) {
      if (isCasting) {
        _castService!.seekTo(Duration.zero);
      } else {
        await _active.seek(Duration.zero);
      }
      savePlaybackState();
      return;
    }

    // Compute the next index (repeat-all wraps to 0).
    final int target;
    if (_currentIndex < _queue.length - 1) {
      target = _currentIndex + 1;
    } else if (_repeatMode == RepeatMode.all && _queue.isNotEmpty) {
      target = 0;
    } else {
      return; // End of queue, no repeat.
    }
    _currentIndex = target;
    _currentSong = _queue[target];
    _position = Duration.zero;
    _lastSongChangeTime = DateTime.now();
    if (_currentSong!.duration > 0) {
      _duration = Duration(seconds: _currentSong!.duration);
    }

    // Chromecast: manage the index ourselves, load on the cast device.
    if (isCasting) {
      _isPlaying = true;
      _syncLocalPlayerIndex(_currentIndex);
      notifyListeners();
      _apiService.trackPlay(_currentSong!.id).catchError((e) {});
      await _castService!.loadAndPlay(_currentSong!,
          quality: _streamQuality, podcastArtworkUrl: _podcastArtworkUrl);
      savePlaybackState();
      return;
    }

    // App-driven: hard-load the new current into slot 0, pre-buffer the next.
    await _playCurrentIndex(autoPlay: true);
    notifyListeners();
    savePlaybackState();
  }

  // Previous song
  Future<void> previous({bool force = false}) async {
    if (isControlling) {
      _syncService.sendRemoteCommand('previous', args: {'force': force});
      return;
    }
    // Joined a headless cast: the backend owns that queue.
    if (isCasting &&
        _castService!.joinedExisting &&
        _castService!.receiverHeadless) {
      await _apiService.castJump(next: false);
      return;
    }
    _cancelCrossfade(); // Cancel any in-progress crossfade
    _crossfadeTriggered = false;

    // Fresh app open: nothing is loaded into the engine yet (restore only sets
    // metadata), so the restart-via-seek paths below would no-op until the
    // first play. Load the current song at 0 so "previous" restarts it
    // immediately on open (autoPlay mirrors the current paused/playing state).
    // NOT while casting — this would start LOCAL playback on top of the cast
    // (double audio). When casting the isCasting branches below handle it.
    if (!_hasLoadedCurrent && _currentSong != null && !isCasting) {
      // "Previous to restart" means play from the top, even from a fresh open.
      await _playCurrentIndex(startPosition: Duration.zero, autoPlay: true);
      return;
    }

    // Repeat-one (unless forced): restart the current song.
    if (_repeatMode == RepeatMode.one && !force) {
      if (isCasting) {
        _castService!.seekTo(Duration.zero);
      } else {
        await _active.seek(Duration.zero);
      }
      return;
    }

    // More than 3s in: restart current (unless forced, e.g. artwork swipe).
    if (_position.inSeconds > 3 && !force) {
      if (isCasting) {
        _castService!.seekTo(Duration.zero);
      } else {
        await _active.seek(Duration.zero);
      }
      return;
    }

    // Track skip for the outgoing song.
    if (_currentSong != null) {
      final pct = _duration.inSeconds > 0
          ? (_position.inSeconds / _duration.inSeconds * 100).round()
          : 0;
      if (pct < 80) {
        _apiService.trackSkip(_currentSong!.id).catchError((e) {});
      }
    }

    // Compute the previous index (repeat-all wraps to the end).
    final int target;
    if (_currentIndex > 0) {
      target = _currentIndex - 1;
    } else if (_repeatMode == RepeatMode.all && _queue.isNotEmpty) {
      target = _queue.length - 1;
    } else {
      // At the first song, no repeat — just restart it.
      if (isCasting) {
        _castService!.seekTo(Duration.zero);
      } else {
        await _active.seek(Duration.zero);
      }
      return;
    }
    _currentIndex = target;
    _currentSong = _queue[target];
    _position = Duration.zero;
    _lastSongChangeTime = DateTime.now();
    if (_currentSong!.duration > 0) {
      _duration = Duration(seconds: _currentSong!.duration);
    }

    // Chromecast: load on the cast device.
    if (isCasting) {
      _isPlaying = true;
      _syncLocalPlayerIndex(_currentIndex);
      notifyListeners();
      _apiService.trackPlay(_currentSong!.id).catchError((e) {});
      await _castService!.loadAndPlay(_currentSong!,
          quality: _streamQuality, podcastArtworkUrl: _podcastArtworkUrl);
      savePlaybackState();
      return;
    }

    // App-driven: hard-load the new current into slot 0, pre-buffer the next.
    await _playCurrentIndex(autoPlay: true);
    notifyListeners();
    savePlaybackState();
  }

  // Toggle shuffle
  Future<void> toggleShuffle() async {
    if (isControlling) {
      _syncService.sendRemoteCommand('toggle_shuffle');
      return;
    }
    _isShuffled = !_isShuffled;
    final currentSongId = _currentSong?.id;
    bool currentSongMoved = false;

    if (_isShuffled) {
      // Save original order, shuffle, then keep the currently-playing song at
      // the front so it doesn't restart. The engine isn't touched — the
      // current track keeps playing; only the lookahead is recomputed below.
      _originalQueue = List.from(_queue);
      _queue.shuffle();
      if (currentSongId != null) {
        final idx = _queue.indexWhere((s) => s.id == currentSongId);
        if (idx > 0) {
          final song = _queue.removeAt(idx);
          _queue.insert(0, song);
          currentSongMoved = true;
        }
        _currentIndex = 0;
        if (_queue.isNotEmpty) _currentSong = _queue[0];
      }
      print('🔀 Queue shuffled: ${_queue.length} songs (current track untouched)');
    } else {
      // Restore original order; relocate the current song's index.
      _queue = List.from(_originalQueue);
      if (_currentSong != null) {
        _currentIndex = _queue.indexWhere((s) => s.id == _currentSong!.id);
        if (_currentIndex < 0) _currentIndex = 0;
      }
      print('🔀 Queue unshuffled');
    }

    if (isCasting) {
      // Cast keeps playing the current song; only reload if its position in
      // the (new) order changed so the device's next/prev matches.
      if (currentSongMoved && _currentSong != null) {
        _castService!.loadAndPlay(_currentSong!,
            quality: _streamQuality, podcastArtworkUrl: _podcastArtworkUrl);
      }
    } else {
      // Local: the playing track is in slot 0 untouched — just re-point the
      // engine's lookahead at the new next song.
      await _refreshLookahead();
    }

    savePlaybackState();
    notifyListeners();
  }

  void _startPlayWatchdog() {
    _playWatchdog?.cancel();
    final positionBefore = _position;

    _playWatchdog = Timer(const Duration(seconds: 4), () {
      // If position hasn't advanced, the connection is stale — rebuild
      if (_isPlaying &&
          (_position - positionBefore).inMilliseconds.abs() < 500) {
        print('🔄 Stale connection detected — rebuilding playlist');
        _rebuildPlaylistKeepingPosition();
      }
    });
  }

  /// Track that the cast session changed songs. We DON'T seek the local player
  /// because that triggers ExoPlayer to download the stream (causing buffering).
  /// Instead, we just update the internal state so _currentSong/_currentIndex
  /// are correct. The local player will be synced when casting stops.
  void _syncLocalPlayerIndex(int index) {
    _lastPlaylistIndex = index;
    print('📺 [Cast] State synced to index $index');
  }

  /// Watchdog-driven rebuild: position stalled despite playing, so the
  /// connection is probably stale. Reload current at the saved position via
  /// the engine — kills the stale stream and starts a fresh one.
  Future<void> _rebuildPlaylistKeepingPosition() async {
    // While casting (or rejoining at launch), _isPlaying=true with a
    // frozen local position is NORMAL (the TV is the one playing) —
    // rebuilding here would start local audio on top of the cast.
    if (_castOwnsAudio) return;
    if (_queue.isEmpty) return;
    final savedPosition = _position;
    final wasPlaying = _isPlaying;
    await _playCurrentIndex(autoPlay: wasPlaying, startPosition: savedPosition);
  }

  // Toggle repeat
  void toggleRepeat() {
    if (isControlling) {
      _syncService.sendRemoteCommand('toggle_repeat');
      return;
    }
    switch (_repeatMode) {
      case RepeatMode.off:
        _repeatMode = RepeatMode.all;
        break;
      case RepeatMode.all:
        _repeatMode = RepeatMode.one;
        break;
      case RepeatMode.one:
        _repeatMode = RepeatMode.off;
        break;
    }

    // Repeat is entirely app-side now: the engine NEVER loops on its own
    // (PlaylistMode.none / no LoopMode). _computeNextIndex encodes the rule —
    // repeat-one clears the lookahead (onCompleted reseeks), repeat-all wraps
    // the lookahead to index 0 at end-of-queue. So changing the mode just
    // needs a lookahead refresh. Podcasts advance manually (no lookahead);
    // cast manages its own queue.
    if (!isPlayingPodcast && !isCasting) {
      _refreshLookahead();
    }
    savePlaybackState();
    notifyListeners();
  }

  // Crossfade settings
  Future<void> setCrossfadeEnabled(bool enabled) async {
    _crossfadeEnabled = enabled;
    if (!enabled) _cancelCrossfade();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('crossfade_enabled', enabled);
    notifyListeners();
  }

  Future<void> setCrossfadeDuration(Duration duration) async {
    _crossfadeDuration = duration;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('crossfade_duration_seconds', duration.inSeconds);
    notifyListeners();
  }

  Future<void> _loadCrossfadeSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _crossfadeEnabled = prefs.getBool('crossfade_enabled') ?? true;
    final seconds = prefs.getInt('crossfade_duration_seconds') ?? 5;
    _crossfadeDuration = Duration(seconds: seconds);
  }

  // Determine next song index for crossfade (returns null if no next song)
  int? _getNextCrossfadeIndex() {
    if (_useJustAudio) {
      // For just_audio: find current song in _queue (shuffled order) and return the next
      if (_currentSong == null) return null;
      final currentQueueIdx =
          _queue.indexWhere((s) => s.id == _currentSong!.id);
      if (currentQueueIdx >= 0 && currentQueueIdx < _queue.length - 1) {
        return currentQueueIdx + 1;
      } else if (_repeatMode == RepeatMode.all && currentQueueIdx >= 0) {
        return 0;
      }
    } else {
      // For media_kit, queue index is straightforward
      if (_currentIndex < _queue.length - 1) {
        return _currentIndex + 1;
      } else if (_repeatMode == RepeatMode.all) {
        return 0;
      }
    }
    return null;
  }

  // ── Crossfade (dual-deck ping-pong) ────────────────────────────────
  // Built on the two persistent A/B decks. When the active song nears its
  // end we load the next song into the INACTIVE deck at volume 0, play it,
  // and run an equal-power volume fade (active↓ / inactive↑). When the fade
  // completes we flip _activeDeckSlot, re-point the listeners via
  // _setupDeckListeners(_active), and promote the queue state. The old design
  // had two code paths (clean mobile ping-pong + a hacky desktop "new player +
  // rebuild playlist"); the 2-slot engine collapses both into this one path,
  // so desktop gets the clean approach too. Crossfade is mutually exclusive
  // with gapless per-transition: at start we clear the active deck's lookahead
  // so the engine can't ALSO roll slot0→slot1 underneath the fade.

  // Trigger gate — called from the active deck's position listener every tick.
  void _maybeStartCrossfade(Duration position) {
    if (!_crossfadeEnabled ||
        _isCrossfading ||
        _crossfadeTriggered ||
        isPlayingPodcast ||
        _repeatMode == RepeatMode.one) {
      return;
    }
    // Cooldown: a stale position reading right after a track change must not
    // trip the fade for the freshly-started song.
    if (DateTime.now().difference(_lastSongChangeTime).inSeconds < 5) return;
    // Only crossfade songs comfortably longer than the fade itself, else the
    // fade would eat most of the track.
    if (_duration.inSeconds <= _crossfadeDuration.inSeconds * 2) return;
    final remainingMs = _duration.inMilliseconds - position.inMilliseconds;
    if (remainingMs > 0 && remainingMs <= _crossfadeDuration.inMilliseconds) {
      _startCrossfade();
    }
  }

  void _startCrossfade() {
    final nextIndex = _computeNextIndex();
    if (nextIndex == null || nextIndex < 0 || nextIndex >= _queue.length) {
      return; // end of queue, no repeat — let it end naturally via onCompleted
    }

    _isCrossfading = true;
    _crossfadeTriggered = true;
    _crossfadeNextIndex = nextIndex;
    final nextSong = _queue[nextIndex];
    _crossfadeNextSong = nextSong;
    final startVolume = _calculateEffectiveVolume();

    // Stop the active deck's gapless lookahead from rolling underneath the
    // fade. Crossfade IS the transition now — the engine must not also advance.
    _active.setNext(null);
    _lookaheadIndex = null;

    AppLogger.instance.info(
      '[player.crossfade] start "${_currentSong?.title}" → "${nextSong.title}" '
      '(${_crossfadeDuration.inSeconds}s)',
    );

    // Load the next song into the idle (inactive) deck at silence, start it,
    // then wait until it actually produces audio before fading — so we never
    // fade into a still-buffering stream.
    AppLogger.instance.info(
      '[player.crossfade] incoming deck = inactive (active slot=$_activeDeckSlot)',
    );

    final incoming = _inactive;
    incoming.setVolume(0);
    incoming
        .loadCurrent(_engineItemFor(nextSong), autoPlay: true)
        .then((_) {
      if (!_isCrossfading) return; // cancelled while loading
      // open()/loadCurrent can reset the player volume to full — force the
      // incoming deck back to silence before the fade takes over, so it never
      // blasts at full volume in the gap before the first fade step.
      incoming.setVolume(0);
      bool fadeStarted = false;
      void kick() {
        if (fadeStarted || !_isCrossfading) return;
        fadeStarted = true;
        _crossfadeBufferSub?.cancel();
        _crossfadeBufferSub = null;
        _beginCrossfadeTimer(nextIndex, nextSong, startVolume);
      }

      _crossfadeBufferSub = incoming.positionStream.listen((pos) {
        if (pos.inMilliseconds > 0) kick();
      });
      // Safety net: if the deck never reports a position (some opus streams are
      // slow to tick), start the fade anyway after 4s.
      Future.delayed(const Duration(seconds: 4), kick);
    }).catchError((e) {
      AppLogger.instance.error('[player.crossfade] incoming load failed: $e');
      _cancelCrossfade();
    });
  }

  /// Runs the equal-power volume fade between the active (outgoing) deck and
  /// the inactive (incoming) deck, then completes the swap.
  void _beginCrossfadeTimer(int nextIndex, Song nextSong, double startVolume) {
    if (!_isCrossfading) return; // cancelled while waiting for buffer

    // Flip the UI to the incoming song (title/art/position/duration getters
    // already read the inactive deck + _crossfadeNext* while this is true).
    _crossfadeUITransitioned = true;
    notifyListeners();

    const fadeSteps = 30;
    // Size the fade to the outgoing song's actual remaining time, clamped into
    // [1s, crossfadeDuration]. _position/_duration still track the OUTGOING
    // deck here (the active deck's listener owns them until the swap).
    final remainingMs = _duration.inMilliseconds - _position.inMilliseconds;
    final fadeDurationMs = remainingMs > 0
        ? remainingMs.clamp(1000, _crossfadeDuration.inMilliseconds)
        : _crossfadeDuration.inMilliseconds;
    final stepDuration = Duration(milliseconds: fadeDurationMs ~/ fadeSteps);
    int currentStep = 0;

    _crossfadeTimer = Timer.periodic(stepDuration, (timer) {
      currentStep++;
      final progress = (currentStep / fadeSteps).clamp(0.0, 1.0);
      // Equal-power (sin/cos) curve keeps perceived loudness constant through
      // the fade instead of dipping in the middle. Engine setVolume is 0..1.
      final angle = progress * pi / 2;
      final outVol = startVolume * cos(angle);
      final inVol = startVolume * sin(angle);
      _active.setVolume(outVol); // outgoing
      _inactive.setVolume(inVol); // incoming
      // Diagnostic: log both decks' real play-state + position + applied volume
      // at the start, middle, and end of the fade. If both show playing=true
      // with advancing positions but only one is audible, it's an audio-device
      // mixing problem (exclusive output), not a fade-logic problem.
      if (currentStep == 1 ||
          currentStep == fadeSteps ~/ 2 ||
          currentStep >= fadeSteps) {
        AppLogger.instance.info(
          '[player.crossfade.fade] step=$currentStep/$fadeSteps '
          'out(slot=$_activeDeckSlot playing=${_active.playing} '
          'pos=${_active.position.inSeconds}s vol=${outVol.toStringAsFixed(2)}) '
          'in(playing=${_inactive.playing} '
          'pos=${_inactive.position.inSeconds}s vol=${inVol.toStringAsFixed(2)})',
        );
      }
      notifyListeners(); // keep the incoming song's position flowing to the UI

      if (currentStep >= fadeSteps) {
        timer.cancel();
        _crossfadeTimer = null;
        _completeCrossfade(nextIndex, nextSong);
      }
    });
  }

  /// Finish the swap: the incoming deck becomes active, the outgoing deck goes
  /// idle (stopped, NOT disposed — it's reused for the next ping-pong).
  void _completeCrossfade(int nextIndex, Song nextSong) {
    if (_currentSong != null) {
      _apiService.trackComplete(_currentSong!.id, 100).catchError((e) {});
    }

    final outgoing = _active;

    // FLIP, then re-point the listeners at the now-active (incoming) deck. Doing
    // the re-point BEFORE stopping the outgoing deck means the outgoing deck no
    // longer has listeners when it stops — so its playing=false event can't
    // bleed into _isPlaying.
    _activeDeckSlot = _activeDeckSlot == 'a' ? 'b' : 'a';
    _setupDeckListeners(_active);
    outgoing.stop(); // releases its slots; deck instance persists

    // Promote queue state to the song we faded in.
    if (nextIndex >= _queue.length) {
      nextIndex = _queue.isEmpty ? 0 : _queue.length - 1;
    }
    if (_queue.isEmpty) {
      _isCrossfading = false;
      _crossfadeUITransitioned = false;
      return;
    }
    _currentIndex = nextIndex;
    _currentSong = _queue[_currentIndex];
    _duration = _active.duration.inMilliseconds > 0
        ? _active.duration
        : (_currentSong!.duration > 0
            ? Duration(seconds: _currentSong!.duration)
            : Duration.zero);
    _position = _active.position;
    _lastSongChangeTime = DateTime.now();
    // Re-anchor the stall watchdog onto the fresh deck.
    _lastObservedPosition = _position;
    _lastPositionAdvance = DateTime.now();

    _apiService.trackPlay(_currentSong!.id).catchError((e) {});

    // Reset crossfade state for the next cycle.
    _isCrossfading = false;
    _crossfadeUITransitioned = false;
    _crossfadeNextIndex = null;
    _crossfadeNextSong = null;
    _crossfadeTriggered = false;
    _isBuffering = false;

    _applyVolume(); // full effective volume (+ replaygain) on the new active deck
    _loopPointA = null;
    _loopPointB = null;

    AppLogger.instance.info(
      '[player.crossfade] complete → queueIdx=$_currentIndex '
      'song="${_currentSong!.title}"',
    );

    // Hand the new active deck its next lookahead (gapless until the next
    // crossfade triggers, or a pure gapless roll if that transition isn't faded).
    _refreshLookahead();

    notifyListeners();
    savePlaybackState();
  }

  // Cancel an in-progress (or pending) crossfade — manual skip, pause, seek,
  // new queue, etc. Stops the incoming deck (kept alive for the next cycle),
  // snaps the active deck back to full volume, and clears all fade state.
  void _cancelCrossfade() {
    if (!_isCrossfading &&
        _crossfadeTimer == null &&
        _crossfadeBufferSub == null) {
      return;
    }
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;
    _crossfadeBufferSub?.cancel();
    _crossfadeBufferSub = null;
    _isCrossfading = false;
    _crossfadeUITransitioned = false;
    _crossfadeTriggered = false;
    _crossfadeNextIndex = null;
    _crossfadeNextSong = null;
    _isBuffering = false;
    // Stop the incoming deck (don't dispose — it persists for the next cycle)
    // and restore the active deck to its proper volume.
    try {
      _inactive.stop();
    } catch (_) {}
    _applyVolume();
    notifyListeners();
  }

  Future<void> _setupAudioSession() async {
    if (!_useJustAudio) return; // Only needed on mobile

    try {
      final session = await AudioSession.instance;

      // Configure the session for music playback
      await session.configure(const AudioSessionConfiguration.music());
      print('✅ [Mobile] Audio session configured successfully');

      // Listen for "becoming noisy" events (Bluetooth disconnect, headphones unplug).
      // Skipped while casting — the TV's audio output is unaffected by phone-side
      // headphone/BT events.
      session.becomingNoisyEventStream.listen((_) {
        if (isCasting) {
          print('🔊 [AudioSession] BECOMING NOISY — ignored (casting)');
          return;
        }
        print('🔊 [AudioSession] BECOMING NOISY — pausing playback (BT disconnect / headphone unplug)');
        if (_isPlaying) {
          _active.pause();
        }
      });

      // Listen for audio interruptions (phone calls, navigation prompts, notifications).
      //
      // While casting we ignore interruptions entirely: the TV is its own
      // audio system, and the local player isn't producing sound. Pausing
      // the local player here is harmless, but the old code also restored
      // playback on the local player after the interruption ended — which
      // would start two audio outputs (phone + TV) running simultaneously.
      // The MediaSession is also marked as REMOTE while casting (see
      // NASRadioAudioHandler), so Android shouldn't send us interruption
      // events at all — but this is defense-in-depth.
      bool _wasPlayingBeforeInterruption = false;
      double? _volumeBeforeDuck;
      session.interruptionEventStream.listen((event) {
        if (isCasting) {
          print('🔊 [AudioSession] Interruption ignored (casting): begin=${event.begin}, type=${event.type}');
          return;
        }
        print('🔊 [AudioSession] Interruption: begin=${event.begin}, type=${event.type}, isPlaying=$_isPlaying');
        if (event.begin) {
          _wasPlayingBeforeInterruption = _isPlaying;
          if (event.type == AudioInterruptionType.duck) {
            // Duck: lower volume instead of pausing — Android expects this.
            _volumeBeforeDuck = _volume;
            duckVolume(0.2);
            print('🔊 [AudioSession] Ducking volume');
          } else {
            // Pause for full interruptions (phone calls, etc.)
            _active.pause();
          }
        } else {
          // Interruption ended
          if (event.type == AudioInterruptionType.duck) {
            if (_volumeBeforeDuck != null) {
              print('🔊 [AudioSession] Restoring volume after duck');
              restoreVolume();
              _volumeBeforeDuck = null;
            }
          } else if (_wasPlayingBeforeInterruption && _currentSong != null) {
            print('🔊 [AudioSession] Resuming after pause interruption');
            _active.play();
          }
          _wasPlayingBeforeInterruption = false;
        }
      });
    } catch (e, stackTrace) {
      print('❌ [Mobile] Audio session setup FAILED: $e');
      print('❌ Stack trace: $stackTrace');
      // Non-fatal — playback can still work without session management
    }
  }

  void _setupConnectivityMonitoring() {
    // Only monitor on mobile — desktop always uses lossless
    if (!_isMobile) {
      _streamQuality = 'lossless';
      return;
    }

    // Check initial connectivity
    Connectivity().checkConnectivity().then((results) {
      _updateQualityFromConnectivity(results);
    });

    // Listen for changes
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) {
      // A genuine network change (e.g. leaving home WiFi for cellular in the
      // truck) is the one moment the sticky-LAN cache should be bypassed:
      // the old host is likely unreachable now, so re-probe immediately
      // instead of letting requests fail against the dead LAN IP for ~2
      // cache cycles. Fire-and-forget; detectNetwork is self-guarding.
      ApiService.forceNetworkRecheck();
      _updateQualityFromConnectivity(results);
    });
  }

  /// Pre-transcode the next song in the queue so it's cached for instant playback
  void _prefetchNextSong() {
    if (_streamQuality == 'lossless') return;
    // Use the same next-song logic as crossfade so the prefetched song
    // matches what crossfade will actually play
    final nextIndex = _getNextCrossfadeIndex();
    if (nextIndex != null) {
      final nextSong = _queue[nextIndex];
      print('🔮 [prefetch] Prefetching song ${nextSong.id} (${nextSong.title}) at queue index $nextIndex');
      _apiService.prefetchSong(nextSong.id, quality: _streamQuality);
    }
  }

  void _updateQualityFromConnectivity(List<ConnectivityResult> results) {
    final oldQuality = _streamQuality;
    final onWifi = results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);

    print('📶 [Connectivity] Event fired: results=$results, oldQuality=$oldQuality, preference=$_qualityPreference');

    // Explicit user preference always takes priority (WiFi or cellular)
    if (_qualityPreference != 'auto') {
      _streamQuality = _qualityPreference;
      print('📶 Stream quality set to: $_streamQuality (user preference)');
    } else if (onWifi) {
      // Auto mode: lossless on WiFi/ethernet, AAC 320k on cellular
      _streamQuality = 'lossless';
      print('📶 Stream quality set to: $_streamQuality (WiFi → auto lossless)');
    } else if (results.contains(ConnectivityResult.mobile)) {
      _streamQuality = 'high'; // AAC 320kbps on cellular
      print('📶 Stream quality set to: $_streamQuality (cellular → auto high)');
    } else {
      _streamQuality = 'lossless'; // Default fallback
      print('📶 Stream quality set to: $_streamQuality (default)');
    }

    // If quality actually changed and we have something loaded on mobile,
    // reload at the current position with new-quality URLs. Never while
    // casting or rejoining — the rebuild's autoPlay flag mirrors the
    // TV's state.
    if (oldQuality != _streamQuality && _useJustAudio && _hasLoadedCurrent &&
        !_castOwnsAudio) {
      print('📶 Quality changed ($oldQuality → $_streamQuality) — reloading');
      _rebuildPlaylistForQualityChange();
    }
  }

  /// Rebuild the playlist with current _streamQuality URLs, preserving the
  /// current song position. Reloads the current song into the engine at the
  /// saved position — _refreshLookahead inside _playCurrentIndex re-points
  /// slot 1 with the new-quality URL too.
  Future<void> _rebuildPlaylistForQualityChange() async {
    // NOT while casting: _isPlaying mirrors the TV, so autoPlay:wasPlaying
    // would start LOCAL playback on a connectivity blip — the source of
    // the 2026-08-13 "phone hissing on every app open" incident (the
    // phone's decoder rendered the AAC+ station as static). And never for
    // stations at all: a live stream has no quality variants to rebuild.
    if (_castOwnsAudio) return;
    if (_currentSong?.isStation == true) return;
    if (_queue.isEmpty) return;
    final savedPosition = _position;
    final wasPlaying = _isPlaying;
    if (_currentIndex >= _queue.length) {
      _currentIndex = _queue.length - 1;
    }
    await _playCurrentIndex(autoPlay: wasPlaying, startPosition: savedPosition);
  }

  Future<void> setQualityPreference(String preference) async {
    if (!_isMobile) return; // Desktop always lossless
    _qualityPreference = preference;
    if (preference != 'auto') {
      _streamQuality = preference;
    } else {
      // Re-evaluate connectivity to set the right quality for auto mode
      final results = await Connectivity().checkConnectivity();
      _updateQualityFromConnectivity(results);
    }
    print('📶 Quality preference set to: $preference → stream quality: $_streamQuality');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('quality_preference', preference);

    // Rebuild the playlist with new quality URLs so the change takes effect immediately
    if (_isPlaying && _queue.isNotEmpty && !isCasting) {
      _rebuildPlaylistKeepingPosition();
    }
    notifyListeners();
  }

  // ReplayGain normalization
  Future<void> _loadReplayGainSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _replayGainEnabled = prefs.getBool('replaygain_enabled') ?? true;
    _targetLoudness = prefs.getDouble('replaygain_target') ?? 5500.0;
  }

  Future<void> setReplayGainEnabled(bool enabled) async {
    _replayGainEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('replaygain_enabled', enabled);
    _applyVolume(); // Re-apply volume with new setting
    notifyListeners();
  }

  Future<void> setTargetLoudness(double target) async {
    _targetLoudness = target.clamp(3000.0, 8000.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('replaygain_target', _targetLoudness);
    _applyVolume(); // Re-apply volume with new setting
    notifyListeners();
  }

  // Calculate effective volume based on ReplayGain.
  //
  // Prefers EBU R128 LUFS when available (post-2026-05-25 analyses).
  // Falls back to legacy Steven's-power-law math for songs analyzed
  // before the upgrade — the resume sweep backfills LUFS over time,
  // so the legacy path eventually goes away.
  double _calculateEffectiveVolume() {
    if (!_replayGainEnabled || _currentSong == null) {
      return _volume;
    }

    final lufs = _currentSong!.integratedLoudnessLufs;
    if (lufs != null && lufs.isFinite && lufs < 0) {
      // Real EBU R128 math: difference in LUFS == difference in dB
      // (the LUFS scale is calibrated to a 1 dB step). A song at
      // -10 LUFS played at -14 target needs -4 dB of gain.
      final gainDb = _targetLufs - lufs;
      // Convert dB to linear scale. 0 dB = 1.0, -6 dB ≈ 0.5, +6 dB ≈ 2.0.
      double linear = pow(10, gainDb / 20.0).toDouble();
      // Cap at 1.0 (no boost — would clip on already-hot tracks) and
      // floor at 0.3 (don't make anything inaudible if a song is
      // measured wildly loud by the analyzer).
      linear = linear.clamp(0.3, 1.0);
      return _volume * linear;
    }

    // Legacy path: Steven's-power-law ratio. Same math as before the
    // LUFS upgrade. Kept verbatim so unscored-yet songs sound the same
    // as they did pre-upgrade.
    final loudness = _currentSong!.loudness;
    if (loudness == null || loudness <= 0) {
      return _volume; // No loudness data at all — use raw volume.
    }
    double gain = _targetLoudness / loudness;
    gain = gain.clamp(0.3, 1.0);
    return _volume * gain;
  }

  // Apply volume to the active deck (with ReplayGain adjustment). The engine
  // normalizes the 0.0-1.0 value to the backend scale (media_kit 0-100).
  void _applyVolume() {
    final effectiveVolume = _calculateEffectiveVolume();
    _active.setVolume(effectiveVolume);

    if (_replayGainEnabled && _currentSong != null) {
      final lufs = _currentSong!.integratedLoudnessLufs;
      if (lufs != null) {
        final gainDb = _targetLufs - lufs;
        print(
          '🔊 ReplayGain[LUFS]: ${_currentSong!.title} - lufs: ${lufs.toStringAsFixed(2)}, gain: ${gainDb.toStringAsFixed(2)} dB, effective vol: ${(effectiveVolume * 100).toStringAsFixed(0)}%',
        );
      } else if (_currentSong!.loudness != null) {
        final gain = _targetLoudness / _currentSong!.loudness!;
        print(
          '🔊 ReplayGain[legacy]: ${_currentSong!.title} - loudness: ${_currentSong!.loudness}, gain: ${gain.toStringAsFixed(2)}, effective vol: ${(effectiveVolume * 100).toStringAsFixed(0)}%',
        );
      }
    }
  }

  // Volume
  Future<void> _loadVolume() async {
    final prefs = await SharedPreferences.getInstance();
    _volume = prefs.getDouble('volume') ?? 0.7;
    // Don't apply yet - wait until a song is loaded
  }

  Future<void> _loadQualityPreference() async {
    if (!_isMobile) return; // Desktop always lossless
    final prefs = await SharedPreferences.getInstance();
    _qualityPreference = prefs.getString('quality_preference') ?? 'auto';
    if (_qualityPreference != 'auto') {
      _streamQuality = _qualityPreference;
    }
  }

  Future<void> _saveVolume() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('volume', _volume);
  }

  Future<void> setVolume(double volume) async {
    if (isControlling) {
      _syncService.sendRemoteCommand('set_volume',
          args: {'volume': volume.clamp(0.0, 1.0)});
      return;
    }
    _volume = volume.clamp(0.0, 1.0);
    // Chromecast: also set cast volume
    if (isCasting) {
      _castService!.setCastVolume(_volume);
    }
    _applyVolume(); // Apply with ReplayGain adjustment
    await _saveVolume();
    notifyListeners();
  }

  double getVolume() => _volume;

  /// Duck volume for weather alerts — does NOT save to prefs
  void duckVolume(double factor) {
    _active.setVolume(_calculateEffectiveVolume() * factor);
  }

  /// Restore volume after ducking
  void restoreVolume() {
    _applyVolume();
  }

  // Playback speed. The engine tracks speed + pitch-correction together and
  // derives pitch (vinyl mode: pitch follows speed; normal: pitch at 1.0), so
  // we just push both to the active deck — no platform branch.
  Future<void> setPlaybackSpeed(double speed) async {
    if (isControlling) {
      _syncService.sendRemoteCommand('set_speed',
          args: {'speed': speed.clamp(0.5, 2.0)});
      return;
    }
    _playbackSpeed = speed.clamp(0.5, 2.0);
    await _active.setSpeed(_playbackSpeed);
    await _active.setPitchCorrectionEnabled(_pitchCorrectionEnabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('playback_speed', _playbackSpeed);
    notifyListeners();
  }

  Future<void> setPitchCorrectionEnabled(bool enabled) async {
    _pitchCorrectionEnabled = enabled;
    await _active.setSpeed(_playbackSpeed);
    await _active.setPitchCorrectionEnabled(enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('pitch_correction_enabled', enabled);
    notifyListeners();
  }

  Future<void> _loadPlaybackSpeed() async {
    final prefs = await SharedPreferences.getInstance();
    _playbackSpeed = prefs.getDouble('playback_speed') ?? 1.0;
    _pitchCorrectionEnabled = prefs.getBool('pitch_correction_enabled') ?? true;
    await _active.setSpeed(_playbackSpeed);
    await _active.setPitchCorrectionEnabled(_pitchCorrectionEnabled);
  }

  // Device & state persistence
  Future<void> _initializeDevice() async {
    final prefs = await SharedPreferences.getInstance();
    _deviceId = prefs.getString('device_id');

    if (_deviceId == null) {
      _deviceId = const Uuid().v4();
      await prefs.setString('device_id', _deviceId!);
    }

    String? savedName = prefs.getString('device_name');

    // If no saved name, detect from device info
    if (savedName == null || savedName == 'Windows Desktop' || savedName == 'Unknown Device') {
      try {
        final deviceInfo = DeviceInfoPlugin();
        if (Platform.isAndroid) {
          final android = await deviceInfo.androidInfo;
          // Use the user-set device name if available, otherwise model
          savedName = android.device.isNotEmpty ? android.model : 'Android Device';
        } else if (Platform.isWindows) {
          final windows = await deviceInfo.windowsInfo;
          savedName = windows.computerName;
        } else if (Platform.isIOS) {
          final ios = await deviceInfo.iosInfo;
          savedName = ios.name;
        } else if (Platform.isLinux) {
          final linux = await deviceInfo.linuxInfo;
          savedName = linux.prettyName;
        } else if (Platform.isMacOS) {
          final mac = await deviceInfo.macOsInfo;
          savedName = mac.computerName;
        }
      } catch (e) {
        print('⚠️ Could not detect device name: $e');
      }
      savedName ??= 'Unknown Device';
      await prefs.setString('device_name', savedName);
    }

    _deviceName = savedName;

    await restorePlaybackState();
  }

  Future<void> savePlaybackState({bool includeFullQueue = true}) async {
    if (_deviceId == null) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final deviceName = prefs.getString('device_name') ?? 'Windows Desktop';
      final queueIds = _queue.map((s) => s.id).toList();

      final originalQueueIds = _originalQueue.map((s) => s.id).toList();

      // Save locally for instant restore on next startup
      if (_currentSong != null) {
        // Save critical state first (song, position, podcast) — these are small
        // and must succeed even if the large queue save fails
        await prefs.setString(
          'last_song_json',
          json.encode(_currentSong!.toJson()),
        );
        await prefs.setInt('last_position_ms', _position.inMilliseconds);
        await prefs.setInt('last_queue_index', _currentIndex);
        await prefs.setBool('last_shuffle_mode', _isShuffled);
        await prefs.setInt('last_repeat_mode', _repeatMode.index);

        // Save podcast state BEFORE queue (queue can be huge and may fail)
        await prefs.setInt('last_podcast_episode_id', _currentEpisodeId ?? 0);
        await prefs.setString('last_podcast_title', _podcastTitle ?? '');
        await prefs.setString('last_podcast_episode_title', _podcastEpisodeTitle ?? '');
        await prefs.setString('last_podcast_artwork_url', _podcastArtworkUrl ?? '');
        await prefs.setInt('last_podcast_feed_id', _podcastFeedId);

        // Save source tracking for "Playing from" display
        await prefs.setString('last_source_type', _sourceType ?? '');
        await prefs.setInt('last_source_id', _sourceId ?? -1);
        await prefs.setString('last_source_name', _sourceName ?? '');

        // Save queue IDs (small)
        await prefs.setString('last_queue_json', json.encode(queueIds));
        await prefs.setString(
          'last_original_queue_json',
          json.encode(originalQueueIds),
        );

        // Cache full Song objects — can be very large (podcast queues hit 1000+
        // episodes), so json.encode of the whole queue is expensive. Only do it
        // when the queue actually changed (includeFullQueue), NOT on the every-3s
        // position autosave — re-encoding the full queue every 3 seconds janked
        // the UI thread and made the scrubber stutter/pause rhythmically.
        if (includeFullQueue) {
          try {
            await prefs.setString(
              'last_queue_songs_json',
              json.encode(_queue.map((s) => s.toJson()).toList()),
            );
            await prefs.setString(
              'last_original_queue_songs_json',
              json.encode(_originalQueue.map((s) => s.toJson()).toList()),
            );
          } catch (e) {
            print('⚠️ Queue songs cache too large to save: $e');
          }
        }
      }

      await _apiService.savePlaybackState(_deviceId!, {
        'device_name': deviceName,
        'current_song_id': _currentSong?.id,
        'position_ms': _position.inMilliseconds,
        'queue_json': json.encode(queueIds),
        'original_queue_json': json.encode(originalQueueIds),
        'queue_index': _currentIndex,
        'shuffle_mode': _isShuffled ? 1 : 0,
        'repeat_mode': _repeatMode.index,
        'volume': _volume,
        'is_playing': _isPlaying ? 1 : 0,
        'is_active': 1,
        // Source context — preserves "Playing from simpson1045's Mix" when
        // another device Resumes from this one. Without these the target
        // device has queue+position but no label/identity.
        'source_type': _sourceType,
        'source_id': _sourceId,
        'source_name': _sourceName,
      });
      print('💾 Saved playback state');

      // Notify sync service of state change
      _syncService?.onLocalStateChanged();
    } catch (e) {
      print('❌ Failed to save playback state: $e');
      AppLogger.instance.error('Save playback state failed: $e');
    }
  }

  /// Resume playback from another device's current state.
  ///
  /// Loads the source device's complete playback_state verbatim — queue
  /// order, shuffle state, repeat mode, position, and "Playing from"
  /// source label. Previous behavior dropped the source label and
  /// (for music) let setQueue's listeners drift the queue back to the
  /// current song's album context; this call now explicitly re-plants
  /// every field after setQueue() rather than letting defaults win.
  ///
  /// Podcast stale-episode remediation: if the source device's
  /// current_song is a podcast episode that's since been marked
  /// completed, we redirect to whatever episode the user has actually
  /// moved on to in that feed (via /api/rss/feeds/<id>/current-episode).
  Future<void> resumeFromDevice(String sourceDeviceId) async {
    try {
      print('📱 Resuming from device: $sourceDeviceId');
      final state = await _apiService.getPlaybackState(sourceDeviceId);

      if (state['exists'] != true) {
        print('❌ No playback state found for device $sourceDeviceId');
        return;
      }

      // Podcast stale-episode remediation (MUSIC: skip this branch).
      // If the current_song_id is negative, it's a virtual podcast song
      // — episode id is the absolute value. If that episode is now
      // completed on the server, redirect to the feed's current episode.
      final currentSongId = state['current_song_id'] as int?;
      if (currentSongId != null && currentSongId < 0) {
        final episodeId = -currentSongId;
        try {
          final epData = await _apiService.getRssEpisode(episodeId);
          final fresh = epData['episode'] ?? epData;
          final isCompleted = (fresh['is_completed'] ?? 0) == 1;
          if (isCompleted) {
            final feedId = fresh['feed_id'] as int?;
            if (feedId != null) {
              final current = await _apiService.getFeedCurrentEpisode(feedId);
              if (current != null) {
                print(
                  '🎙️ Source device was on completed episode $episodeId; '
                  'redirecting to current episode ${current['id']} in feed $feedId',
                );
                // Rebuild a minimal podcast session for the redirected
                // episode. We lose the source device's queue context
                // (which was the wrong episode anyway) but we land on
                // the right one with the server's saved position.
                final redirected = RssEpisode.fromJson(current);
                final audioUrl = redirected.audioUrl ?? _apiService.getRssStreamUrl(redirected.id);
                await playPodcastEpisode(
                  redirected,
                  audioUrl,
                  feedId: feedId,
                  allEpisodes: [redirected],
                );
                return;
              }
            }
          }
        } catch (e) {
          print('⚠️ Stale-episode check failed, continuing with source state: $e');
        }
      }

      // Get queue song IDs
      final queueJson = state['queue_json'] ?? '[]';
      final List<int> queueIds = List<int>.from(json.decode(queueJson));

      if (queueIds.isEmpty) {
        print('❌ Source device has empty queue');
        return;
      }

      // Fetch all songs in batch. Skips negative IDs (podcast virtual
      // songs) — getSongsBatch only resolves real songs.id rows.
      final positiveIds = queueIds.where((id) => id > 0).toList();
      final songData = positiveIds.isEmpty
          ? <Map<String, dynamic>>[]
          : await _apiService.getSongsBatch(positiveIds);
      final songMap = <int, Song>{};
      for (final data in songData) {
        songMap[data['id']] = Song.fromJson(data);
      }

      // Rebuild queue in order
      final queue = queueIds
          .where((id) => songMap.containsKey(id))
          .map((id) => songMap[id]!)
          .toList();

      if (queue.isEmpty) {
        print('❌ Could not resolve any songs from source device');
        return;
      }

      // Also restore original queue if available
      final originalQueueJson = state['original_queue_json'] ?? '[]';
      final List<int> originalQueueIds = List<int>.from(json.decode(originalQueueJson));

      final queueIndex = state['queue_index'] ?? 0;
      final positionMs = state['position_ms'] ?? 0;
      final shuffleMode = state['shuffle_mode'] ?? 0;
      final repeatMode = state['repeat_mode'] ?? 0;

      // Source context — "Playing from simpson1045's Mix" etc. The backend
      // saves these now; without them a resume lands with a blank
      // Now Playing label or defaults to album context.
      final sourceType = state['source_type'] as String?;
      final sourceId = state['source_id'] as int?;
      final sourceName = state['source_name'] as String?;

      // Restore shuffle/repeat state BEFORE setting queue
      // (setQueue resets _isShuffled and _originalQueue, so we override after)
      _repeatMode = RepeatMode.values[(repeatMode as int).clamp(0, RepeatMode.values.length - 1)];

      // Set the queue and start playing — queue is already in the correct
      // (possibly shuffled) order from the saved state. Pass source_*
      // through setQueue so the "Playing from X" label lands on the
      // first build instead of getting reset to null.
      _isRestoring = true;
      setQueue(
        queue,
        queueIndex.clamp(0, queue.length - 1),
        sourceType: sourceType,
        sourceId: sourceId,
        sourceName: sourceName,
      );

      // Override the original queue that setQueue just reset
      if (originalQueueIds.isNotEmpty) {
        _originalQueue = originalQueueIds
            .where((id) => songMap.containsKey(id))
            .map((id) => songMap[id]!)
            .toList();
      }

      // Re-set shuffle flag since setQueue resets it
      _isShuffled = shuffleMode == 1;
      _isRestoring = false;

      // Seek to saved position after a brief delay for player initialization
      await Future.delayed(const Duration(milliseconds: 500));
      seek(Duration(milliseconds: positionMs));

      print('✅ Resumed playback from device $sourceDeviceId '
          '(source: ${sourceName ?? "(none)"}, queue: ${queue.length})');
    } catch (e) {
      print('❌ Failed to resume from device: $e');
    }
  }

  /// Execute a remote command (used by DeviceSyncService for remote control)
  Future<void> executeRemoteCommand(String command, Map<String, dynamic> args) async {
    switch (command) {
      case 'play':
        if (!_isPlaying) togglePlayPause();
        break;
      case 'pause':
        if (_isPlaying) togglePlayPause();
        break;
      case 'toggle_play_pause':
        togglePlayPause();
        break;
      case 'next':
        next();
        break;
      case 'previous':
        previous(force: args['force'] ?? false);
        break;
      case 'seek':
        seek(Duration(milliseconds: args['position_ms'] ?? 0));
        break;
      case 'set_volume':
        setVolume((args['volume'] ?? 0.7).toDouble());
        break;
      case 'toggle_shuffle':
        toggleShuffle();
        break;
      case 'toggle_repeat':
        toggleRepeat();
        break;
      case 'set_speed':
        setPlaybackSpeed((args['speed'] ?? 1.0).toDouble());
        break;
      case 'set_sleep_timer':
        startSleepTimer(
            Duration(seconds: ((args['seconds'] ?? 0) as num).toInt()));
        break;
      case 'cancel_sleep_timer':
        cancelSleepTimer();
        break;
      case 'toggle_loop':
        toggleLoop();
        break;
      case 'toggle_lyrics':
        // Screen state — handled by the now-playing screen if it's open.
        onRemoteLyricsToggle?.call();
        break;
      case 'toggle_black_screen':
        onRemoteBlackScreenToggle?.call();
        break;
      default:
        print('⚠️ Unknown remote command: $command');
    }
  }

  Future<void> restorePlaybackState() async {
    if (_deviceId == null) return;

    _isLoading = true;
    notifyListeners();

    // If something's already loaded (user started playing before restore
    // completed), skip restore.
    if (_hasLoadedCurrent || _isPlaying) {
      print('💾 Skipping restore - player already active');
      return;
    }

    _isRestoring = true;

    // First, quickly load from local cache for instant mini player display
    await _restoreFromLocalCache();

    try {
      final state = await _apiService.getPlaybackState(_deviceId!);

      if (state['exists'] != true) {
        _isRestoring = false;
        return;
      }

      _isShuffled = state['shuffle_mode'] == 1;
      _repeatMode = RepeatMode.values[state['repeat_mode'] ?? 0];
      _volume = (state['volume'] ?? 0.7).toDouble();
      // Don't apply volume yet - wait until song is loaded

      final queueJson = state['queue_json'] ?? '[]';
      final List<int> queueIds = List<int>.from(json.decode(queueJson));

      if (queueIds.isNotEmpty) {
        // Double-check: if user started playing during the API call, abort
        if (_hasLoadedCurrent) {
          print('💾 Aborting restore - player became active during fetch');
          return;
        }

        // For podcast virtual songs (negative IDs), the API can't resolve them
        // so keep the locally cached queue as-is
        final isPodcastRestore = _currentEpisodeId != null;
        if (isPodcastRestore) {
          print('💾 Podcast restore - keeping local cache queue (${_queue.length} items)');
        } else {
          // Use cached queue from _restoreFromLocalCache() as lookup source
          // This avoids downloading the entire 18MB song library
          final songMap = {for (var s in _queue) s.id: s};

          // Also include original queue songs in case they differ
          for (var s in _originalQueue) {
            songMap[s.id] = s;
          }

          // Only rebuild if we have a valid lookup (cache was populated)
          if (songMap.isNotEmpty) {
            final rebuiltQueue = queueIds
                .where((id) => songMap.containsKey(id))
                .map((id) => songMap[id]!)
                .toList();

            // Don't overwrite with empty queue if we had songs from local cache
            if (rebuiltQueue.isNotEmpty) {
              _queue = rebuiltQueue;

              // Restore original queue order (for unshuffle)
              final originalQueueJson = state['original_queue_json'] ?? '[]';
              final List<int> originalQueueIds = List<int>.from(
                json.decode(originalQueueJson),
              );
              if (originalQueueIds.isNotEmpty) {
                _originalQueue = originalQueueIds
                    .where((id) => songMap.containsKey(id))
                    .map((id) => songMap[id]!)
                    .toList();
              } else {
                _originalQueue = List.from(_queue);
              }
            } else {
              print('💾 API queue rebuild produced empty result, keeping local cache queue');
            }
          } else {
            print('💾 No cached songs available, keeping server queue IDs only');
          }
        }

        // For podcasts, trust local cache entirely — don't let API overwrite
        // the current index or song (API state may be stale/from another device)
        if (!isPodcastRestore) {
          _currentIndex = state['queue_index'] ?? 0;
          if (_currentIndex >= _queue.length) _currentIndex = 0;
          _lastPlaylistIndex = _currentIndex;
        }

        if (_queue.isNotEmpty) {
          if (!isPodcastRestore) {
            _currentSong = _queue[_currentIndex];
          }
          final positionMs = state['position_ms'] ?? 0;
          _position = Duration(milliseconds: positionMs);

          // Cold-start podcast auto-sync. The per-device playback_state
          // above is THIS device's snapshot, but a podcast episode's
          // authoritative state lives on rss_episodes (any device's
          // progress timer writes to it). Two cases to handle:
          //
          //   1. Cached episode is now marked completed. Desktop's
          //      snapshot pointed at "S01E05 @ 45:00"; phone finished
          //      S01E05 yesterday and is now mid-S01E06. Don't resume
          //      S01E05 — redirect to whatever the feed's current
          //      episode is.
          //
          //   2. Same episode, server position is newer. 15 s progress
          //      cadence means we tolerate a >3 s drift before
          //      overriding; tinier diffs are just timer-tick noise.
          if (isPodcastRestore && _currentEpisodeId != null) {
            try {
              final epData =
                  await _apiService.getRssEpisode(_currentEpisodeId!);
              final fresh = epData['episode'] ?? epData;
              final isCompleted = (fresh['is_completed'] ?? 0) == 1;
              if (isCompleted && _podcastFeedId > 0) {
                // Redirect to the feed's current episode if one exists.
                final current = await _apiService
                    .getFeedCurrentEpisode(_podcastFeedId);
                if (current != null && current['id'] is int) {
                  final newEpisodeId = current['id'] as int;
                  final newPos = (current['played_position'] ?? 0) as int;
                  final newTitle = current['title'] as String? ??
                      _podcastEpisodeTitle ?? 'Podcast';
                  print(
                    '🎙️ Cold-start sync: cached episode $_currentEpisodeId '
                    'completed, redirecting to ${newEpisodeId} @ ${newPos}s',
                  );
                  _currentEpisodeId = newEpisodeId;
                  _podcastEpisodeTitle = newTitle;
                  _position = Duration(seconds: newPos);
                  // _currentSong is a virtual Song; rebuild it so the UI
                  // shows the right title/art before user presses play.
                  if (_currentSong != null) {
                    _currentSong = Song(
                      id: -newEpisodeId,
                      title: newTitle,
                      artistId: _currentSong!.artistId,
                      artistName: _currentSong!.artistName,
                      albumId: _currentSong!.albumId,
                      albumTitle: _currentSong!.albumTitle,
                      trackNumber: 0,
                      duration: (current['audio_duration'] ?? 0) as int,
                      filePath: (current['audio_url'] as String?) ??
                          _apiService.getRssStreamUrl(newEpisodeId),
                      fileSize: 0,
                      bitrate: 0,
                      sourceType: 'podcast',
                      podcastFeedId: _podcastFeedId,
                      podcastEpisodeId: newEpisodeId,
                      playedPosition: newPos,
                    );
                  }
                }
              } else {
                final freshPos = fresh['played_position'];
                int? serverPos;
                if (freshPos is int) {
                  serverPos = freshPos;
                } else if (freshPos is num) {
                  serverPos = freshPos.toInt();
                }
                if (serverPos != null && serverPos > 0) {
                  final local = _position.inSeconds;
                  if ((serverPos - local).abs() > 3) {
                    print(
                      '🎙️ Cold-start position sync: local=${local}s, '
                      'server=${serverPos}s — using server',
                    );
                    _position = Duration(seconds: serverPos);
                  }
                }
              }
            } catch (e) {
              print('⚠️ Cold-start podcast sync failed, using local: $e');
            }
          }

          // Build playlist but DON'T open yet - just store the position
          // The position will be restored when user presses play
          print(
            '💾 Restored state: ${_currentSong!.title} at ${_formatDuration(_position)}',
          );

          // Repeat mode is purely app-side now — _computeNextIndex honors
          // _repeatMode when togglePlayPause first-play loads the lookahead.
        }
      }

      notifyListeners();
    } catch (e) {
      print('❌ Failed to restore playback state: $e');
    } finally {
      _isRestoring = false;
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _restoreFromLocalCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final songJson = prefs.getString('last_song_json');

      if (songJson == null) return;

      _currentSong = Song.fromJson(json.decode(songJson));
      _position = Duration(milliseconds: prefs.getInt('last_position_ms') ?? 0);
      // Pre-set duration from song metadata so UI shows it immediately
      if (_currentSong!.duration > 0) {
        _duration = Duration(seconds: _currentSong!.duration);
      }
      _currentIndex = prefs.getInt('last_queue_index') ?? 0;
      _lastPlaylistIndex = _currentIndex;
      _isShuffled = prefs.getBool('last_shuffle_mode') ?? false;
      _repeatMode = RepeatMode.values[prefs.getInt('last_repeat_mode') ?? 0];

      // Restore full queue from cached Song objects (instant, no API needed)
      final queueSongsJson = prefs.getString('last_queue_songs_json');
      if (queueSongsJson != null) {
        final List<dynamic> songsData = json.decode(queueSongsJson);
        _queue = songsData.map((s) => Song.fromJson(s)).toList();
        print('⚡ Restored queue with ${_queue.length} songs from cache');
      }

      final originalQueueSongsJson = prefs.getString(
        'last_original_queue_songs_json',
      );
      if (originalQueueSongsJson != null) {
        final List<dynamic> songsData = json.decode(originalQueueSongsJson);
        _originalQueue = songsData.map((s) => Song.fromJson(s)).toList();
      } else {
        _originalQueue = List.from(_queue);
      }

      // Restore source tracking for "Playing from" display
      final sourceType = prefs.getString('last_source_type');
      _sourceType = (sourceType != null && sourceType.isNotEmpty)
          ? sourceType
          : null;
      final sourceId = prefs.getInt('last_source_id');
      _sourceId = (sourceId != null && sourceId >= 0) ? sourceId : null;
      final sourceName = prefs.getString('last_source_name');
      _sourceName = (sourceName != null && sourceName.isNotEmpty)
          ? sourceName
          : null;

      // FALLBACK: If queue is empty but we have current song, create minimal queue
      if (_queue.isEmpty && _currentSong != null) {
        _queue = [_currentSong!];
        _currentIndex = 0;
        _lastPlaylistIndex = 0;
        print(
          '⚡ Created fallback single-song queue for ${_currentSong!.title}',
        );
      }

      // Repeat mode is purely app-side now (engine never loops). Podcast
      // mode is handled below; _computeNextIndex returns null while a podcast
      // is current so no music lookahead is set.

      // Restore podcast state
      final podcastEpisodeId = prefs.getInt('last_podcast_episode_id') ?? 0;
      if (podcastEpisodeId > 0) {
        _currentEpisodeId = podcastEpisodeId;
        _podcastTitle = prefs.getString('last_podcast_title') ?? '';
        _podcastEpisodeTitle = prefs.getString('last_podcast_episode_title') ?? '';
        final artworkUrl = prefs.getString('last_podcast_artwork_url') ?? '';
        _podcastArtworkUrl = artworkUrl.isNotEmpty ? artworkUrl : null;
        _podcastFeedId = prefs.getInt('last_podcast_feed_id') ?? 0;
        print('⚡ Restored podcast state: $_podcastEpisodeTitle (episode $_currentEpisodeId)');
      } else {
        _currentEpisodeId = null;
        _podcastTitle = null;
        _podcastEpisodeTitle = null;
        _podcastArtworkUrl = null;
        _podcastFeedId = 0;
      }

      // Verify _currentIndex actually points to _currentSong in the queue
      // (index can be stale if queue was saved in a different order)
      if (_queue.isNotEmpty && _currentSong != null) {
        if (_currentIndex >= _queue.length || _queue[_currentIndex].id != _currentSong!.id) {
          final correctIndex = _queue.indexWhere((s) => s.id == _currentSong!.id);
          if (correctIndex >= 0) {
            print('⚡ Fixed stale queue index: $_currentIndex → $correctIndex');
            _currentIndex = correctIndex;
            _lastPlaylistIndex = correctIndex;
          }
        }
      }

      print('⚡ Instant restore from cache: ${_currentSong!.title} (index $_currentIndex)');
      AppLogger.instance.info('Restore: ${_currentSong!.title} (idx=$_currentIndex, queue=${_queue.length}, podcast=${_currentEpisodeId != null})');

      // Cold-start restored a station? Start now-playing polling here — this
      // restore path bypasses playSong's station branch where it normally begins.
      if (_currentSong?.isStation == true) {
        _startStationMetaPolling();
      }

      // Warm up the backend's SMB connection to the NAS for the song
      // we're about to play. Fire-and-forget HEAD request — the backend
      // /api/stream/<id> handler opens the file (establishing the SMB
      // session) before responding. By the time the user actually presses
      // play, the connection is hot and play() returns quickly.
      //
      // Without this, the first play after app open takes 10-15s while
      // Flask waits on its first SMB handshake to the NAS — the 2026-05-25
      // cold-start lag simpson1045 called unacceptable on gigabit. Skip for
      // podcasts (their streams come from external CDNs, not the NAS).
      if (_currentSong != null && !_currentSong!.isPodcast && _warmedUpSongId != _currentSong!.id) {
        final warmId = _currentSong!.id;
        _warmedUpSongId = warmId;
        final warmUpUrl = _apiService.getStreamUrl(warmId, quality: _streamQuality);
        http.head(Uri.parse(warmUpUrl)).timeout(
          const Duration(seconds: 10),
          onTimeout: () => http.Response('', 408),
        ).then((_) {
          print('🔥 Restore-time stream warm-up done for: ${_currentSong?.title}');
        }).catchError((e) {
          print('⚠️ Restore-time stream warm-up failed: $e');
        });
      }

      // If we have a full queue, we're ready to play immediately
      if (_queue.isNotEmpty) {
        _isLoading = false;
      }

      notifyListeners();
    } catch (e) {
      print('⚠️ Local cache restore failed: $e');
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  // Lightweight autosave for the 3-second timer: writes ONLY the resume
  // position locally — no song/queue JSON encoding and no network call. The
  // full state is persisted on real events (song change, play/pause, seek,
  // queue change). Doing the full save every 3s janked the scrubber.
  Future<void> _savePositionOnly() async {
    if (_deviceId == null || _currentSong == null || _isRestoring) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('last_position_ms', _position.inMilliseconds);
      await prefs.setInt('last_queue_index', _currentIndex);
    } catch (_) {}
  }

  void _startSaveTimer() {
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_isPlaying) _savePositionOnly();
    });
  }

  void _stopSaveTimer() {
    _saveTimer?.cancel();
    _saveTimer = null;
  }

  // Sleep timer
  void startSleepTimer(Duration duration) {
    if (isControlling) {
      _syncService.sendRemoteCommand(
          'set_sleep_timer', args: {'seconds': duration.inSeconds});
      return;
    }
    cancelSleepTimer();
    _volumeBeforeSleep = _volume;
    _sleepTimeRemaining = duration;

    // Show countdown on TV when casting
    if (isCasting) {
      _castService!.sendSleepTimer(duration.inSeconds);
    }

    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _sleepTimeRemaining -= const Duration(seconds: 1);
      if (_sleepTimeRemaining.inSeconds <= 0) {
        _fadeOutAndStop();
        timer.cancel();
        _sleepTimer = null;
      }
      notifyListeners();
    });

    notifyListeners();
  }

  void cancelSleepTimer() {
    if (isControlling) {
      _syncService.sendRemoteCommand('cancel_sleep_timer');
      return;
    }
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _sleepTimeRemaining = Duration.zero;
    // Hide countdown on TV
    if (isCasting) {
      _castService!.sendSleepTimer(0);
    }
    notifyListeners();
  }

  void _fadeOutAndStop() {
    const fadeDuration = Duration(seconds: 10);
    const fadeSteps = 20;
    final stepDuration = Duration(
      milliseconds: fadeDuration.inMilliseconds ~/ fadeSteps,
    );
    final volumeStep = _volume / fadeSteps;

    int currentStep = 0;
    _fadeTimer = Timer.periodic(stepDuration, (timer) {
      currentStep++;
      final newVolume = (_volume - volumeStep).clamp(0.0, 1.0);
      _active.setVolume(newVolume);
      _volume = newVolume;

      if (currentStep >= fadeSteps) {
        timer.cancel();
        _fadeTimer = null;

        _active.pause();
        _volume = _volumeBeforeSleep;
        _active.setVolume(_volume);

        // When casting, disconnect to let the TV go idle/off via HDMI-CEC
        // The black screen (if active) stays until disconnect kills the receiver
        if (isCasting) {
          _castService!.pause();
          _castService!.disconnect();
        }

        _sleepTimeRemaining = Duration.zero;
        notifyListeners();
      }
    });
  }

  // A-B Loop
  void setLoopPointA() {
    _loopPointA = _position;
    _loopPointB = null;
    notifyListeners();
  }

  void setLoopPointB() {
    if (_loopPointA == null) return;
    if (_position > _loopPointA!) {
      _loopPointB = _position;
    } else {
      _loopPointB = _loopPointA;
      _loopPointA = _position;
    }
    notifyListeners();
  }

  void clearLoop() {
    _loopPointA = null;
    _loopPointB = null;
    notifyListeners();
  }

  /// Set the A-B loop to an explicit region. Used to loop a single podcast
  /// chapter (A = chapter start, B = chapter end) in one tap. The existing
  /// loop enforcement (seek back to A when playback passes B) handles the rest.
  void setLoopRegion(Duration a, Duration b) {
    if (b <= a) return;
    _loopPointA = a;
    _loopPointB = b;
    notifyListeners();
  }

  void toggleLoop() {
    if (isControlling) {
      _syncService.sendRemoteCommand('toggle_loop');
      return;
    }
    if (_loopPointA == null) {
      setLoopPointA();
    } else if (_loopPointB == null) {
      setLoopPointB();
    } else {
      clearLoop();
    }
  }

  void setNowPlayingVisible(bool visible) {
    _isNowPlayingVisible = visible;
  }

  @override
  // --- Home screen widget ---

  void _updateHomeWidget() {
    if (!Platform.isAndroid) return;
    // Throttle to max once per second
    final now = DateTime.now();
    if (_lastWidgetUpdate != null &&
        now.difference(_lastWidgetUpdate!).inMilliseconds < 900) {
      return;
    }
    _lastWidgetUpdate = now;

    _widgetService.updateWidget(
      songTitle: _currentSong?.title,
      artistName: _currentSong?.artistsFormatted,
      albumName: _currentSong?.albumTitle,
      format: isPlayingPodcast ? '' : _currentSong?.fileFormat,
      albumId: _currentSong?.albumId,
      isPlaying: _isPlaying,
      position: position,
      duration: duration,
      artworkUrl: isPlayingPodcast ? _podcastArtworkUrl : null,
    );
  }

  void _startWidgetProgressTimer() {
    _widgetProgressTimer?.cancel();
    _widgetProgressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isPlaying) _updateHomeWidget();
    });
  }

  void _stopWidgetProgressTimer() {
    _widgetProgressTimer?.cancel();
    _widgetProgressTimer = null;
  }

  @override
  void notifyListeners() {
    super.notifyListeners();
    _updateHomeWidget();
    // Manage progress timer based on playing state
    if (_isPlaying && _widgetProgressTimer == null) {
      _startWidgetProgressTimer();
    } else if (!_isPlaying) {
      _stopWidgetProgressTimer();
    }
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _playWatchdog?.cancel();
    _stallCheckTimer?.cancel();
    _stopSaveTimer();
    _cancelCrossfade();
    _stopWidgetProgressTimer();
    _widgetService.clearWidget();
    // Cancel all engine stream subscriptions before disposing the decks.
    for (final s in _engineSubs) {
      s.cancel();
    }
    _engineSubs.clear();
    savePlaybackState();
    // Release the Windows keep-awake hold so a disposed-while-playing service
    // doesn't leave the machine pinned awake. No-op off Windows.
    if (Platform.isWindows) {
      WindowsWakelock.setEnabled(false);
    }
    _deckAEngine?.dispose();
    _deckBEngine?.dispose();
    super.dispose();
  }
}
