import 'dart:io' show Platform;
import 'package:flutter/services.dart';

/// Holds an Android Wi-Fi high-performance lock + partial wake lock while
/// casting, so locking the phone doesn't drop the LAN connection to the TV.
///
/// The foreground service keeps the CPU alive but does NOT stop Wi-Fi from
/// power-saving when the screen turns off — which killed casts within seconds
/// of locking the phone. The native side (MainActivity.kt) holds a
/// FULL_HIGH_PERF Wi-Fi lock that survives screen-off. No-op off Android.
class CastKeepAlive {
  static const _channel = MethodChannel('com.nasradio/castkeepalive');
  static bool _held = false;

  /// Acquire the locks (idempotent). Call when a cast session begins.
  static Future<void> acquire() async {
    if (!Platform.isAndroid || _held) return;
    try {
      await _channel.invokeMethod('acquire');
      _held = true;
    } catch (_) {
      // Native side missing / failed — degrade silently to the old behavior.
    }
    // Doze exemption check — separate call so a failure here can't cost us
    // the locks. Doze suspends the app's NETWORK during long screen-off
    // (locks don't help; casting plays no local audio so the phone looks
    // idle) — that was the "cast dies after several songs" root cause.
    // No-op once the user has granted the exemption.
    try {
      final exempt =
          await _channel.invokeMethod('ensureBatteryExemption') as bool?;
      // ignore: avoid_print
      print('🔋 [Cast] Battery-optimization exempt: $exempt');
    } catch (_) {}
  }

  /// Release the locks (idempotent). Call when the cast session truly ends —
  /// NOT on a transient drop, so the radio stays up for auto-reconnect.
  static Future<void> release() async {
    if (!Platform.isAndroid || !_held) return;
    try {
      await _channel.invokeMethod('release');
    } catch (_) {}
    _held = false;
  }
}
