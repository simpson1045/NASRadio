import 'package:flutter/material.dart';
import '../models/song_chapter.dart';

/// Full-height scrollable chapter list as a bottom sheet. Better than the
/// horizontal strip for episodes with 20+ chapters (ASOT: 29 tracks) where
/// scrolling sideways to find one specific track is painful.
///
/// Active chapter is highlighted; tapping any chapter seeks to it and
/// closes the sheet. Skippable (ad) chapters are tagged with a red AD
/// badge. Chapter image is shown as a 48px thumbnail when the feed's
/// chapter JSON provides one.
class ChaptersSheet extends StatelessWidget {
  final List<SongChapter> chapters;
  final Duration currentPosition;
  final Future<void> Function(Duration target) onSeek;

  const ChaptersSheet({
    super.key,
    required this.chapters,
    required this.currentPosition,
    required this.onSeek,
  });

  /// Convenience launcher — shows the sheet and returns once it closes.
  static Future<void> show(
    BuildContext context, {
    required List<SongChapter> chapters,
    required Duration currentPosition,
    required Future<void> Function(Duration) onSeek,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChaptersSheet(
        chapters: chapters,
        currentPosition: currentPosition,
        onSeek: onSeek,
      ),
    );
  }

  int _activeIndex() {
    final seconds = currentPosition.inSeconds;
    for (var i = chapters.length - 1; i >= 0; i--) {
      if (seconds >= chapters[i].startTimeSeconds) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final activeIdx = _activeIndex();
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      minChildSize: 0.3,
      expand: false,
      builder: (context, controller) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF0d1b2a),
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              // Drag handle
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Row(
                  children: [
                    const Icon(Icons.list_alt, color: Color(0xFFff8c42)),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Chapters',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '${chapters.length}',
                      style: const TextStyle(color: Colors.white60, fontSize: 14),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Colors.white12),
              Expanded(
                child: ListView.builder(
                  controller: controller,
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).viewPadding.bottom + 16,
                  ),
                  itemCount: chapters.length,
                  itemBuilder: (context, i) {
                    final chapter = chapters[i];
                    final isActive = i == activeIdx;
                    return InkWell(
                      onTap: () async {
                        Navigator.pop(context);
                        await onSeek(Duration(seconds: chapter.startTimeSeconds));
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        color: isActive
                            ? const Color(0xFFff8c42).withValues(alpha: 0.12)
                            : null,
                        child: Row(
                          children: [
                            // Leading: chapter image if present, else number
                            _ChapterLeading(chapter: chapter, index: i, isActive: isActive),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        chapter.startTimeFormatted,
                                        style: TextStyle(
                                          color: isActive
                                              ? const Color(0xFFff8c42)
                                              : Colors.white60,
                                          fontSize: 12,
                                          fontFeatures: const [FontFeature.tabularFigures()],
                                        ),
                                      ),
                                      if (chapter.isSkippable) ...[
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: Colors.redAccent
                                                .withValues(alpha: 0.25),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: const Text(
                                            'AD',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    chapter.title ?? 'Chapter ${i + 1}',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: isActive
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (isActive)
                              const Icon(
                                Icons.graphic_eq,
                                color: Color(0xFFff8c42),
                                size: 20,
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ChapterLeading extends StatelessWidget {
  final SongChapter chapter;
  final int index;
  final bool isActive;

  const _ChapterLeading({
    required this.chapter,
    required this.index,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    final hasImage = (chapter.imageUrl?.isNotEmpty ?? false);
    if (hasImage) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.network(
          chapter.imageUrl!,
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fallback(),
          loadingBuilder: (_, child, progress) =>
              progress == null ? child : _fallback(),
        ),
      );
    }
    return _fallback();
  }

  Widget _fallback() {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: isActive
            ? const Color(0xFFff8c42).withValues(alpha: 0.15)
            : const Color(0xFF1e2a3a),
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Text(
        '${index + 1}',
        style: TextStyle(
          color: isActive ? const Color(0xFFff8c42) : Colors.white60,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    );
  }
}
