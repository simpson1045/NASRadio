import 'package:flutter/widgets.dart';

/// Whether the user can see the app at all. Drives an app-wide TickerMode in
/// main.dart, so every animation (mini player progress + sparks, Now Playing,
/// waveform, lyrics) stops while nobody can see it.
///
/// Visible = on screen, focused or not (a second monitor counts). Hidden =
/// minimized, or the OS says hidden/paused (phone backgrounded, Mac hidden).
/// Windows never reports `hidden` for a minimized window (only `inactive`,
/// the same as losing focus), so desktop minimize/restore comes from
/// window_manager instead. Without this the Windows app burned ~23% GPU
/// minimized (FRAMEWORK, Oct 2026).
class AppVisibility {
  AppVisibility._();
  static final AppVisibility instance = AppVisibility._();

  final ValueNotifier<bool> visible = ValueNotifier<bool>(true);

  AppLifecycleState _lifecycle = AppLifecycleState.resumed;
  bool _minimized = false;

  void setLifecycle(AppLifecycleState state) {
    _lifecycle = state;
    _update();
  }

  void setMinimized(bool minimized) {
    _minimized = minimized;
    _update();
  }

  void _update() {
    final shown = !_minimized &&
        (_lifecycle == AppLifecycleState.resumed ||
            _lifecycle == AppLifecycleState.inactive);
    if (visible.value != shown) visible.value = shown;
  }
}
