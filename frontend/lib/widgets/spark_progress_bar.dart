import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'dart:math';

class SparkProgressBar extends StatefulWidget {
  final double progress;
  final Color progressColor;
  final Color backgroundColor;
  /// Sparks spawn only while active (playing); when it goes false the last
  /// sparks fade out and the bar stops animating entirely.
  final bool active;

  const SparkProgressBar({
    super.key,
    required this.progress,
    this.progressColor = const Color(0xFF00d4ff),
    this.backgroundColor = const Color(0xFF0d1b2a),
    this.active = true,
  });

  @override
  State<SparkProgressBar> createState() => _SparkProgressBarState();
}

class _SparkProgressBarState extends State<SparkProgressBar>
    with SingleTickerProviderStateMixin {
  // Runs only while active or while sparks are still fading (it used to be a
  // 24 h repeating controller that ran even when paused). The app-wide
  // TickerMode also mutes it while the app can't be seen.
  late final Ticker _ticker;
  final List<Spark> _sparks = [];
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) {
      _updateSparks();
      if (!widget.active && _sparks.isEmpty) _ticker.stop();
      if (mounted) setState(() {});
    });
    if (widget.active) _ticker.start();
  }

  @override
  void didUpdateWidget(SparkProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_ticker.isActive) _ticker.start();
  }

  void _updateSparks() {
    // Generate new sparks at the progress point
    if (widget.active && _random.nextDouble() < 0.3) {
      // 30% chance each frame
      _sparks.add(
        Spark(
          x: widget.progress,
          y: 0.5,
          velocityX: (_random.nextDouble() - 0.5) * 0.002,
          velocityY: (_random.nextDouble() - 0.8) * 0.01,
          life: 1.0,
          size: _random.nextDouble() * 2 + 1,
        ),
      );
    }

    // Update existing sparks
    _sparks.removeWhere((spark) {
      spark.update();
      return spark.life <= 0;
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: SparkProgressPainter(
        progress: widget.progress,
        sparks: _sparks,
        progressColor: widget.progressColor,
        backgroundColor: widget.backgroundColor,
      ),
      child: Container(height: 3),
    );
  }
}

class Spark {
  double x;
  double y;
  double velocityX;
  double velocityY;
  double life;
  double size;

  Spark({
    required this.x,
    required this.y,
    required this.velocityX,
    required this.velocityY,
    required this.life,
    required this.size,
  });

  void update() {
    x += velocityX;
    y += velocityY;
    velocityY += 0.0005; // Gravity
    life -= 0.02; // Fade out
  }
}

class SparkProgressPainter extends CustomPainter {
  final double progress;
  final List<Spark> sparks;
  final Color progressColor;
  final Color backgroundColor;

  SparkProgressPainter({
    required this.progress,
    required this.sparks,
    required this.progressColor,
    required this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Draw background bar
    final bgPaint = Paint()..color = backgroundColor;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    // Draw progress bar
    final progressPaint = Paint()..color = progressColor;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width * progress, size.height),
      progressPaint,
    );

    // Draw sparks
    for (var spark in sparks) {
      final sparkX = spark.x * size.width;
      final sparkY = spark.y * size.height;

      // Create gradient for glow effect
      final sparkPaint = Paint()
        ..color = progressColor.withOpacity(spark.life * 0.8)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);

      canvas.drawCircle(
        Offset(sparkX, sparkY),
        spark.size * spark.life,
        sparkPaint,
      );
    }
  }

  @override
  bool shouldRepaint(SparkProgressPainter oldDelegate) {
    return true; // Always repaint for animation
  }
}
