import 'package:flutter/material.dart';
import '../services/device_sync_service.dart';

/// A small cyan pill that fades in when this device is participating in remote
/// control — either "Controlled by [device]" (we are the target) or
/// "Controlling [device]" (we are the controller). Styled to match the Cast
/// indicator (#00d4ff) so the two features feel like one family.
///
/// Self-contained: listens to the [DeviceSyncService] and renders nothing when
/// idle, so callers can drop it anywhere (now playing, fullscreen, mini player)
/// without their own visibility logic.
class RemoteControlBadge extends StatelessWidget {
  final DeviceSyncService service;

  /// Tighter padding / smaller text for dense spots like the mini player.
  final bool compact;

  /// When controlling, tapping the badge stops remote control. Wire this on the
  /// controller's surfaces (e.g. Now Playing) so the takeover has an obvious
  /// "stop" — it's a no-op on the controlled device (which only shows status).
  final VoidCallback? onStopControl;

  const RemoteControlBadge({
    super.key,
    required this.service,
    this.compact = false,
    this.onStopControl,
  });

  static const Color _accent = Color(0xFF00d4ff);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        String? text;
        var controlling = false;
        if (service.isBeingControlled) {
          text = 'Controlled by ${service.controllerDeviceName ?? 'another device'}';
        } else if (service.isController) {
          text = 'Controlling ${service.targetDeviceName ?? 'a device'}';
          controlling = true;
        }

        final tappable = controlling && onStopControl != null;
        Widget child = text == null
            ? const SizedBox.shrink(key: ValueKey('rc-none'))
            : _pill(text, showStop: tappable);
        if (tappable) {
          child = GestureDetector(
            key: ValueKey('rc-tap-$text'),
            onTap: onStopControl,
            behavior: HitTestBehavior.opaque,
            child: child,
          );
        }

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          transitionBuilder: (child, anim) =>
              FadeTransition(opacity: anim, child: child),
          child: child,
        );
      },
    );
  }

  Widget _pill(String text, {bool showStop = false}) {
    final double fontSize = compact ? 11 : 12.5;
    final EdgeInsets pad = compact
        ? const EdgeInsets.symmetric(horizontal: 8, vertical: 3)
        : const EdgeInsets.symmetric(horizontal: 12, vertical: 6);
    return Container(
      key: ValueKey('rc-$text'),
      padding: pad,
      decoration: BoxDecoration(
        color: _accent.withOpacity(0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _accent.withOpacity(0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.settings_remote, size: compact ? 13 : 15, color: _accent),
          SizedBox(width: compact ? 5 : 7),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _accent,
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ),
          if (showStop) ...[
            SizedBox(width: compact ? 5 : 7),
            Icon(Icons.close, size: compact ? 13 : 15, color: _accent),
          ],
        ],
      ),
    );
  }
}
