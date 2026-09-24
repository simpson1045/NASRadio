import 'package:flutter/material.dart';
import 'package:marquee/marquee.dart' as m;

class MarqueeText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final double velocity;
  final Duration pauseDuration;

  const MarqueeText({
    super.key,
    required this.text,
    this.style,
    this.velocity = 40.0,
    this.pauseDuration = const Duration(seconds: 2),
  });

  @override
  Widget build(BuildContext context) {
    // Measure with exactly what gets drawn. Text (and the Marquee package's
    // Text) merges our style under the inherited DefaultTextStyle, whose
    // Material line height (~1.43) is taller than the font's own, and applies
    // the system font scale. Measuring the bare style gave a box a few pixels
    // shorter than the glyphs, and the part that hung out was the descenders:
    // the clipped "g" in every title long enough to scroll.
    final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
    final textScaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final textPainter = TextPainter(
          text: TextSpan(text: text, style: effectiveStyle),
          maxLines: 1,
          textDirection: direction,
          textScaler: textScaler,
        )..layout();

        final textWidth = textPainter.width;
        // Whole pixels plus a little headroom: some faces draw descenders a
        // hair past their reported line box.
        final textHeight = textPainter.height.ceilToDouble() + 4;
        textPainter.dispose();
        final containerWidth = constraints.maxWidth;

        // No scroll needed
        if (textWidth <= containerWidth || containerWidth <= 0) {
          return Text(
            text,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        }

        return SizedBox(
          height: textHeight,
          width: containerWidth,
          child: m.Marquee(
            text: text,
            style: style,
            velocity: velocity,
            blankSpace: 50,
            pauseAfterRound: pauseDuration,
            startAfter: const Duration(seconds: 1),
            fadingEdgeStartFraction: 0,
            fadingEdgeEndFraction: 0,
          ),
        );
      },
    );
  }
}
