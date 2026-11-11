import 'dart:async';

import 'package:flutter/scheduler.dart';

import 'app_logger.dart';
import 'app_visibility.dart';

/// Tripwire for the bug that kept coming back (Oct 26, Nov 4, Nov 9): an
/// animation clock left running, so the app keeps drawing frames while
/// nothing on screen moves. On Windows every frame redraws the whole window,
/// which ran FRAMEWORK hot and froze the whole machine.
///
/// Counts the frames actually drawn and every 10 minutes logs a summary:
///   🎞️ [frames] last 10 min: playing 59.8 fps (6.0m), paused 0.1 fps (4.0m)
/// and warns (at most every 15 min) when the app draws more than it should
/// for two 30 s windows in a row:
///   🔥 [frames] 60.1 fps while paused for 60 s ...
/// Paused allows the themed-song glow breathe (20 fps) plus some scrolling;
/// hidden (minimized / backgrounded) allows next to nothing.
class FrameWatchdog {
  FrameWatchdog._();
  static final FrameWatchdog instance = FrameWatchdog._();

  static const Duration _window = Duration(seconds: 30);
  static const int _summaryWindows = 20; // 20 x 30 s = 10 min
  static const double _pausedLimit = 25.0;
  static const double _hiddenLimit = 2.0;

  bool Function() _isPlaying = () => false;
  Timer? _timer;
  int _frames = 0;
  int _strikes = 0;
  DateTime? _lastWarn;
  int _windows = 0;
  final Map<String, int> _sumFrames = {};
  final Map<String, int> _sumWindows = {};

  void start({required bool Function() isPlaying}) {
    if (_timer != null) return;
    _isPlaying = isPlaying;
    SchedulerBinding.instance.addTimingsCallback((t) => _frames += t.length);
    _timer = Timer.periodic(_window, (_) => _check());
  }

  void _check() {
    final frames = _frames;
    _frames = 0;
    final fps = frames / _window.inSeconds;

    bool playing;
    try {
      playing = _isPlaying();
    } catch (_) {
      playing = false;
    }
    final state = !AppVisibility.instance.visible.value
        ? 'hidden'
        : (playing ? 'playing' : 'paused');
    _sumFrames[state] = (_sumFrames[state] ?? 0) + frames;
    _sumWindows[state] = (_sumWindows[state] ?? 0) + 1;

    final limit = state == 'hidden'
        ? _hiddenLimit
        : (state == 'paused' ? _pausedLimit : double.infinity);
    if (fps > limit) {
      _strikes++;
      final now = DateTime.now();
      if (_strikes >= 2 &&
          (_lastWarn == null ||
              now.difference(_lastWarn!) > const Duration(minutes: 15))) {
        _lastWarn = now;
        AppLogger.instance.warning(
          '🔥 [frames] ${fps.toStringAsFixed(1)} fps while $state for '
          '${_strikes * _window.inSeconds} s (limit '
          '${limit.toStringAsFixed(0)}): something is redrawing when nothing '
          'should move',
        );
      }
    } else {
      _strikes = 0;
    }

    if (++_windows >= _summaryWindows) {
      final parts = <String>[];
      for (final s in const ['playing', 'paused', 'hidden']) {
        final w = _sumWindows[s] ?? 0;
        if (w == 0) continue;
        final secs = w * _window.inSeconds;
        final f = (_sumFrames[s] ?? 0) / secs;
        parts.add('$s ${f.toStringAsFixed(1)} fps '
            '(${(secs / 60).toStringAsFixed(1)}m)');
      }
      AppLogger.instance.info('🎞️ [frames] last 10 min: ${parts.join(', ')}');
      _sumFrames.clear();
      _sumWindows.clear();
      _windows = 0;
    }
  }
}
