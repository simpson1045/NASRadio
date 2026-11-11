import 'dart:async';

import 'app_logger.dart';
import 'app_visibility.dart';

/// Catches the app's main thread getting stuck, and says what it was doing.
///
/// FRAMEWORK (Nov 2026): the app froze for seconds right after playback
/// started while time kept moving (the scrubber jumped afterwards, catching
/// up on stale position updates). A 200 ms timer can't fire while the main
/// thread is blocked, so a long gap between ticks = a stall. The report lists
/// what was in flight ([track]/[begin]) and the last breadcrumbs ([note])
/// around the stall, e.g.
///   🧊 [stall] main thread stuck ~2400 ms (visible) | in flight: mpv.setNext
///   (started 30 ms before) | steps: mpv.remove -40ms, mpv.add -10ms
/// [track] also logs any call whose synchronous part alone blocks > 150 ms:
///   🐌 [stall] save.playbackState blocked the main thread 900 ms
class StallWatch {
  StallWatch._();
  static final StallWatch instance = StallWatch._();

  static const Duration _tick = Duration(milliseconds: 200);
  static const int _stallMs = 1000;
  static const int _slowSyncMs = 150;

  Timer? _timer;
  DateTime _last = DateTime.now();
  int _nextId = 0;
  final Map<int, (String, DateTime)> _inFlight = {};
  final List<(String, DateTime)> _notes = [];

  void start() {
    _timer ??= Timer.periodic(_tick, (_) => _check());
  }

  /// A breadcrumb: "about to do X".
  void note(String what) {
    _notes.add((what, DateTime.now()));
    if (_notes.length > 40) _notes.removeAt(0);
  }

  int begin(String what) {
    final id = _nextId++;
    _inFlight[id] = (what, DateTime.now());
    note(what);
    return id;
  }

  void end(int id) => _inFlight.remove(id);

  /// Runs [f], tracking it as in flight until its future completes, and logs
  /// if its synchronous part (everything before its first real await, e.g. a
  /// blocking FFI or file call) held the main thread.
  Future<T> track<T>(String what, Future<T> Function() f) async {
    final id = begin(what);
    final sw = Stopwatch()..start();
    late final Future<T> future;
    try {
      future = f();
    } catch (e) {
      end(id);
      rethrow;
    }
    final syncMs = sw.elapsedMilliseconds;
    if (syncMs > _slowSyncMs) {
      AppLogger.instance
          .warning('🐌 [stall] $what blocked the main thread $syncMs ms');
    }
    try {
      return await future;
    } finally {
      end(id);
    }
  }

  void _check() {
    final now = DateTime.now();
    final gap = now.difference(_last).inMilliseconds;
    _last = now;
    if (gap < _stallMs) return;

    final stuck = gap - _tick.inMilliseconds;
    final from = now.subtract(Duration(milliseconds: gap));
    final inFlight = _inFlight.values
        .map((e) =>
            '${e.$1} (started ${from.difference(e.$2).inMilliseconds} ms before)')
        .join(', ');
    final steps = _notes
        .where((n) => n.$2.isAfter(from.subtract(const Duration(seconds: 2))))
        .map((n) => '${n.$1} ${n.$2.difference(from).inMilliseconds}ms')
        .join(', ');
    final visible = AppVisibility.instance.visible.value ? 'visible' : 'hidden';
    AppLogger.instance.warning(
      '🧊 [stall] main thread stuck ~$stuck ms ($visible)'
      ' | in flight: ${inFlight.isEmpty ? 'nothing tracked' : inFlight}'
      ' | steps (ms from stall start): ${steps.isEmpty ? 'none' : steps}',
    );
  }
}
