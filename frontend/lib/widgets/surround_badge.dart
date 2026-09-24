import 'package:flutter/material.dart';

import '../models/song.dart';

/// "DOLBY ATMOS" pill for E-AC-3 JOC tracks — Dolby blue, mirrors the TV
/// receiver's badge.
class AtmosBadge extends StatelessWidget {
  final double fontSize;

  const AtmosBadge({super.key, this.fontSize = 9});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFF1E64B4).withOpacity(0.35),
        border: Border.all(color: const Color(0xFF4FC3F7), width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        'ATMOS',
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          color: const Color(0xFFE8F4FF),
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// "5.1" / "5.0" pill for plain multichannel tracks — teal, mirrors the TV.
class SurroundBadge extends StatelessWidget {
  final String label;
  final double fontSize;

  const SurroundBadge({super.key, required this.label, this.fontSize = 9});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFF4DD0E1).withOpacity(0.15),
        border: Border.all(color: const Color(0xFF4DD0E1), width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          color: const Color(0xFF4DD0E1),
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Convenience: the right spatial badge for a song, or nothing.
/// Drop next to HdcdBadge wherever track badges render.
class SpatialBadge extends StatelessWidget {
  final Song song;
  final double fontSize;

  const SpatialBadge({super.key, required this.song, this.fontSize = 9});

  @override
  Widget build(BuildContext context) {
    if (song.isAtmos) return AtmosBadge(fontSize: fontSize);
    if (song.isSurround) {
      return SurroundBadge(label: song.surroundLabel, fontSize: fontSize);
    }
    return const SizedBox.shrink();
  }
}
