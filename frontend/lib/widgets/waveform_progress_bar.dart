import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'dart:io' show Platform;

class WaveformProgressBar extends StatefulWidget {
  final List<double> waveformData;
  final Duration position;
  final Duration duration;
  final Function(Duration) onSeek;
  final bool lightsaberMode;
  final Color? lightsaberColor;
  final bool dnaMode;
  final bool evhStripesMode;
  final bool liveSeek;

  const WaveformProgressBar({
    super.key,
    required this.waveformData,
    required this.position,
    required this.duration,
    required this.onSeek,
    this.lightsaberMode = false,
    this.lightsaberColor,
    this.dnaMode = false,
    this.evhStripesMode = false,
    this.liveSeek = true,
  });

  @override
  State<WaveformProgressBar> createState() => _WaveformProgressBarState();
}

class _WaveformProgressBarState extends State<WaveformProgressBar>
    with TickerProviderStateMixin {
  double? _dragPosition;
  double? _dragX; // X position for tooltip
  AnimationController? _smoothController;
  AnimationController? _pulseController;
  Duration _lastKnownPosition = Duration.zero;
  DateTime _lastUpdateTime = DateTime.now();

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    _lastKnownPosition = widget.position;
    _lastUpdateTime = DateTime.now();

    // Only use smooth animation on desktop - mobile relies on position updates
    if (!_isMobile) {
      _smoothController = AnimationController(
        vsync: this,
        duration: const Duration(hours: 24),
      )..repeat();
    }

    // Start pulse animation if in lightsaber mode, DNA mode, or EVH mode (desktop only for performance)
    if (!_isMobile &&
        (widget.lightsaberMode || widget.dnaMode || widget.evhStripesMode)) {
      _startPulseAnimation();
    }
  }

  void _startPulseAnimation() {
    if (_isMobile) return; // Skip pulse animation on mobile for performance
    _pulseController?.dispose();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  void _stopPulseAnimation() {
    _pulseController?.dispose();
    _pulseController = null;
  }

  @override
  void didUpdateWidget(WaveformProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Update when we get new position from audio player
    if (widget.position != oldWidget.position) {
      _lastKnownPosition = widget.position;
      _lastUpdateTime = DateTime.now();
    }

    // Handle lightsaber mode changes (desktop only)
    if (!_isMobile) {
      if (widget.lightsaberMode && !oldWidget.lightsaberMode) {
        _startPulseAnimation();
      } else if (!widget.lightsaberMode &&
          oldWidget.lightsaberMode &&
          !widget.dnaMode &&
          !widget.evhStripesMode) {
        _stopPulseAnimation();
      }

      // Handle DNA mode changes
      if (widget.dnaMode && !oldWidget.dnaMode) {
        _startPulseAnimation();
      } else if (!widget.dnaMode &&
          oldWidget.dnaMode &&
          !widget.lightsaberMode &&
          !widget.evhStripesMode) {
        _stopPulseAnimation();
      }

      // Handle EVH stripes mode changes
      if (widget.evhStripesMode && !oldWidget.evhStripesMode) {
        _startPulseAnimation();
      } else if (!widget.evhStripesMode &&
          oldWidget.evhStripesMode &&
          !widget.lightsaberMode &&
          !widget.dnaMode) {
        _stopPulseAnimation();
      }
    }
  }

  @override
  void dispose() {
    _smoothController?.dispose();
    _pulseController?.dispose();
    super.dispose();
  }

  Duration get _smoothPosition {
    if (_dragPosition != null) {
      return Duration(milliseconds: _dragPosition!.toInt());
    }

    final now = DateTime.now();
    final elapsed = now.difference(_lastUpdateTime);
    final smoothPos = _lastKnownPosition + elapsed;

    // Don't go past actual position or duration
    if (smoothPos > widget.position) {
      return widget.position;
    }
    if (smoothPos > widget.duration) {
      return widget.duration;
    }
    return smoothPos;
  }

  @override
  Widget build(BuildContext context) {
    // Calculate hilt width for lightsaber mode
    final hiltWidth = widget.lightsaberMode ? (_isMobile ? 90.0 : 200.0) : 0.0;

    return GestureDetector(
      onTapDown: (details) {
        final box = context.findRenderObject() as RenderBox;
        final localPosition = box.globalToLocal(details.globalPosition);
        final width = box.size.width;
        final bladeWidth = width - hiltWidth;

        // If tap is on the hilt, seek to beginning
        if (localPosition.dx <= hiltWidth) {
          widget.onSeek(Duration.zero);
          return;
        }

        // Calculate percent based on blade area only
        final bladeX = localPosition.dx - hiltWidth;
        final percent = (bladeX / bladeWidth).clamp(0.0, 1.0);
        final newPosition = widget.duration * percent;
        widget.onSeek(newPosition);
      },
      onHorizontalDragStart: (details) {
        final box = context.findRenderObject() as RenderBox;
        final localPosition = box.globalToLocal(details.globalPosition);
        final width = box.size.width;
        final bladeWidth = width - hiltWidth;

        final bladeX = (localPosition.dx - hiltWidth).clamp(0.0, bladeWidth);
        final percent = bladeX / bladeWidth;
        final newPosition = widget.duration.inMilliseconds * percent;
        setState(() {
          _dragPosition = newPosition;
          _dragX = localPosition.dx;
        });
        if (widget.liveSeek) {
          widget.onSeek(Duration(milliseconds: newPosition.toInt()));
        }
      },
      onHorizontalDragUpdate: (details) {
        final box = context.findRenderObject() as RenderBox;
        final localPosition = box.globalToLocal(details.globalPosition);
        final width = box.size.width;
        final bladeWidth = width - hiltWidth;

        final bladeX = (localPosition.dx - hiltWidth).clamp(0.0, bladeWidth);
        final percent = bladeX / bladeWidth;
        final newPosition = widget.duration.inMilliseconds * percent;

        final shouldSeek =
            widget.liveSeek &&
            (_dragPosition == null ||
                (newPosition - _dragPosition!).abs() > 500);

        setState(() {
          _dragPosition = newPosition;
          _dragX = localPosition.dx;
        });

        if (shouldSeek) {
          widget.onSeek(Duration(milliseconds: newPosition.toInt()));
        }
      },
      onHorizontalDragEnd: (details) {
        if (_dragPosition != null) {
          widget.onSeek(Duration(milliseconds: _dragPosition!.toInt()));
          setState(() {
            _dragPosition = null;
            _dragX = null;
          });
        }
      },
      child: RepaintBoundary(
        child: SizedBox(
          height: 80,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: _buildAnimatedPaint(),
              ),
              // Timestamp tooltip while dragging
              if (_dragPosition != null && _dragX != null)
                Positioned(
                  left: _dragX! - 30,
                  top: -28,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1a2332),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: const Color(0xFF00d4ff),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      _formatDuration(
                        Duration(milliseconds: _dragPosition!.toInt()),
                      ),
                      style: const TextStyle(
                        color: Color(0xFF00d4ff),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAnimatedPaint() {
    // Combine listenables for efficient rebuilds - only rebuilds CustomPaint, not entire widget tree
    final List<Listenable> listenables = [];
    if (_smoothController != null) listenables.add(_smoothController!);
    if (_pulseController != null) listenables.add(_pulseController!);

    if (listenables.isEmpty) {
      // No animations - just build static paint
      return _buildCustomPaint();
    }

    return AnimatedBuilder(
      animation: listenables.length == 1
          ? listenables.first
          : Listenable.merge(listenables),
      builder: (context, child) => _buildCustomPaint(),
    );
  }

  Widget _buildCustomPaint() {
    // On mobile, use direct position (no smooth interpolation for performance)
    // On desktop, use smooth interpolation for buttery progress
    final progress = widget.duration.inMilliseconds > 0
        ? (_isMobile
                  ? widget.position.inMilliseconds
                  : _smoothPosition.inMilliseconds) /
              widget.duration.inMilliseconds
        : 0.0;

    return CustomPaint(
      painter: WaveformPainter(
        waveformData: widget.waveformData,
        progress: _dragPosition != null
            ? _dragPosition! / widget.duration.inMilliseconds
            : progress,
        lightsaberMode: widget.lightsaberMode,
        lightsaberColor: widget.lightsaberColor ?? const Color(0xFF4488ff),
        pulseValue: _pulseController?.value ?? 0.0,
        dnaMode: widget.dnaMode,
        evhStripesMode: widget.evhStripesMode,
        isMobile: _isMobile,
      ),
      size: Size.infinite,
    );
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    final seconds = d.inSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

class WaveformPainter extends CustomPainter {
  final List<double> waveformData;
  final double progress;
  final bool lightsaberMode;
  final Color lightsaberColor;
  final double pulseValue;
  final bool dnaMode;
  final bool evhStripesMode;
  final bool isMobile;

  WaveformPainter({
    required this.waveformData,
    required this.progress,
    this.lightsaberMode = false,
    this.lightsaberColor = const Color(0xFF4488ff),
    this.pulseValue = 0.0,
    this.dnaMode = false,
    this.evhStripesMode = false,
    this.isMobile = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (waveformData.isEmpty) return;

    final width = size.width;
    final centerY = size.height / 2;
    final maxAmplitude = size.height / 2;

    // Reserve space for hilt if in lightsaber mode - smaller on mobile
    final hiltWidth = lightsaberMode ? (isMobile ? 90.0 : 200.0) : 0.0;
    final bladeStartX = hiltWidth;
    final bladeWidth = width - hiltWidth;

    // Build the complete waveform path once
    final waveformPath = Path();
    waveformPath.moveTo(bladeStartX, centerY);

    // Top half
    for (int i = 0; i < waveformData.length; i++) {
      final x = bladeStartX + (i / waveformData.length) * bladeWidth;
      final amplitude = waveformData[i] * maxAmplitude;
      waveformPath.lineTo(x, centerY - amplitude);
    }

    // Bottom half (mirrored)
    for (int i = waveformData.length - 1; i >= 0; i--) {
      final x = bladeStartX + (i / waveformData.length) * bladeWidth;
      final amplitude = waveformData[i] * maxAmplitude;
      waveformPath.lineTo(x, centerY + amplitude);
    }
    waveformPath.close();

    if (lightsaberMode) {
      // ===== LIGHTSABER MODE =====

      // Bright white core color
      final coreColor = Color.lerp(lightsaberColor, Colors.white, 0.7)!;

      // Draw unplayed portion first (dark, no glow)
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(
          bladeStartX + bladeWidth * progress,
          0,
          bladeWidth * (1 - progress),
          size.height,
        ),
      );
      final unplayedPaint = Paint()
        ..color = const Color(0xFF1a2332)
        ..style = PaintingStyle.fill;
      canvas.drawPath(waveformPath, unplayedPaint);
      canvas.restore();

      // Draw played portion with glow layers
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(bladeStartX, 0, bladeWidth * progress, size.height),
      );

      // Pulsing glow intensity - MORE PRONOUNCED
      final pulseIntensity = 0.7 + (pulseValue * 0.3);
      final pulseBlur = 8 + (pulseValue * 8); // 8-16 blur

      // Outer glow (widest, most transparent) - PULSING
      final outerGlowPaint = Paint()
        ..color = lightsaberColor.withOpacity(0.2 * pulseIntensity)
        ..style = PaintingStyle.fill
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, pulseBlur);
      canvas.drawPath(waveformPath, outerGlowPaint);

      // Middle glow - ALSO PULSING
      final middleGlowPaint = Paint()
        ..color = lightsaberColor.withOpacity(0.3 * pulseIntensity)
        ..style = PaintingStyle.fill
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 + (pulseValue * 2));
      canvas.drawPath(waveformPath, middleGlowPaint);

      // Inner glow (tighter) - ALSO PULSING
      final innerGlowPaint = Paint()
        ..color = lightsaberColor.withOpacity(0.6 * pulseIntensity)
        ..style = PaintingStyle.fill
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 + (pulseValue * 1));
      canvas.drawPath(waveformPath, innerGlowPaint);

      // Bright core - PULSING BRIGHTNESS
      final coreBrightness = 0.6 + (pulseValue * 0.15); // 0.6 to 0.75
      final corePaint = Paint()
        ..color = Color.lerp(lightsaberColor, Colors.white, coreBrightness)!
        ..style = PaintingStyle.fill;
      canvas.drawPath(waveformPath, corePaint);

      canvas.restore();

      // Draw a glowing "blade edge" line at the progress point
      if (progress > 0 && progress < 1) {
        final edgeX = bladeStartX + bladeWidth * progress;

        // Outer edge glow
        final edgeGlowPaint = Paint()
          ..color = lightsaberColor.withOpacity(0.5)
          ..strokeWidth = 6
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
        canvas.drawLine(
          Offset(edgeX, 0),
          Offset(edgeX, size.height),
          edgeGlowPaint,
        );

        // Bright edge core
        final edgeCorePaint = Paint()
          ..color = coreColor
          ..strokeWidth = 2;
        canvas.drawLine(
          Offset(edgeX, 0),
          Offset(edgeX, size.height),
          edgeCorePaint,
        );
      }

      // ===== DRAW LIGHTSABER HILT =====
      _drawHilt(canvas, size, centerY, hiltWidth, lightsaberColor, pulseValue);
    } else if (dnaMode) {
      // ===== DNA HELIX MODE =====
      _drawDnaHelix(canvas, size, progress, pulseValue);
    } else if (evhStripesMode) {
      // ===== EVH FRANKENSTEIN STRIPES MODE =====
      _drawEvhStripes(canvas, size, progress, pulseValue, waveformData);
    } else {
      // ===== NORMAL MODE =====

      // Draw played portion (clipped)
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, 0, width * progress, size.height));
      final playedPaint = Paint()
        ..color = const Color(0xFF00d4ff)
        ..style = PaintingStyle.fill;
      canvas.drawPath(waveformPath, playedPaint);
      canvas.restore();

      // Draw unplayed portion (clipped)
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(width * progress, 0, width * (1 - progress), size.height),
      );
      final unplayedPaint = Paint()
        ..color = const Color(0xFF2a3f5f)
        ..style = PaintingStyle.fill;
      canvas.drawPath(waveformPath, unplayedPaint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(WaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.waveformData != waveformData ||
        oldDelegate.lightsaberMode != lightsaberMode ||
        oldDelegate.lightsaberColor != lightsaberColor ||
        oldDelegate.pulseValue != pulseValue ||
        oldDelegate.dnaMode != dnaMode ||
        oldDelegate.evhStripesMode != evhStripesMode ||
        oldDelegate.isMobile != isMobile;
  }

  void _drawHilt(
    Canvas canvas,
    Size size,
    double centerY,
    double hiltWidth,
    Color bladeColor,
    double pulseValue,
  ) {
    // Hilt dimensions - sleek and detailed
    final hiltHeight = size.height * 0.5;
    final hiltTop = centerY - hiltHeight / 2;
    final hiltBottom = centerY + hiltHeight / 2;

    // Determine hilt style based on blade color
    final isRedSaber = bladeColor.red > 200 && bladeColor.green < 100;
    final isPurpleSaber = bladeColor.red > 150 && bladeColor.blue > 200;

    // Base colors for different saber styles
    final darkMetal = isRedSaber
        ? const Color(0xFF1a1a1a)
        : const Color(0xFF3a3a3a);
    final lightMetal = isRedSaber
        ? const Color(0xFF404040)
        : const Color(0xFFa0a0a0);
    final chromeMetal = isPurpleSaber
        ? const Color(0xFFc9a227)
        : const Color(0xFFc0c0c0);
    final darkAccent = const Color(0xFF202020);

    if (isMobile) {
      // Mobile hilt with recognizable lightsaber shape (90px width)

      // === POMMEL (rounded end cap) ===
      final pommelRadius = hiltHeight / 2;
      canvas.drawCircle(
        Offset(pommelRadius + 2, centerY),
        pommelRadius,
        Paint()..color = darkMetal,
      );
      // Pommel highlight
      canvas.drawCircle(
        Offset(pommelRadius, centerY - 3),
        pommelRadius * 0.3,
        Paint()..color = lightMetal.withOpacity(0.4),
      );

      // === GRIP SECTION (with ridges) ===
      final gripStart = pommelRadius * 1.8;
      final gripEnd = 50.0;
      canvas.drawRect(
        Rect.fromLTRB(gripStart, hiltTop + 2, gripEnd, hiltBottom - 2),
        Paint()..color = darkMetal,
      );
      // Grip ridges
      final ridgePaint = Paint()
        ..color = darkAccent
        ..strokeWidth = 1.5;
      for (double x = gripStart + 3; x < gripEnd - 2; x += 4) {
        canvas.drawLine(
          Offset(x, hiltTop + 3),
          Offset(x, hiltBottom - 3),
          ridgePaint,
        );
      }

      // === ACTIVATION BOX ===
      final activationStart = gripEnd;
      final activationEnd = 68.0;
      final activationRect = RRect.fromRectAndRadius(
        Rect.fromLTRB(activationStart, hiltTop, activationEnd, hiltBottom),
        const Radius.circular(2),
      );
      canvas.drawRRect(activationRect, Paint()..color = lightMetal);

      // Power button (glowing)
      final buttonX = (activationStart + activationEnd) / 2;
      final buttonPulse = 0.6 + (pulseValue * 0.4);
      canvas.drawCircle(
        Offset(buttonX, centerY),
        3 + (pulseValue * 2),
        Paint()
          ..color = bladeColor.withOpacity(buttonPulse)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            2 + (pulseValue * 3),
          ),
      );
      canvas.drawCircle(
        Offset(buttonX, centerY),
        2.5,
        Paint()..color = Color.lerp(bladeColor, Colors.white, 0.7)!,
      );

      // === EMITTER SHROUD ===
      final emitterStart = activationEnd;
      final emitterEnd = hiltWidth - 2;
      final emitterRect = RRect.fromRectAndRadius(
        Rect.fromLTRB(emitterStart, hiltTop - 1, emitterEnd, hiltBottom + 1),
        const Radius.circular(2),
      );
      canvas.drawRRect(
        emitterRect,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(0, hiltTop),
            Offset(0, hiltBottom),
            [
              chromeMetal.withOpacity(0.7),
              chromeMetal,
              chromeMetal.withOpacity(0.7),
            ],
            [0.0, 0.5, 1.0],
          ),
      );
      // Emitter ring
      canvas.drawLine(
        Offset(emitterEnd - 4, hiltTop - 1),
        Offset(emitterEnd - 4, hiltBottom + 1),
        Paint()
          ..color = darkAccent
          ..strokeWidth = 1.5,
      );

      // Emission glow
      final emissionPulse = 0.3 + (pulseValue * 0.4);
      canvas.drawRect(
        Rect.fromLTRB(
          emitterEnd - 2,
          hiltTop + 4,
          hiltWidth + 4,
          hiltBottom - 4,
        ),
        Paint()
          ..color = bladeColor.withOpacity(emissionPulse)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            3 + (pulseValue * 4),
          ),
      );
      return;
    }

    // === POMMEL (rounded end cap) ===
    final pommelRadius = hiltHeight / 2 + 2;
    canvas.drawCircle(
      Offset(pommelRadius, centerY),
      pommelRadius,
      Paint()..color = darkMetal,
    );
    // Pommel highlight
    canvas.drawCircle(
      Offset(pommelRadius - 3, centerY - 4),
      pommelRadius * 0.35,
      Paint()..color = lightMetal.withOpacity(0.5),
    );

    // === GRIP SECTION (with ridges) ===
    final gripStart = pommelRadius * 1.5;
    final gripEnd = 110.0;
    final gripRect = RRect.fromRectAndRadius(
      Rect.fromLTRB(gripStart, hiltTop, gripEnd, hiltBottom),
      const Radius.circular(2),
    );
    canvas.drawRRect(gripRect, Paint()..color = darkMetal);

    // Grip ridges (vertical lines for texture)
    final ridgePaint = Paint()
      ..color = darkAccent
      ..strokeWidth = 2;
    for (double x = gripStart + 4; x < gripEnd - 2; x += 5) {
      canvas.drawLine(
        Offset(x, hiltTop + 1),
        Offset(x, hiltBottom - 1),
        ridgePaint,
      );
    }

    // === ACTIVATION BOX ===
    final activationStart = gripEnd;
    final activationEnd = 144.0;
    final activationRect = RRect.fromRectAndRadius(
      Rect.fromLTRB(
        activationStart,
        hiltTop - 2,
        activationEnd,
        hiltBottom + 2,
      ),
      const Radius.circular(2),
    );
    canvas.drawRRect(activationRect, Paint()..color = lightMetal);

    // Activation box border
    canvas.drawRRect(
      activationRect,
      Paint()
        ..color = darkAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    // Power button (glowing with pulse) - MORE VISIBLE
    final buttonX = (activationStart + activationEnd) / 2;
    final buttonPulse = 0.6 + (pulseValue * 0.4);
    canvas.drawCircle(
      Offset(buttonX, centerY),
      4 + (pulseValue * 3),
      Paint()
        ..color = bladeColor.withOpacity(buttonPulse)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 + (pulseValue * 5)),
    );
    canvas.drawCircle(
      Offset(buttonX, centerY),
      3,
      Paint()..color = Color.lerp(bladeColor, Colors.white, 0.7)!,
    );

    // === NECK SECTION ===
    final neckStart = activationEnd;
    final neckEnd = 168.0;
    canvas.drawRect(
      Rect.fromLTRB(neckStart, hiltTop + 2, neckEnd, hiltBottom - 2),
      Paint()..color = darkMetal,
    );

    // === EMITTER SHROUD ===
    final emitterStart = neckEnd;
    final emitterEnd = hiltWidth - 2;

    // Main emitter body
    final emitterRect = RRect.fromRectAndRadius(
      Rect.fromLTRB(emitterStart, hiltTop - 1, emitterEnd, hiltBottom + 1),
      const Radius.circular(2),
    );
    // Chrome gradient
    final emitterPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, hiltTop),
        Offset(0, hiltBottom),
        [
          chromeMetal.withOpacity(0.7),
          chromeMetal,
          chromeMetal.withOpacity(0.8),
        ],
        [0.0, 0.5, 1.0],
      );
    canvas.drawRRect(emitterRect, emitterPaint);

    // Emitter rings
    final ringPaint = Paint()
      ..color = darkAccent
      ..strokeWidth = 1.5;
    canvas.drawLine(
      Offset(emitterStart + 3, hiltTop - 1),
      Offset(emitterStart + 3, hiltBottom + 1),
      ringPaint,
    );
    canvas.drawLine(
      Offset(emitterEnd - 3, hiltTop - 1),
      Offset(emitterEnd - 3, hiltBottom + 1),
      ringPaint,
    );

    // === BLADE EMISSION GLOW === (pulsing) - MORE VISIBLE
    final emissionPulse = 0.3 + (pulseValue * 0.4);
    final emissionGlow = Paint()
      ..color = bladeColor.withOpacity(emissionPulse)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 + (pulseValue * 6));
    canvas.drawRect(
      Rect.fromLTRB(emitterEnd - 2, hiltTop + 2, hiltWidth + 6, hiltBottom - 2),
      emissionGlow,
    );
  }

  void _drawDnaHelix(
    Canvas canvas,
    Size size,
    double progress,
    double pulseValue,
  ) {
    final width = size.width;
    final height = size.height;
    final centerY = height / 2;

    // DNA colors - Jurassic Park style
    const Color dnaBlue = Color(0xFF00a8ff);
    const Color dnaYellow = Color(0xFFffd000);
    const Color dnaPurple = Color(0xFFa855f7);
    const Color dnaUnplayed = Color(0xFF2a3f5f);

    // Helix parameters
    final amplitude = height * 0.35;
    final frequency = 0.025;
    final phaseShift = pulseValue * 0.5;

    // Number of rungs (base pairs)
    final rungSpacing = 20.0;
    final numRungs = (width / rungSpacing).ceil();

    // Draw unplayed background first
    final unplayedPath1 = Path();
    final unplayedPath2 = Path();

    for (double x = 0; x <= width; x += 2) {
      final phase = x * frequency + phaseShift;
      final y1 = centerY + amplitude * _sineWave(phase);
      final y2 = centerY + amplitude * _sineWave(phase + 3.14159);

      if (x == 0) {
        unplayedPath1.moveTo(x, y1);
        unplayedPath2.moveTo(x, y2);
      } else {
        unplayedPath1.lineTo(x, y1);
        unplayedPath2.lineTo(x, y2);
      }
    }

    // Draw unplayed strands (darker)
    final unplayedPaint = Paint()
      ..color = dnaUnplayed
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(unplayedPath1, unplayedPaint);
    canvas.drawPath(unplayedPath2, unplayedPaint);

    // Draw unplayed rungs
    for (int i = 0; i < numRungs; i++) {
      final x = i * rungSpacing;
      final phase = x * frequency + phaseShift;
      final y1 = centerY + amplitude * _sineWave(phase);
      final y2 = centerY + amplitude * _sineWave(phase + 3.14159);

      canvas.drawLine(
        Offset(x, y1),
        Offset(x, y2),
        Paint()
          ..color = dnaUnplayed.withOpacity(0.5)
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }

    // Now draw the played portion (clipped)
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, width * progress, height));

    // Played strand 1 (blue with glow)
    final playedPath1 = Path();
    for (double x = 0; x <= width; x += 2) {
      final phase = x * frequency + phaseShift;
      final y1 = centerY + amplitude * _sineWave(phase);

      if (x == 0) {
        playedPath1.moveTo(x, y1);
      } else {
        playedPath1.lineTo(x, y1);
      }
    }

    // Glow for strand 1
    final glow1 = Paint()
      ..color = dnaBlue.withOpacity(0.4 + pulseValue * 0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawPath(playedPath1, glow1);

    // Core strand 1
    final strand1Paint = Paint()
      ..color = dnaBlue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(playedPath1, strand1Paint);

    // Played strand 2 (purple with glow)
    final playedPath2 = Path();
    for (double x = 0; x <= width; x += 2) {
      final phase = x * frequency + phaseShift;
      final y2 = centerY + amplitude * _sineWave(phase + 3.14159);

      if (x == 0) {
        playedPath2.moveTo(x, y2);
      } else {
        playedPath2.lineTo(x, y2);
      }
    }

    // Glow for strand 2
    final glow2 = Paint()
      ..color = dnaPurple.withOpacity(0.4 + pulseValue * 0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawPath(playedPath2, glow2);

    // Core strand 2
    final strand2Paint = Paint()
      ..color = dnaPurple
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(playedPath2, strand2Paint);

    // Draw played rungs (yellow with glow)
    for (int i = 0; i < numRungs; i++) {
      final x = i * rungSpacing;
      final phase = x * frequency + phaseShift;
      final y1 = centerY + amplitude * _sineWave(phase);
      final y2 = centerY + amplitude * _sineWave(phase + 3.14159);

      // Rung glow
      canvas.drawLine(
        Offset(x, y1),
        Offset(x, y2),
        Paint()
          ..color = dnaYellow.withOpacity(0.5 + pulseValue * 0.3)
          ..strokeWidth = 6
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );

      // Rung core
      canvas.drawLine(
        Offset(x, y1),
        Offset(x, y2),
        Paint()
          ..color = dnaYellow
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }

    canvas.restore();

    // Draw progress indicator line
    if (progress > 0 && progress < 1) {
      final progressX = width * progress;
      final phase = progressX * frequency + phaseShift;
      final y1 = centerY + amplitude * _sineWave(phase);
      final y2 = centerY + amplitude * _sineWave(phase + 3.14159);

      // Bright line at progress point
      canvas.drawLine(
        Offset(progressX, y1 - 5),
        Offset(progressX, y2 + 5),
        Paint()
          ..color = Colors.white.withOpacity(0.8)
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  void _drawEvhStripes(
    Canvas canvas,
    Size size,
    double progress,
    double pulseValue,
    List<double> waveformData,
  ) {
    if (waveformData.isEmpty) return;

    final width = size.width;
    final centerY = size.height / 2;
    final maxAmplitude = size.height / 2;

    // EVH Frankenstein colors
    const Color evhRed = Color(0xFFE31937);
    const Color evhWhite = Color(0xFFFFFFFF);
    const Color evhBlack = Color(0xFF000000);
    const Color unplayedColor = Color(0xFF2a3f5f);

    // Build the waveform path
    final waveformPath = Path();
    waveformPath.moveTo(0, centerY);

    // Top half
    for (int i = 0; i < waveformData.length; i++) {
      final x = (i / waveformData.length) * width;
      final amplitude = waveformData[i] * maxAmplitude;
      waveformPath.lineTo(x, centerY - amplitude);
    }

    // Bottom half (mirrored)
    for (int i = waveformData.length - 1; i >= 0; i--) {
      final x = (i / waveformData.length) * width;
      final amplitude = waveformData[i] * maxAmplitude;
      waveformPath.lineTo(x, centerY + amplitude);
    }
    waveformPath.close();

    // Draw unplayed portion first
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(width * progress, 0, width * (1 - progress), size.height),
    );
    canvas.drawPath(waveformPath, Paint()..color = unplayedColor);
    canvas.restore();

    // Draw played portion with EVH stripes
    canvas.save();
    canvas.clipPath(waveformPath);
    canvas.clipRect(Rect.fromLTWH(0, 0, width * progress, size.height));

    // Red base
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width, size.height),
      Paint()..color = evhRed,
    );

    // Stripe positions below are absolute pixel offsets, tuned for a
    // ~1120-pixel canvas. On ultrawide displays at fullscreen the widget
    // can be 1900+ pixels wide, leaving the right portion stripeless
    // (solid red base only). Scale x positions by the actual width to
    // stretch the pattern across the full canvas. Stripe widths/angles
    // stay constant so individual stripes look the same — pattern just
    // becomes slightly more open on wide screens, denser on narrow.
    const double evhDesignWidth = 1120.0;
    final double stripeScale = width / evhDesignWidth;

    // Define stripe patterns - chaotic angles like the real Frankenstein
    final stripes = <Map<String, dynamic>>[
      // Black stripes
      {'color': evhBlack, 'x': -20.0, 'angle': 0.4, 'width': 18.0},
      {'color': evhBlack, 'x': 60.0, 'angle': -0.6, 'width': 22.0},
      {'color': evhBlack, 'x': 150.0, 'angle': 0.3, 'width': 16.0},
      {'color': evhBlack, 'x': 240.0, 'angle': -0.5, 'width': 20.0},
      {'color': evhBlack, 'x': 350.0, 'angle': 0.7, 'width': 18.0},
      {'color': evhBlack, 'x': 450.0, 'angle': -0.4, 'width': 24.0},
      {'color': evhBlack, 'x': 550.0, 'angle': 0.5, 'width': 16.0},
      {'color': evhBlack, 'x': 650.0, 'angle': -0.3, 'width': 20.0},
      {'color': evhBlack, 'x': 750.0, 'angle': 0.6, 'width': 18.0},
      {'color': evhBlack, 'x': 850.0, 'angle': -0.5, 'width': 22.0},
      {'color': evhBlack, 'x': 950.0, 'angle': 0.4, 'width': 16.0},
      {'color': evhBlack, 'x': 1050.0, 'angle': -0.6, 'width': 20.0},
      // White stripes
      {'color': evhWhite, 'x': 20.0, 'angle': -0.5, 'width': 10.0},
      {'color': evhWhite, 'x': 100.0, 'angle': 0.6, 'width': 8.0},
      {'color': evhWhite, 'x': 200.0, 'angle': -0.4, 'width': 12.0},
      {'color': evhWhite, 'x': 300.0, 'angle': 0.5, 'width': 10.0},
      {'color': evhWhite, 'x': 400.0, 'angle': -0.7, 'width': 8.0},
      {'color': evhWhite, 'x': 500.0, 'angle': 0.4, 'width': 12.0},
      {'color': evhWhite, 'x': 600.0, 'angle': -0.6, 'width': 10.0},
      {'color': evhWhite, 'x': 700.0, 'angle': 0.3, 'width': 8.0},
      {'color': evhWhite, 'x': 800.0, 'angle': -0.5, 'width': 10.0},
      {'color': evhWhite, 'x': 900.0, 'angle': 0.6, 'width': 12.0},
      {'color': evhWhite, 'x': 1000.0, 'angle': -0.4, 'width': 8.0},
      {'color': evhWhite, 'x': 1100.0, 'angle': 0.5, 'width': 10.0},
    ];

    // Draw each stripe
    for (final stripe in stripes) {
      final color = stripe['color'] as Color;
      final x = stripe['x'] as double;
      final angle = stripe['angle'] as double;
      final stripeWidth = stripe['width'] as double;

      canvas.save();
      canvas.translate(x * stripeScale, centerY);
      canvas.rotate(angle);

      canvas.drawRect(
        Rect.fromCenter(
          center: Offset.zero,
          width: stripeWidth,
          height: size.height * 3,
        ),
        Paint()..color = color,
      );
      canvas.restore();
    }

    canvas.restore();

    // Add subtle glow on the progress edge
    if (progress > 0 && progress < 1) {
      final edgeX = width * progress;
      final glowIntensity = 0.5 + (pulseValue * 0.3);

      // Red glow at edge
      canvas.drawLine(
        Offset(edgeX, 0),
        Offset(edgeX, size.height),
        Paint()
          ..color = evhRed.withOpacity(glowIntensity)
          ..strokeWidth = 6
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );

      // White core line
      canvas.drawLine(
        Offset(edgeX, 0),
        Offset(edgeX, size.height),
        Paint()
          ..color = evhWhite
          ..strokeWidth = 2,
      );
    }
  }

  double _sineWave(double x) {
    return math.sin(x);
  }
}
