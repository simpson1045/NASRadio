import 'dart:async';
import 'package:just_audio/just_audio.dart' as ja;
import 'playback_engine.dart';

/// Mobile (just_audio) implementation of [PlaybackEngine].
///
/// Internal invariant: the [ja.ConcatenatingAudioSource] holds AT MOST two
/// items, `[current, next]`, with the currently-playing item at index 0.
/// We never enable just_audio's loop modes — the engine alone decides
/// advancement. just_audio does the one thing we want: gaplessly roll from
/// index 0 to index 1 when index 0 ends (ConcatenatingAudioSource pre-buffers
/// the lookahead), and report end-of-source via ProcessingState.completed.
///
/// Lifecycle of the two slots (identical to MediaKitEngine):
///   loadCurrent(A)   -> setAudioSource([A]),  index 0 playing
///   setNext(B)       -> [A, B]                (B pre-buffers gaplessly)
///   (A ends)         -> just_audio rolls currentIndex 0 -> 1 -> onAdvanced
///   setNext(C)       -> removeAt(0) drops finished A, drops old lookahead,
///                       add(C) -> [B, C], B at index 0
///   ...repeat. Always exactly [current, next], current at index 0.
///
/// `setNext` is the single reconciliation primitive: trim-to-current, drop
/// existing lookahead, append the new one. "Play next", the post-advance
/// refill, and lookahead replacement all route through it, so there are no
/// special cases and nothing can desync.
///
/// Live mutation of a ConcatenatingAudioSource (add/removeAt) does NOT
/// interrupt the currently-playing item: removing an item BEFORE the current
/// index shifts currentIndex down transparently, and appending to the end
/// only pre-buffers. We only ever removeAt(0) when currentIndex > 0 (i.e.
/// the item at 0 is already finished), so the playing item is never touched.
class JustAudioEngine implements PlaybackEngine {
  JustAudioEngine() {
    _player = ja.AudioPlayer(
      // Mirror the app's proven ExoPlayer buffer tuning so playback/rebuffer
      // behavior is identical to the pre-rewrite mobile player.
      audioLoadConfiguration: ja.AudioLoadConfiguration(
        androidLoadControl: ja.AndroidLoadControl(
          minBufferDuration: const Duration(seconds: 60),
          maxBufferDuration: const Duration(seconds: 120),
          bufferForPlaybackDuration: const Duration(milliseconds: 1500),
          bufferForPlaybackAfterRebufferDuration: const Duration(seconds: 3),
          prioritizeTimeOverSizeThresholds: true,
          backBufferDuration: const Duration(seconds: 30),
        ),
      ),
    );
    _wireStreams();
  }

  late final ja.AudioPlayer _player;

  /// The live source backing the two slots. Null before the first
  /// [loadCurrent] and after [stop].
  ja.ConcatenatingAudioSource? _source;

  @override
  String get tag => 'justaudio';

  /// Direct access to the underlying just_audio player — a few niche call
  /// sites in the service (audio_session ducking, raw stream taps) need it.
  ja.AudioPlayer get rawPlayer => _player;

  // The app owns "what is current"; the engine only tracks its lookahead.
  EngineItem? _next;

  // Track the currentIndex just_audio reports so we can tell a real
  // "advanced 0->1" transition apart from index churn during our own
  // reconciliation (which we suppress via _reconciling).
  int _lastIndex = 0;
  bool _reconciling = false;

  // Speed / pitch state. The interface's setPitchCorrectionEnabled doesn't
  // carry the current speed, so we remember both and re-derive pitch:
  //   pitch correction ON  -> pitch stays 1.0 (normal)
  //   pitch correction OFF -> pitch follows speed (vinyl mode)
  double _speed = 1.0;
  bool _pitchCorrection = true;

  final _advancedController = StreamController<void>.broadcast();
  final _completedController = StreamController<void>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _bufferingController = StreamController<bool>.broadcast();

  final List<StreamSubscription> _subs = [];

  void _wireStreams() {
    // currentIndex increments signal gapless advancement. just_audio rolls
    // the index from 0 to 1 as it moves from [current] to [next]. We ignore
    // index changes while WE are reconciling (removeAt/add churns the index
    // without being a real song-end advancement), and ignore nulls (which
    // occur transiently around setAudioSource).
    _subs.add(_player.currentIndexStream.listen((idx) {
      if (idx == null) return;
      if (_reconciling) {
        _lastIndex = idx;
        return;
      }
      if (idx > _lastIndex) {
        // Rolled forward to the lookahead slot — current finished, next is
        // now playing. The held lookahead becomes the current track; clear
        // it so the app hands us a fresh one via setNext.
        _lastIndex = idx;
        _next = null;
        _advancedController.add(null);
      } else {
        _lastIndex = idx;
      }
    }));

    // processingState drives both completion and buffering. With our 2-slot
    // model, ProcessingState.completed means the LAST loaded item finished
    // and there was no further lookahead to roll to (a gapless 0->1 roll does
    // NOT complete the source — it just moves currentIndex).
    _subs.add(_player.processingStateStream.listen((state) {
      final buffering = state == ja.ProcessingState.loading ||
          state == ja.ProcessingState.buffering;
      _bufferingController.add(buffering);

      if (state == ja.ProcessingState.completed && !_reconciling) {
        _completedController.add(null);
      }
    }));

    // just_audio surfaces playback errors via PlayerException on the
    // playbackEventStream; map them to a human-readable message.
    _subs.add(_player.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace st) {
        _errorController.add(e.toString());
      },
    ));
  }

  ja.AudioSource _makeSource(EngineItem item) {
    // Attach the OS media-notification tag if the app supplied metadata.
    final tag = <String, dynamic>{
      if (item.title != null) 'title': item.title,
      if (item.artist != null) 'artist': item.artist,
      if (item.album != null) 'album': item.album,
      if (item.artUri != null) 'artUri': item.artUri,
    };
    return ja.AudioSource.uri(
      Uri.parse(item.url),
      tag: tag.isEmpty ? null : tag,
    );
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
      // Hard reset to a single-item source. setAudioSource resolves once the
      // source is prepared; initialPosition seeks the start (resume).
      _source = ja.ConcatenatingAudioSource(
        useLazyPreparation: true,
        children: [_makeSource(item)],
      );
      await _player.setAudioSource(
        _source!,
        initialIndex: 0,
        initialPosition: startPosition,
      );
      // Re-apply any speed/pitch the app set before this load.
      await _applyRate();
      if (autoPlay) {
        // Do NOT await — play()'s Future completes when playback ENDS.
        _player.play();
      }
    } catch (e) {
      _errorController.add('loadCurrent failed: $e');
    } finally {
      // Let the index settle before re-enabling advance detection.
      Future.delayed(const Duration(milliseconds: 150), () {
        _reconciling = false;
        _lastIndex = _player.currentIndex ?? 0;
      });
    }
  }

  @override
  Future<void> setNext(EngineItem? item) async {
    // Nothing loaded yet — there's no current slot to attach a lookahead to.
    // (After stop() the source is null; the next loadCurrent rebuilds it.)
    final src = _source;
    if (src == null) {
      _next = item;
      return;
    }
    // Reconcile the source to exactly [current, item]:
    //   1. trim any finished items before the current index (index 0)
    //   2. drop the existing lookahead at index 1 (if any)
    //   3. append the new item (lands at index 1)
    _reconciling = true;
    try {
      // 1. Trim everything before the current playing index so current sits
      //    at index 0. After a gapless advance the source is
      //    [finishedCurrent, nowPlaying] with currentIndex 1 — removeAt(0)
      //    drops the finished item; just_audio re-indexes nowPlaying to 0
      //    without interrupting it.
      var guard = 0;
      while ((_player.currentIndex ?? 0) > 0 && guard < 8) {
        await src.removeAt(0);
        guard++;
      }
      // 2. Drop the existing lookahead (anything after current = index >= 1).
      while (src.length > 1) {
        await src.removeAt(src.length - 1);
      }
      // 3. Append the new lookahead, if any.
      _next = item;
      if (item != null) {
        await src.add(_makeSource(item));
      }
      _lastIndex = 0;
    } catch (e) {
      _errorController.add('setNext failed: $e');
    } finally {
      Future.delayed(const Duration(milliseconds: 120), () {
        _reconciling = false;
        _lastIndex = _player.currentIndex ?? 0;
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
      // just_audio's stop() idles the player; a fresh loadCurrent must
      // setAudioSource again, so drop our source reference too.
      _source = null;
    } finally {
      _reconciling = false;
    }
  }

  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume(volume.clamp(0.0, 1.0)); // just_audio: 0.0 - 1.0

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

  /// Apply current speed + pitch-correction state together. Vinyl mode
  /// (correction OFF) lets pitch follow speed; normal mode pins pitch at 1.0.
  Future<void> _applyRate() async {
    await _player.setSpeed(_speed);
    await _player.setPitch(_pitchCorrection ? 1.0 : _speed);
  }

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration?> get durationStream => _player.durationStream;

  @override
  Stream<bool> get playingStream => _player.playingStream;

  @override
  Stream<bool> get bufferingStream => _bufferingController.stream;

  @override
  Stream<void> get onAdvanced => _advancedController.stream;

  @override
  Stream<void> get onCompleted => _completedController.stream;

  @override
  Stream<String> get onError => _errorController.stream;

  @override
  Duration get position => _player.position;

  @override
  Duration get duration => _player.duration ?? Duration.zero;

  @override
  bool get playing => _player.playing;

  @override
  bool get buffering =>
      _player.processingState == ja.ProcessingState.loading ||
      _player.processingState == ja.ProcessingState.buffering;

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
