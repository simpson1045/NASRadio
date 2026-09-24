import 'package:flutter/material.dart';

/// DEPRECATED — pass-through. Mouse-back is now handled globally by
/// [AppBackNavigator] / NavBackController (a single debounced source of truth).
/// This used to install a per-screen Listener that popped on mouse button 8,
/// which double-fired against the shell + key handlers and overshot to home.
/// Kept as a no-op wrapper so existing usages compile; the usages can be
/// deleted in a mechanical cleanup pass.
class MouseBackButtonWrapper extends StatelessWidget {
  final Widget child;

  const MouseBackButtonWrapper({super.key, required this.child});

  @override
  Widget build(BuildContext context) => child;
}
