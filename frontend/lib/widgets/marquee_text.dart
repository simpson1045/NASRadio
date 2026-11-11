import 'dart:async' show Timer;

import 'package:flutter/material.dart';

/// A one-line title that scrolls to show its end when it doesn't fit, ONCE:
/// a second after it appears (or the text changes), and again when the mouse
/// moves over it. Then it sits still.
///
/// Until Nov 9 this used the marquee package, which scrolls forever, playing
/// or paused (~80% of the time in motion, plus an always-on ShaderMask). On
/// Windows that is a full-window redraw 60 times a second for as long as a
/// long title is on screen: it alone kept FRAMEWORK hot with music paused.
class MarqueeText extends StatefulWidget {
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
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText> {
  final ScrollController _scroll = ScrollController();
  Timer? _startTimer;
  bool _scrolling = false;

  @override
  void initState() {
    super.initState();
    _scheduleScroll(const Duration(seconds: 1));
  }

  @override
  void didUpdateWidget(covariant MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _scheduleScroll(const Duration(seconds: 1));
    }
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _scheduleScroll(Duration delay) {
    _startTimer?.cancel();
    _startTimer = Timer(delay, _scrollOnce);
  }

  /// To the end at [velocity] px/s, hold, glide back to the start, stop.
  Future<void> _scrollOnce() async {
    if (!mounted || _scrolling || !_scroll.hasClients) return;
    final end = _scroll.position.maxScrollExtent;
    if (end <= 0) return;
    _scrolling = true;
    try {
      final ms = (end / widget.velocity * 1000).round();
      await _scroll.animateTo(end,
          duration: Duration(milliseconds: ms), curve: Curves.linear);
      await Future.delayed(widget.pauseDuration);
      if (!mounted || !_scroll.hasClients) return;
      await _scroll.animateTo(0,
          duration: const Duration(milliseconds: 700),
          curve: Curves.easeInOut);
    } catch (_) {
      // Disposed or detached mid-scroll.
    } finally {
      _scrolling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Measure with exactly what gets drawn. Text merges our style under the
    // inherited DefaultTextStyle, whose Material line height (~1.43) is taller
    // than the font's own, and applies the system font scale. Measuring the
    // bare style gave a box a few pixels shorter than the glyphs, and the part
    // that hung out was the descenders: the clipped "g" in every title long
    // enough to scroll.
    final effectiveStyle = DefaultTextStyle.of(context).style.merge(widget.style);
    final textScaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final textPainter = TextPainter(
          text: TextSpan(text: widget.text, style: effectiveStyle),
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
            widget.text,
            style: widget.style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        }

        return MouseRegion(
          onEnter: (_) => _scheduleScroll(Duration.zero),
          child: SizedBox(
            height: textHeight,
            width: containerWidth,
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: Text(
                widget.text,
                style: widget.style,
                maxLines: 1,
                softWrap: false,
              ),
            ),
          ),
        );
      },
    );
  }
}
