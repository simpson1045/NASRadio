import 'package:flutter/material.dart';

/// A Cast device the user has previously connected to. Persisted
/// across app launches so it can appear in the "Recent" section of
/// the device picker with an online/offline indicator.
class SavedCastDevice {
  /// Stable mDNS service name — survives IP changes and reboots.
  final String serviceName;

  /// The friendly name the device broadcasts over mDNS.
  final String originalName;

  /// Name the user set in the app. Null means "show originalName".
  final String? customName;

  /// mDNS `md` attribute when we last saw the device — e.g.
  /// "Google Nest Hub", "Chromecast Ultra", "LG OLED C2". Used to
  /// pick an icon.
  final String? modelHint;

  /// Unix millis of the last successful connection.
  final int lastSeenMillis;

  /// Last known address — lets the picker connect DIRECTLY when mDNS
  /// discovery is wedged (Android multicast flake, LG cast-stack hang).
  /// The TV's CASTV2 port answers even when its advertisements stop, so
  /// a saved address turns "can't see the TV" into a non-event. Null on
  /// entries saved before this field existed.
  final String? host;
  final int? port;

  const SavedCastDevice({
    required this.serviceName,
    required this.originalName,
    required this.lastSeenMillis,
    this.customName,
    this.modelHint,
    this.host,
    this.port,
  });

  /// What to show in the list: custom name if set, else original.
  String get displayName =>
      (customName != null && customName!.trim().isNotEmpty)
          ? customName!.trim()
          : originalName;

  SavedCastDevice copyWith({
    String? originalName,
    String? customName,
    String? modelHint,
    int? lastSeenMillis,
    String? host,
    int? port,
    bool clearCustomName = false,
  }) {
    return SavedCastDevice(
      serviceName: serviceName,
      originalName: originalName ?? this.originalName,
      customName: clearCustomName ? null : (customName ?? this.customName),
      modelHint: modelHint ?? this.modelHint,
      lastSeenMillis: lastSeenMillis ?? this.lastSeenMillis,
      host: host ?? this.host,
      port: port ?? this.port,
    );
  }

  Map<String, dynamic> toJson() => {
        'serviceName': serviceName,
        'originalName': originalName,
        if (customName != null) 'customName': customName,
        if (modelHint != null) 'modelHint': modelHint,
        'lastSeenMillis': lastSeenMillis,
        if (host != null) 'host': host,
        if (port != null) 'port': port,
      };

  factory SavedCastDevice.fromJson(Map<String, dynamic> json) {
    return SavedCastDevice(
      serviceName: json['serviceName'] as String,
      originalName: json['originalName'] as String? ?? '',
      customName: json['customName'] as String?,
      modelHint: json['modelHint'] as String?,
      lastSeenMillis: (json['lastSeenMillis'] as num?)?.toInt() ?? 0,
      host: json['host'] as String?,
      port: (json['port'] as num?)?.toInt(),
    );
  }
}

/// Heuristic: map an mDNS `md` model string to the right picker
/// icon. Chromecast broadcasts cover a zoo of products — this
/// covers the common ones and falls back to a generic cast icon.
IconData iconForModel(String? model) {
  if (model == null || model.trim().isEmpty) return Icons.cast;
  final m = model.toLowerCase();

  // TVs — LG WebOS, Sony Bravia, TCL/Hisense Android TV, generic
  // Chromecast-built-in sets.
  if (m.contains('tv') ||
      m.contains('bravia') ||
      m.contains('webos') ||
      m.contains('android tv') ||
      m.contains(' oled') ||
      m.startsWith('oled') ||
      m.contains('qled') ||
      m.contains('roku')) {
    return Icons.tv;
  }

  // Smart displays — Nest Hub, Nest Hub Max.
  if (m.contains('hub') || m.contains('display')) {
    return Icons.smart_display;
  }

  // Speakers — Google Home, Nest Mini, Nest Audio, Sonos, generic
  // "speaker" in the name.
  if (m.contains('home') ||
      m.contains('mini') ||
      m.contains('nest audio') ||
      m.contains('sonos') ||
      m.contains('speaker')) {
    return Icons.speaker;
  }

  // Chromecast dongle (generic "Chromecast" or "Chromecast Ultra").
  if (m.contains('chromecast')) {
    return Icons.cast;
  }

  return Icons.cast;
}
