import 'package:flutter/material.dart';
import '../models/song_chapter.dart';

/// Horizontal scrollable strip of podcast chapters shown on the Now Playing
/// screen. Tap a chapter to seek. The currently-active chapter is
/// highlighted based on the player's playback position.
///
/// Silently renders nothing when the chapter list is empty — callers can
/// always drop it into the layout without guarding.
class ChapterStrip extends StatefulWidget {
  final List<SongChapter> chapters;
  final Duration position;
  final Future<void> Function(Duration target) onSeek;

  const ChapterStrip({
    super.key,
    required this.chapters,
    required this.position,
    required this.onSeek,
  });

  @override
  State<ChapterStrip> createState() => _ChapterStripState();
}

class _ChapterStripState extends State<ChapterStrip> {
  final ScrollController _scroll = ScrollController();
  int? _lastAutoScrolledIndex;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  int _currentChapterIndex() {
    final seconds = widget.position.inSeconds;
    for (var i = widget.chapters.length - 1; i >= 0; i--) {
      if (seconds >= widget.chapters[i].startTimeSeconds) return i;
    }
    return 0;
  }

  @override
  void didUpdateWidget(ChapterStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Auto-scroll the active chapter into view when it changes.
    if (!_scroll.hasClients) return;
    final idx = _currentChapterIndex();
    if (_lastAutoScrolledIndex == idx) return;
    _lastAutoScrolledIndex = idx;
    // Approximate width — chapters are variable but centering is best-effort.
    const double estimatedWidth = 240.0;
    final target = (idx * estimatedWidth) - 100.0;
    final clamped = target.clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(
      clamped,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.chapters.isEmpty) return const SizedBox.shrink();

    final activeIdx = _currentChapterIndex();

    return SizedBox(
      height: 72,
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: widget.chapters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final chapter = widget.chapters[i];
          final isActive = i == activeIdx;
          final baseColor = chapter.isSkippable
              ? const Color(0xFF3a1a1a) // Dim red for ads
              : const Color(0xFF1e2a3a);
          final activeColor = chapter.isSkippable
              ? const Color(0xFF6b2020)
              : const Color(0xFFff8c42); // NASRadio podcast orange
          final border = isActive
              ? const Color(0xFFff8c42)
              : Colors.white12;
          return InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => widget.onSeek(Duration(seconds: chapter.startTimeSeconds)),
            child: Container(
              constraints: const BoxConstraints(minWidth: 160, maxWidth: 320),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isActive ? activeColor : baseColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: border, width: 1.5),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        chapter.startTimeFormatted,
                        style: TextStyle(
                          color: isActive ? Colors.white : const Color(0xFF9aa5b4),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (chapter.isSkippable) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'AD',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    chapter.title ?? 'Chapter ${i + 1}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isActive ? Colors.white : Colors.white70,
                      fontSize: 13,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
