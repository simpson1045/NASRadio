import 'package:flutter/material.dart';
import '../models/album.dart';

/// "4 editions" marker for a collapsed edition-group card
/// (ALBUM_EDITIONS_SPEC.md §4, like Jellyfin's version count). The
/// surround icon flags a group with an Atmos or multichannel edition.
/// Ungrouped albums get nothing.
class EditionBadge extends StatelessWidget {
  final Album album;
  // Compact = icon + number on a dark pill, for sitting on artwork.
  final bool compact;

  const EditionBadge({super.key, required this.album, this.compact = false});

  /// [child] (an album's artwork) with the compact badge in its top-right
  /// corner. For fixed-size grid tiles, where an extra text line would
  /// overflow. Passthrough keeps the artwork's own sizing.
  static Widget over({required Album album, required Widget child}) {
    if (album.editionCount < 2) return child;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        Positioned(
          top: 6,
          right: 6,
          child: EditionBadge(album: album, compact: true),
        ),
      ],
    );
  }

  /// A list row's subtitle [text] followed by the full badge.
  static Widget after({required Album album, required Widget text}) {
    if (album.editionCount < 2) return text;
    return Row(
      children: [
        Flexible(child: text),
        const SizedBox(width: 6),
        EditionBadge(album: album),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (album.editionCount < 2) return const SizedBox.shrink();
    const cyan = Color(0xFF00d4ff);
    final spatial = album.editionHasAtmos || album.editionMaxChannels > 2;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: compact
            ? Colors.black.withOpacity(0.65)
            : cyan.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cyan.withOpacity(compact ? 0.7 : 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            spatial ? Icons.surround_sound : Icons.layers,
            size: 11,
            color: cyan,
          ),
          const SizedBox(width: 4),
          Text(
            compact
                ? '${album.editionCount}'
                : '${album.editionCount} editions',
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: cyan,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}
