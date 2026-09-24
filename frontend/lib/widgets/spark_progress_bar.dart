import 'package:flutter/material.dart';
import 'dart:math';

class SparkProgressBar extends StatefulWidget {
  final double progress;
  final Color progressColor;
  final Color backgroundColor;

  const SparkProgressBar({
    super.key,
    required this.progress,
    this.progressColor = const Color(0xFF00d4ff),
    this.backgroundColor = const Color(0xFF0d1b2a),
  });

  @override
  State<SparkProgressBar> createState() => _SparkProgressBarState();
}

class _SparkProgressBarState extends State<SparkProgressBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  final List<Spark> _sparks = [];
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _animationController =
        AnimationController(vsync: this, duration: const Duration(hours: 24))
          ..addListener(() {
            _updateSparks();
            if (mounted) setState(() {});
          });
    _animationController.repeat();
  }

  void _updateSparks() {
    // Generate new sparks at the progress point
    if (_random.nextDouble() < 0.3) {
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
    _animationController.dispose();
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
