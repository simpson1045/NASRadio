import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Single source of truth for "go back" / "go forward" navigation driven by
/// the mouse side-buttons and the browser back/forward keys.
///
/// Windows can deliver ONE physical side-button press as BOTH a pointer event
/// (buttons == 8 / 16) AND a browserBack/browserForward key event (some mouse
/// drivers remap the side buttons to keyboard keys). The app used to have three
/// independent handlers that each popped — so a single press navigated back two
/// or three times ("overshoots to home"). Everything now funnels through this
/// one debounced entry point: whichever event arrives first navigates, and any
/// duplicate within the debounce window is ignored — hardware-agnostic.
class NavBackController {
  NavBackController._();

  /// Attached to MaterialApp so we can pop the root navigator from above it.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  /// Set by the nav shell: what to do when there is no route to pop — i.e.
  /// walk the bottom-tab history back / forward.
  static VoidCallback? onTabBack;
  static VoidCallback? onTabForward;

  static const _debounce = Duration(milliseconds: 250);
  static DateTime? _lastBack;
  static DateTime? _lastForward;

  static bool _tooSoon(DateTime? last) =>
      last != null && DateTime.now().difference(last) < _debounce;

  static void back() {
    if (_tooSoon(_lastBack)) return;
    _lastBack = DateTime.now();
    final nav = navigatorKey.currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
    } else {
      onTabBack?.call();
    }
  }

  static void forward() {
    if (_tooSoon(_lastForward)) return;
    _lastForward = DateTime.now();
    onTabForward?.call();
  }
}

/// Wraps the app ABOVE MaterialApp and routes mouse side-buttons + browser
/// back/forward keys into [NavBackController]. Being above the Navigator means
/// it sees events for every route — pushed detail screens AND tab screens — so
/// no per-screen wrapper is needed.
class AppBackNavigator extends StatefulWidget {
  final Widget child;
  const AppBackNavigator({super.key, required this.child});

  @override
  State<AppBackNavigator> createState() => _AppBackNavigatorState();
}

class _AppBackNavigatorState extends State<AppBackNavigator> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.browserBack) {
        NavBackController.back();
        return true;
      }
      if (event.logicalKey == LogicalKeyboardKey.browserForward) {
        NavBackController.forward();
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // 8 = mouse "back" (X1), 16 = mouse "forward" (X2). Passive listener —
      // it observes pointer-downs without consuming them, so normal clicks
      // are unaffected.
      onPointerDown: (event) {
        if (event.buttons == 8) {
          NavBackController.back();
        } else if (event.buttons == 16) {
          NavBackController.forward();
        }
      },
      child: widget.child,
    );
  }
}
