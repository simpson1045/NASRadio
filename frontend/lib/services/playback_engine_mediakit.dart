import 'dart:async';
import 'package:media_kit/media_kit.dart';
import 'playback_engine.dart';

/// Desktop (media_kit) implementation of [PlaybackEngine].
///
/// Internal invariant: the media_kit playlist holds AT MOST two items,
/// `[current, next]`, with the currently-playing item at index 0.
/// PlaylistMode is always `none` — we never let media_kit loop or
/// manage advancement decisions; it only does the one thing we want
/// (gaplessly roll from index 0 to index 1 when index 0 ends).
///
/// Lifecycle of the two slots:
///   loadCurrent(A)   -> open([A]),          index 0 playing
///   setNext(B)       -> [A, B]              (B pre-buffers)
///   (A ends)         -> media_kit auto-advances to index 1 -> onAdvanced
///   setNext(C)       -> trims finished A (remove 0), drops old lookahead
///                       if any, appends C  -> [B, C], B at index 0
///   ...repeat. Always exactly [current, next], current at index 0.
///
/// `setNext` is the single reconciliation primitive: trim-to-current,
/// drop existing lookahead, append the new one. "Play next", the
/// post-advance refill, and lookahead replacement all route through it,
/// so there are no special cases and nothing can desync.
class MediaKitEngine implements PlaybackEngine {
  MediaKitEngine() {
    _player = Player(configuration: const PlayerConfiguration(pitch: true));
    _wireStreams();
    _applyMpvTuning();
  }

  /// Push libmpv options media_kit doesn't surface via PlayerConfiguration.
  /// media_kit pins `network-timeout` to 5s, which is SHORTER than a cold
  /// NAS/SMB stat on the backend (8-12s) — so a slow-but-working stream open
  /// fails at 5s and the player skips the song. Bump it to 30s so a slow open
  /// rides through instead of triggering a wrongful skip. Fire-and-forget;
  /// setProperty waits for player init internally.
  void _applyMpvTuning() {
    final platform = _player.platform;
    if (platform is NativePlayer) {
      platform.setProperty('network-timeout', '30').catchError((_) {});
      // Crossfade plays two decks (two libmpv instances) simultaneously. On
      // Windows, both must open WASAPI in SHARED (non-exclusive) mode for the
      // OS to mix them. Otherwise the second deck can't grab the device,
      // silently falls back to a null audio output (clock still runs, so
      // position advances but nothing is audible), and the crossfade sounds
      // like a plain gapless cut — exactly the symptom observed. Force shared.
      platform.setProperty('audio-exclusive', 'no').catchError((_) {});
    }
  }

  late final Player _player;

  @override
  String get tag => 'mediakit';

  /// Direct access to the underlying media_kit Player — needed for the
  /// VideoController binding and a few niche call sites in the service.
  Player get rawPlayer => _player;

  // The app (AudioPlayerService) owns "what is current" via its queue +
  // index; the engine only needs to track the lookahead it's holding.
  EngineItem? _next;

  // We track the playlist index media_kit reports so we can tell an
  // "advanced 0->1" transition apart from index churn during our own
  // remove/add reconciliation (which we suppress via _reconciling).
  int _lastIndex = 0;
  bool _reconciling = false;

  // Speed / pitch state. The interface's setPitchCorrectionEnabled doesn't
  // carry the current speed, so we remember both and re-derive pitch.
  double _speed = 1.0;
  bool _pitchCorrection = true;

  final _advancedController = StreamController<void>.broadcast();
  final _completedController = StreamController<void>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _bufferingController = StreamController<bool>.broadcast();

  final List<StreamSubscription> _subs = [];

  void _wireStreams() {
    // Playlist index changes signal gapless advancement. media_kit fires
    // index increments as it rolls from [current] to [next]. We ignore
    // index changes that happen while WE are reconciling the playlist
    // (remove/add), since those churn the index without being real
    // song-end advancements.
    _subs.add(_player.stream.playlist.listen((pl) {
      final idx = pl.index;
      if (_reconciling) {
        _lastIndex = idx;
        return;
      }
      if (idx > _lastIndex) {
        // Rolled forward to the lookahead slot — current finished,
        // next is now playing. The held lookahead is now the current
        // track; clear it so the app hands us a fresh one via setNext.
        _lastIndex = idx;
        _next = null;
        _advancedController.add(null);
      } else {
        _lastIndex = idx;
      }
    }));

    // completed fires when the WHOLE playlist ends (PlaylistMode.none).
    // With our 2-slot model that means: the last loaded item finished
    // and there was no further lookahead to roll to.
    _subs.add(_player.stream.completed.listen((done) {
      if (done && !_reconciling) {
        _completedController.add(null);
      }
    }));

    _subs.add(_player.stream.buffering.listen((b) {
      _bufferingController.add(b);
    }));

    _subs.add(_player.stream.error.listen((e) {
      _errorController.add(e.toString());
    }));
  }

  @override
  EngineItem? get nextItem => _next;

  @override
  Future<void> loadCurrent(
    EngineItem item, {
    Duration startPosition = Duration.zero,
    bool autoPlay = true,
  }) async {
    _reconciling = true;
    try {
      _next = null;
      _lastIndex = 0;
      final resuming = startPosition > Duration.zero;
      // Hard reset to a single-item playlist. PlaylistMode.none so
      // media_kit never loops or decides advancement on its own.
      //
      // Resume: a seek issued immediately after a *playing* open() on a network
      // stream races the demuxer and is silently dropped — the track restarts
      // from 0 instead of resuming at the saved position. So when resuming we
      // open PAUSED, wait until the stream reports a duration (seekable by
      // then), seek, and only then start playing.
      await _player.open(
        Playlist([Media(item.url)], index: 0),
        play: resuming ? false : autoPlay,
      );
      await _player.setPlaylistMode(PlaylistMode.none);
      if (resuming) {
        if (_player.state.duration <= Duration.zero) {
          await _player.stream.duration
              .firstWhere((d) => d > Duration.zero)
              .timeout(const Duration(seconds: 10),
                  onTimeout: () => _player.state.duration);
        }
        await _player.seek(startPosition);
        if (autoPlay) {
          await _player.play();
        }
      }
    } finally {
      // Let the index settle before re-enabling advance detection.
      Future.delayed(const Duration(milliseconds: 150), () {
        _reconciling = false;
        _lastIndex = 0;
      });
    }
  }

  @override
  Future<void> setNext(EngineItem? item) async {
    // Reconcile the playlist to exactly [current, item]:
    //   1. trim any finished items before the current index (index 0)
    //   2. drop the existing lookahead at index 1 (if any)
    //   3. append the new item (lands at index 1)
    _reconciling = true;
    try {
      // 1. Trim everything before the current playing index so current
      //    sits at index 0. After a gapless advance the playlist is
      //    [finishedCurrent, nowPlaying] with index at 1 — remove(0)
      //    drops the finished item; media_kit re-indexes nowPlaying to 0
      //    without interrupting it (verified in media_kit 1.2.6 source).
      var guard = 0;
      while (_player.state.playlist.index > 0 && guard < 8) {
        await _player.remove(0);
        guard++;
      }
      // 2. Drop the existing lookahead (anything after current).
      while (_player.state.playlist.medias.length > 1) {
        await _player.remove(_player.state.playlist.medias.length - 1);
      }
      // 3. Append the new lookahead, if any.
      _next = item;
      if (item != null) {
        await _player.add(Media(item.url));
      }
      _lastIndex = 0;
    } catch (e) {
      _errorController.add('setNext failed: $e');
    } finally {
      Future.delayed(const Duration(milliseconds: 120), () {
        _reconciling = false;
        _lastIndex = _player.state.playlist.index;
      });
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() async {
    _reconciling = true;
    _next = null;
    _lastIndex = 0;
    try {
      await _player.stop();
    } finally {
      _reconciling = false;
    }
  }

  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume((volume.clamp(0.0, 1.0)) * 100.0); // media_kit: 0-100

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    await _applyRate();
  }

  @override
  Future<void> setPitchCorrectionEnabled(bool enabled) async {
    _pitchCorrection = enabled;
    await _applyRate();
  }

  /// Apply current speed + pitch-correction together. Vinyl mode (correction
  /// OFF) lets pitch follow speed; normal mode pins pitch at 1.0. Requires
  /// PlayerConfiguration(pitch: true), set at construction.
  ///
  /// At unity speed we must NOT go through media_kit's setRate/setPitch:
  /// with pitch enabled they set audio-pitch-correction=no and insert
  /// af=scaletempo even at 1.0, and scaletempo's granular re-blending
  /// audibly warbles on hi-res (96k vinyl-rip) FLACs. Clear the filter
  /// chain instead so normal playback is bit-clean passthrough.
  Future<void> _applyRate() async {
    final platform = _player.platform;
    if (_speed == 1.0 && platform is NativePlayer) {
      // Pitch is 1.0 in both modes at unity speed (vinyl: pitch=speed=1.0),
      // so this branch is exact, not an approximation. Reset speed too —
      // media_kit's setPitch drives mpv's speed property, so it may be
      // left ≠1.0 when returning from a non-unity rate.
      await platform.setProperty('af', '');
      await platform.setProperty('audio-pitch-correction', 'yes');
      await platform.setProperty('speed', '1.0');
      return;
    }
    await _player.setRate(_speed);
    await _player.setPitch(_pitchCorrection ? 1.0 : _speed);
  }

  @override
  Stream<Duration> get positionStream => _player.stream.position;

  @override
  Stream<Duration?> get durationStream =>
      _player.stream.duration.map<Duration?>((d) => d);

  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  Stream<bool> get bufferingStream => _bufferingController.stream;

  @override
  Stream<void> get onAdvanced => _advancedController.stream;

  @override
  Stream<void> get onCompleted => _completedController.stream;

  @override
  Stream<String> get onError => _errorController.stream;

  @override
  Duration get position => _player.state.position;

  @override
  Duration get duration => _player.state.duration;

  @override
  bool get playing => _player.state.playing;

  @override
  bool get buffering => _player.state.buffering;

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _advancedController.close();
    await _completedController.close();
    await _errorController.close();
    await _bufferingController.close();
    await _player.dispose();
  }
}
