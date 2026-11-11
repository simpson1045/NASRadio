import 'dart:async' show Timer;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
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
  /// Song id for the EVH stripes: each song gets its own (stable) pattern.
  final int evhSeed;
  final bool liveSeek;
  /// Music is playing: the glow pulse runs every frame. Paused: it breathes
  /// at 20 fps instead.
  final bool isPlaying;

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
    this.evhSeed = 0,
    this.liveSeek = true,
    this.isPlaying = true,
  });

  @override
  State<WaveformProgressBar> createState() => _WaveformProgressBarState();
}

class _WaveformProgressBarState extends State<WaveformProgressBar>
    with SingleTickerProviderStateMixin {
  double? _dragPosition;
  double? _dragX; // X position for tooltip
  late final Ticker _pulseTicker;
  Timer? _pulseTimer;
  final ValueNotifier<double> _pulse = ValueNotifier<double>(0.0);
  final Stopwatch _pulseClock = Stopwatch()..start();
  bool _tickersEnabled = true;
  Duration _lastKnownPosition = Duration.zero;
  DateTime _lastUpdateTime = DateTime.now();

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    _lastKnownPosition = widget.position;
    _lastUpdateTime = DateTime.now();
    // Glow pulse while playing: a ticker, so TickerMode (hidden section,
    // minimized window) mutes it for free.
    _pulseTicker = createTicker((_) => _pulse.value = _pulseNow());
  }

  // No progress clock here any more. Until Nov 9 a 24 h AnimationController
  // repeated forever on desktop from the moment the bar appeared, playing or
  // paused, but _smoothPosition is capped at widget.position, so all it did
  // was repaint the same picture 60 times a second (FRAMEWORK: ~17% GPU plus
  // the compositor, running hot, whole-machine freezes). The parent hands in
  // a new position every frame while playing; that is what moves the bar.

  bool get _wantsPulse =>
      !_isMobile &&
      (widget.lightsaberMode || widget.dnaMode || widget.evhStripesMode);

  /// Triangle wave 0 -> 1 -> 0 over 1.6 s, the old 800 ms repeat(reverse).
  double _pulseNow() {
    final t = (_pulseClock.elapsedMilliseconds % 1600) / 800.0;
    return t <= 1.0 ? t : 2.0 - t;
  }

  /// Playing: pulse every frame (the frame is drawn for the progress anyway).
  /// Paused: a slow breathe at 20 fps. Hidden, or a plain song: still.
  void _syncPulse() {
    final on = _wantsPulse && _tickersEnabled;
    if (on && widget.isPlaying) {
      if (!_pulseTicker.isActive) _pulseTicker.start();
    } else if (_pulseTicker.isActive) {
      _pulseTicker.stop();
    }
    if (on && !widget.isPlaying) {
      _pulseTimer ??= Timer.periodic(
        const Duration(milliseconds: 50),
        (_) => _pulse.value = _pulseNow(),
      );
    } else {
      _pulseTimer?.cancel();
      _pulseTimer = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // TickerMode off = hidden section or minimized window. A Timer isn't
    // muted by TickerMode on its own, so stop the breathe here too.
    _tickersEnabled = TickerMode.of(context);
    _syncPulse();
  }

  @override
  void didUpdateWidget(WaveformProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Update when we get new position from audio player
    if (widget.position != oldWidget.position) {
      _lastKnownPosition = widget.position;
      _lastUpdateTime = DateTime.now();
    }
    _syncPulse();
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
    _pulseTicker.dispose();
    _pulse.dispose();
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
    // Only the glow pulse animates in here; progress comes from the parent.
    if (!_wantsPulse) return _buildCustomPaint();
    return AnimatedBuilder(
      animation: _pulse,
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
        pulseValue: _wantsPulse ? _pulse.value : 0.0,
        dnaMode: widget.dnaMode,
        evhStripesMode: widget.evhStripesMode,
        evhSeed: widget.evhSeed,
        isMobile: _isMobile,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
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
  final int evhSeed;
  final bool isMobile;
  final double devicePixelRatio;

  WaveformPainter({
    required this.waveformData,
    required this.progress,
    this.lightsaberMode = false,
    this.lightsaberColor = const Color(0xFF4488ff),
    this.pulseValue = 0.0,
    this.dnaMode = false,
    this.evhStripesMode = false,
    this.evhSeed = 0,
    this.isMobile = false,
    this.devicePixelRatio = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (waveformData.isEmpty || size.isEmpty) return;

    final width = size.width;
    final centerY = size.height / 2;
    final maxAmplitude = size.height / 2;

    // Reserve space for hilt if in lightsaber mode - smaller on mobile
    final hiltWidth = lightsaberMode ? (isMobile ? 90.0 : 200.0) : 0.0;
    final bladeStartX = hiltWidth;
    final bladeWidth = width - hiltWidth;

    // The complete waveform outline (~2 points per sample). Normal mode only
    // builds it when its cached images need redrawing (new song or size).
    Path buildPath() {
      final path = Path();
      path.moveTo(bladeStartX, centerY);

      // Top half
      for (int i = 0; i < waveformData.length; i++) {
        final x = bladeStartX + (i / waveformData.length) * bladeWidth;
        final amplitude = waveformData[i] * maxAmplitude;
        path.lineTo(x, centerY - amplitude);
      }

      // Bottom half (mirrored)
      for (int i = waveformData.length - 1; i >= 0; i--) {
        final x = bladeStartX + (i / waveformData.length) * bladeWidth;
        final amplitude = waveformData[i] * maxAmplitude;
        path.lineTo(x, centerY + amplitude);
      }
      path.close();
      return path;
    }

    if (lightsaberMode) {
      // ===== LIGHTSABER MODE =====
      final waveformPath = buildPath();

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
      // The waveform is drawn ONCE per song and size into two images (played
      // colour, unplayed colour); each frame only shows a slice of each. Until
      // Nov 9 the ~2000-point outline was rebuilt and filled twice on every
      // frame of the 60 fps scrubber.
      final images = _WaveformImages.of(
          waveformData, size, devicePixelRatio, buildPath);
      final src = Rect.fromLTWH(0, 0, images.played.width.toDouble(),
          images.played.height.toDouble());
      final dst = Offset.zero & size;
      final imagePaint = Paint()..filterQuality = FilterQuality.medium;

      // Played portion (clipped)
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, 0, width * progress, size.height));
      canvas.drawImageRect(images.played, src, dst, imagePaint);
      canvas.restore();

      // Unplayed portion (clipped)
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(width * progress, 0, width * (1 - progress), size.height),
      );
      canvas.drawImageRect(images.unplayed, src, dst, imagePaint);
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
        oldDelegate.evhSeed != evhSeed ||
        oldDelegate.isMobile != isMobile ||
        oldDelegate.devicePixelRatio != devicePixelRatio;
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

    // Frankenstrat stripes — the same seeded generator as the Van Halen
    // artist page (and the cast receiver's evhStripes): random spots,
    // angles and widths, one stripe per ~40 px of width. The old fixed
    // table was laid out for a 1120 px canvas and had its x positions
    // scaled down to fit, so a phone got all 24 full-width stripes crammed
    // together as a few fat, regular zigzags with no red. Angles stop at
    // ~69° off vertical: steeper smears into a flat line on a bar this thin.
    // Per-song seed (same formula as the receiver's evhStripes, so a song
    // looks the same on the phone and the TV at the same bar width).
    int seed = (0x5EED ^ (evhSeed * 2654435761)) & 0x7fffffff;
    if (seed == 0) seed = 0x5EED;
    double rnd() {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed / 0x7fffffff;
    }

    // Jittered slots: one stripe somewhere inside each equal slice of the
    // bar, so pure chance can't leave a stretch bare (it bunched up and
    // left the start of the bar nearly plain red).
    final n = math.max(8, (width / 32).round());
    final slot = (width + 40) / n;
    // (isBlack, width, x, y, angle): generated in slot order with the same
    // draw sequence as the receiver, then painted white first, black on top.
    final stripes = <(bool, double, double, double, double)>[];
    for (var i = 0; i < n; i++) {
      final isBlack = rnd() >= 9 / 16;
      final w = isBlack ? 12 + rnd() * 9 : 7 + rnd() * 6;
      final x = -20 + (i + rnd()) * slot;
      final y = rnd() * size.height;
      final angle = (rnd() - 0.5) * 2.4;
      stripes.add((isBlack, w, x, y, angle));
    }
    for (final black in [false, true]) {
      for (final (isBlack, w, x, y, angle) in stripes) {
        if (isBlack != black) continue;
        canvas.save();
        canvas.translate(x, y);
        canvas.rotate(angle);
        canvas.drawRect(
          Rect.fromCenter(center: Offset.zero, width: w, height: size.height * 6),
          Paint()..color = isBlack ? evhBlack : evhWhite,
        );
        canvas.restore();
      }
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

/// Normal-mode waveform rendered once into two images at device resolution
/// (played + unplayed colours). One entry: only one waveform is on screen at a
/// time. A new song (new data list), a resize or a DPI change re-renders it.
class _WaveformImages {
  _WaveformImages._(this.data, this.size, this.dpr, this.played, this.unplayed);

  final List<double> data;
  final Size size;
  final double dpr;
  final ui.Image played;
  final ui.Image unplayed;

  static _WaveformImages? _last;

  static _WaveformImages of(
    List<double> data,
    Size size,
    double dpr,
    Path Function() buildPath,
  ) {
    final cached = _last;
    if (cached != null &&
        identical(cached.data, data) &&
        cached.size == size &&
        cached.dpr == dpr) {
      return cached;
    }
    final path = buildPath();
    final w = (size.width * dpr).ceil();
    final h = (size.height * dpr).ceil();
    ui.Image render(Color color) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.scale(dpr);
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.fill,
      );
      final picture = recorder.endRecording();
      final image = picture.toImageSync(w, h);
      picture.dispose();
      return image;
    }

    final next = _WaveformImages._(
      data,
      size,
      dpr,
      render(const Color(0xFF00d4ff)),
      render(const Color(0xFF2a3f5f)),
    );
    // Safe while an old frame still shows them: a picture keeps its images
    // alive until it is gone too.
    cached?.played.dispose();
    cached?.unplayed.dispose();
    _last = next;
    return next;
  }
}
