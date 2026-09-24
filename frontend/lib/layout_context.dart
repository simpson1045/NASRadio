import 'package:flutter/widgets.dart';

/// The one place the mobile-vs-desktop decision is made
/// (DESKTOP_UX_SPEC.md §3).
///
/// NASRadio began life as a desktop app; the phone port cost it the
/// dedicated layout split, leaving ~200 scattered `width < 600`-style
/// checks negotiating every widget between two form factors. This
/// restores a single source of truth: the shell measures the window
/// once per geometry change and publishes the verdict here. Screens
/// read `LayoutScope.of(context).isDesktop` — never MediaQuery math.
///
/// As screens are restored (spec §5) their local checks migrate to
/// this. A screen is "restored" when it contains zero ad-hoc width
/// checks.
enum AppLayout { mobile, desktop }

class LayoutScope extends InheritedWidget {
  /// Matches the login screen's precedent (the pattern's proof).
  static const double desktopBreakpoint = 1100;

  final AppLayout layout;

  const LayoutScope({super.key, required this.layout, required super.child});

  bool get isDesktop => layout == AppLayout.desktop;
  bool get isMobile => layout == AppLayout.mobile;

  static LayoutScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LayoutScope>();
    assert(scope != null, 'LayoutScope missing above this context — '
        'is the shell wrapping the tree?');
    return scope!;
  }

  /// Null-safe variant for widgets that can render outside the shell
  /// (dialogs pushed on the root navigator, the login screen).
  static LayoutScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LayoutScope>();

  @override
  bool updateShouldNotify(LayoutScope oldWidget) => layout != oldWidget.layout;
}
