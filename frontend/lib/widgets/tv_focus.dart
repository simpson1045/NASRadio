import 'package:flutter/material.dart';

/// Wraps a tappable region so it can be reached + activated via the
/// Fire TV / Android TV remote's d-pad. Touch tap still works as before.
///
/// Built on `FocusableActionDetector` — it makes the region focusable,
/// wires d-pad center / Enter / Space / select to the existing `onTap`
/// callback via the standard `ActivateIntent`, and triggers a state
/// rebuild on focus change so we can paint a 3px cyan border around the
/// child via a `Stack` overlay (no layout shift).
///
/// On focus, `Scrollable.ensureVisible` runs in a post-frame callback so
/// d-pad navigation through a horizontally-scrolling list keeps the
/// focused item in view — without it, focus could leave the viewport
/// silently and the user wouldn't be able to tell what was selected.
class TvFocusable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final BorderRadius? borderRadius;
  final bool autofocus;

  const TvFocusable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.borderRadius,
    this.autofocus = false,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;

  void _onFocusChange(bool focused) {
    if (!mounted) return;
    if (_focused != focused) setState(() => _focused = focused);
    if (focused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ctx = context;
        if (!ctx.mounted) return;
        // Scope ensureVisible to ONLY the immediate enclosing Scrollable
        // — the static `Scrollable.ensureVisible(ctx, ...)` walks the
        // entire ancestor chain. For a card inside a horizontal `ListView`
        // inside the dashboard's outer vertical `SingleChildScrollView`,
        // that means BOTH scroll — and the outer scroll pulls the
        // "Recently Played" section header off the top of the viewport.
        // Calling `position.ensureVisible` directly on the nearest
        // ScrollableState only scrolls the inner horizontal list (which
        // is what we actually want for d-pad carousels).
        final scrollable = Scrollable.maybeOf(ctx);
        final renderObject = ctx.findRenderObject();
        if (scrollable == null || renderObject == null) return;
        scrollable.position.ensureVisible(
          renderObject,
          duration: const Duration(milliseconds: 200),
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      onFocusChange: _onFocusChange,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: Stack(
          children: [
            widget.child,
            if (_focused)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: widget.borderRadius,
                      border: Border.all(
                        color: const Color(0xFF00d4ff),
                        width: 3,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// `IconButton`-shaped widget that draws a clear cyan focus ring when
/// focused via d-pad. Default Flutter focus highlight on `IconButton` is
/// too subtle to see at 10-foot Fire TV viewing distance. Built directly
/// from `FocusableActionDetector` (not by wrapping `IconButton`) because
/// Flutter Issue #96860: passing a `FocusNode` to `IconButton.focusNode`
/// does NOT actually attach the node to the focus tree, so the canonical
/// "wrap IconButton in your own focus-aware widget" pattern silently
/// fails to receive focus events.
class TvIconButton extends StatefulWidget {
  final Widget icon;
  final VoidCallback? onPressed;
  final double iconSize;
  final String? tooltip;
  final bool autofocus;

  const TvIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.iconSize = 48,
    this.tooltip,
    this.autofocus = false,
  });

  @override
  State<TvIconButton> createState() => _TvIconButtonState();
}

class _TvIconButtonState extends State<TvIconButton> {
  bool _focused = false;

  void _onFocusChange(bool focused) {
    if (!mounted) return;
    if (_focused != focused) {
      setState(() => _focused = focused);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      mouseCursor: SystemMouseCursors.click,
      onFocusChange: _onFocusChange,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onPressed?.call();
            return null;
          },
        ),
      },
      child: Tooltip(
        message: widget.tooltip ?? '',
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: widget.icon,
              ),
              if (_focused)
                IgnorePointer(
                  child: Container(
                    width: widget.iconSize,
                    height: widget.iconSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFF00d4ff),
                        width: 2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
