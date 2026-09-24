import 'dart:ffi';
import 'dart:io' show Platform;

/// Windows-only "keep awake during playback" helper.
///
/// Wraps the Win32 `SetThreadExecutionState` API (kernel32.dll) so that while
/// music is actively playing we tell Windows the machine is busy — preventing
/// the system from sleeping and the display from turning off. When playback
/// pauses/stops we clear the flags so normal idle timeouts resume.
///
/// On any non-Windows platform every call is a no-op, so callers don't need to
/// guard with Platform.isWindows themselves (though they may, to skip the work).
class WindowsWakelock {
  WindowsWakelock._();

  // EXECUTION_STATE flags (winbase.h).
  static const int _esContinuous = 0x80000000;
  static const int _esSystemRequired = 0x00000001;
  static const int _esDisplayRequired = 0x00000002;

  static _SetThreadExecutionStateNative? _setState;
  static bool _resolved = false;
  static bool _enabled = false;

  /// Lazily bind to kernel32!SetThreadExecutionState. Returns null off Windows
  /// or if the symbol can't be resolved (shouldn't happen on a real desktop).
  static _SetThreadExecutionStateNative? _resolve() {
    if (_resolved) return _setState;
    _resolved = true;
    if (!Platform.isWindows) return null;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      _setState = kernel32.lookupFunction<_SetThreadExecutionStateC,
          _SetThreadExecutionStateNative>('SetThreadExecutionState');
    } catch (_) {
      _setState = null;
    }
    return _setState;
  }

  /// Drive the wakelock to match playback state. Idempotent — calling it
  /// repeatedly with the same value does nothing after the first transition.
  ///
  /// [keepAwake] true while audio is actively playing; false on pause/stop.
  static void setEnabled(bool keepAwake) {
    if (keepAwake == _enabled) return;
    final setState = _resolve();
    if (setState == null) return; // not Windows / symbol missing
    if (keepAwake) {
      // ES_CONTINUOUS keeps the flags in effect until we change them again,
      // rather than resetting after a single idle-timer poke.
      setState(_esContinuous | _esSystemRequired | _esDisplayRequired);
    } else {
      // Clear the requirements — ES_CONTINUOUS alone restores normal timeouts.
      setState(_esContinuous);
    }
    _enabled = keepAwake;
  }
}

typedef _SetThreadExecutionStateC = Uint32 Function(Uint32 esFlags);
typedef _SetThreadExecutionStateNative = int Function(int esFlags);
