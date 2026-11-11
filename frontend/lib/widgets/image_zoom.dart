import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Full-screen pinch-zoom for artwork (album, artist, Now Playing, playlist,
/// release preview). Pass an [imageUrl], or any [child] widget (e.g. a
/// playlist's 2x2 cover mosaic). The zoom surface fills the whole screen so
/// zooming is never clipped to the image's own box. Pinch 1x-6x, double-tap
/// toggles 2.5x at the tapped point, single tap / ✕ / remote OK closes.
Future<void> showImageZoom(BuildContext context, {String? imageUrl, Widget? child}) {
  assert(imageUrl != null || child != null);
  return Navigator.of(context).push(
    PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (_, __, ___) => _ImageZoomPage(imageUrl: imageUrl, child: child),
      transitionsBuilder: (_, animation, __, page) =>
          FadeTransition(opacity: animation, child: page),
    ),
  );
}

class _ImageZoomPage extends StatefulWidget {
  final String? imageUrl;
  final Widget? child;

  const _ImageZoomPage({this.imageUrl, this.child});

  @override
  State<_ImageZoomPage> createState() => _ImageZoomPageState();
}

class _ImageZoomPageState extends State<_ImageZoomPage> {
  final _transform = TransformationController();
  Offset _doubleTapAt = Offset.zero;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    if (_transform.value.getMaxScaleOnAxis() > 1.01) {
      _transform.value = Matrix4.identity();
      return;
    }
    const scale = 2.5;
    final p = _doubleTapAt;
    _transform.value = Matrix4.identity()
      ..translateByDouble(-p.dx * (scale - 1), -p.dy * (scale - 1), 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // Decode cap: sharp enough to zoom into, without decoding a 3000px
    // embedded cover at full size on the UI thread (the old Now Playing
    // full-artwork freeze).
    final cachePx = math.min(
      2400,
      (math.max(mq.size.width, mq.size.height) * mq.devicePixelRatio * 1.5).ceil(),
    );
    final content = widget.child ??
        CachedNetworkImage(
          imageUrl: widget.imageUrl!,
          fit: BoxFit.contain,
          memCacheWidth: cachePx,
          placeholder: (_, __) =>
              const CircularProgressIndicator(color: Color(0xFF00d4ff)),
          errorWidget: (_, __, ___) =>
              const Icon(Icons.broken_image, color: Colors.grey, size: 64),
        );

    return FocusableActionDetector(
      autofocus: true,
      // Fire TV / keyboard: OK or Esc closes (nothing else is focusable here).
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            Navigator.of(context).pop();
            return null;
          },
        ),
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            Navigator.of(context).pop();
            return null;
          },
        ),
      },
      child: Material(
        color: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
                onDoubleTap: _toggleZoom,
                child: InteractiveViewer(
                  transformationController: _transform,
                  minScale: 1.0,
                  maxScale: 6.0,
                  clipBehavior: Clip.none,
                  child: SizedBox.expand(child: Center(child: content)),
                ),
              ),
            ),
            Positioned(
              top: mq.padding.top + 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 30),
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
