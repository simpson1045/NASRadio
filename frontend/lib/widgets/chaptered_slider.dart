import 'package:flutter/material.dart';
import '../models/song_chapter.dart';

/// A Material `Slider` with small vertical tick marks painted at each
/// chapter's start position. Used on Now Playing for podcast episodes
/// so the user can see where the ~29 tracks of an ASOT mix start at a
/// glance, instead of having to scrub blindly.
///
/// If the chapters list is empty the overlay paints nothing — you can
/// use this widget unconditionally in place of the plain Slider.
class ChapteredSlider extends StatelessWidget {
  final double value;
  final double max;
  final ValueChanged<double>? onChanged;
  final List<SongChapter> chapters;
  final Color activeTrackColor;
  final Color inactiveTrackColor;
  final Color thumbColor;
  final Color tickColor;
  final Color skippableTickColor;
  final double trackHeight;

  const ChapteredSlider({
    super.key,
    required this.value,
    required this.max,
    required this.onChanged,
    required this.chapters,
    required this.activeTrackColor,
    required this.inactiveTrackColor,
    required this.thumbColor,
    this.tickColor = Colors.white70,
    this.skippableTickColor = Colors.redAccent,
    this.trackHeight = 4,
  });

  @override
  Widget build(BuildContext context) {
    final slider = SliderTheme(
      data: SliderThemeData(
        trackHeight: trackHeight,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        activeTrackColor: activeTrackColor,
        inactiveTrackColor: inactiveTrackColor,
        thumbColor: thumbColor,
        overlayColor: activeTrackColor.withValues(alpha: 0.2),
      ),
      child: Slider(
        value: value.clamp(0, max <= 0 ? 1 : max),
        max: max <= 0 ? 1 : max,
        onChanged: onChanged,
      ),
    );

    if (chapters.isEmpty || max <= 0) return slider;

    // Stack the tick overlay BEHIND the slider so the thumb, active track
    // color, and overlay halo paint on top. IgnorePointer keeps the
    // slider's gesture handling intact.
    return Stack(
      alignment: Alignment.center,
      children: [
        Padding(
          // Match the Slider's default horizontal padding — thumb radius
          // plus overlay radius — so ticks align with the track, not the
          // widget's outer edge. Approximate; the visual alignment is
          // close enough that a pixel or two either way is invisible.
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: IgnorePointer(
            child: SizedBox(
              height: trackHeight + 6,
              child: CustomPaint(
                painter: _ChapterTickPainter(
                  chapters: chapters,
                  max: max,
                  trackHeight: trackHeight,
                  tickColor: tickColor,
                  skippableTickColor: skippableTickColor,
                ),
                size: const Size.fromHeight(10),
              ),
            ),
          ),
        ),
        slider,
      ],
    );
  }
}

class _ChapterTickPainter extends CustomPainter {
  final List<SongChapter> chapters;
  final double max;
  final double trackHeight;
  final Color tickColor;
  final Color skippableTickColor;

  _ChapterTickPainter({
    required this.chapters,
    required this.max,
    required this.trackHeight,
    required this.tickColor,
    required this.skippableTickColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final tickHalfHeight = trackHeight / 2 + 3; // extends 3px above/below the track
    final centerY = size.height / 2;
    for (final chapter in chapters) {
      // Skip ticks at t=0 (visually indistinguishable from the track start)
      // and anything past the reported duration.
      final t = chapter.startTimeSeconds.toDouble();
      if (t <= 0 || t >= max) continue;
      final x = (t / max) * size.width;
      final paint = Paint()
        ..color = chapter.isSkippable ? skippableTickColor : tickColor
        ..strokeWidth = 2;
      canvas.drawLine(
        Offset(x, centerY - tickHalfHeight),
        Offset(x, centerY + tickHalfHeight),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ChapterTickPainter oldDelegate) {
    return oldDelegate.chapters != chapters ||
        oldDelegate.max != max ||
        oldDelegate.trackHeight != trackHeight ||
        oldDelegate.tickColor != tickColor ||
        oldDelegate.skippableTickColor != skippableTickColor;
  }
}
