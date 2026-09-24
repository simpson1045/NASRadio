import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Shared visual primitives for the v1.1.0 refresh. Three components:
///
///   - [SectionHeader]: consistent title + optional "View all" pill +
///     optional accent bar + optional subtitle, used across every
///     dashboard/library/search row.
///
///   - [GradientBackdrop]: dominant-color vertical gradient that fades
///     to the page background, used behind album/artist/playlist hero
///     images on detail pages.
///
///   - [HoverCard]: small Material wrapper that adds a subtle border
///     highlight on hover and a brief scale-down on press. Use for
///     tap-targetable tiles (album covers, playlist tiles, etc.).
///
/// All three keep the existing dark-page color palette (deep navy
/// background, cyan 0xFF00d4ff accent) so adoption is incremental —
/// new screens use these; old screens migrate over time.

/// Accent color used across the design system. Matches the existing
/// app primary so the new system feels like a polish, not a rewrite.
const Color kAccent = Color(0xFF00d4ff);
const Color kPageBg = Color(0xFF0d1b2a);
const Color kCardBg = Color(0xFF1a2332);
const Color kCardBorder = Color(0xFF2a3a4a);

// ============================================================================
// SectionHeader
// ============================================================================

/// Consistent header for a content section ("Coming Soon", "Recently
/// Played", etc.). Replaces the ad-hoc `_buildSectionHeader` helpers
/// scattered through dashboard_screen.dart / podcast_discovery_screen.dart /
/// settings_dialog.dart so every section looks the same.
///
/// Visual:
///   ┃ Title text 24pt bold white  •  (optional subtitle)        View all >
///   ┃
///   ^ optional cyan accent bar (4px wide)
///
/// Use:
/// ```dart
/// SectionHeader('Coming Soon', onViewAll: () => ...);
/// SectionHeader(
///   'Recently Played',
///   subtitle: '${songs.length} tracks',
///   icon: Icons.history,
///   onViewAll: () => ...,
/// );
/// ```
class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final VoidCallback? onViewAll;
  final Color accentColor;
  final bool showAccentBar;
  final EdgeInsetsGeometry padding;

  const SectionHeader(
    this.title, {
    super.key,
    this.subtitle,
    this.icon,
    this.onViewAll,
    this.accentColor = kAccent,
    this.showAccentBar = true,
    this.padding = const EdgeInsets.fromLTRB(16, 16, 16, 8),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (showAccentBar) ...[
            Container(
              width: 4,
              height: 26,
              decoration: BoxDecoration(
                color: accentColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 12),
          ],
          if (icon != null) ...[
            Icon(icon, color: accentColor, size: 22),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: -0.2,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white54,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (onViewAll != null)
            _ViewAllPill(onPressed: onViewAll!, accentColor: accentColor),
        ],
      ),
    );
  }
}

class _ViewAllPill extends StatelessWidget {
  final VoidCallback onPressed;
  final Color accentColor;

  const _ViewAllPill({required this.onPressed, required this.accentColor});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'View all',
                style: TextStyle(
                  color: accentColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.chevron_right, color: accentColor, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// GradientBackdrop
// ============================================================================

/// Renders a vertical gradient backdrop from a dominant color fading
/// down to the page background. Used behind album / artist / playlist
/// hero images so the page color subtly echoes the artwork instead of
/// being a stark dark slab.
///
/// Use:
/// ```dart
/// GradientBackdrop(
///   dominantColor: _dominantColor,
///   child: Column(children: [
///     // hero image, title, etc.
///   ]),
/// );
/// ```
///
/// For dominant-color extraction itself, use [extractDominantColor]
/// below (or the existing PaletteGenerator usage in artist_detail_screen.dart).
class GradientBackdrop extends StatelessWidget {
  final Color dominantColor;
  final Widget child;
  final double height;
  // 0 = fully fade out at bottom; 1 = no fade at all. Default 0 (full
  // fade to the page background so content below the backdrop reads
  // cleanly without an abrupt color seam).
  final double fadeStrength;

  const GradientBackdrop({
    super.key,
    required this.dominantColor,
    required this.child,
    this.height = 420,
    this.fadeStrength = 0.0,
  });

  @override
  Widget build(BuildContext context) {
    // Blend the dominant color toward the page bg so vivid covers
    // (think Frankenstrat red) don't burn out the eyes — pulls toward
    // the brand palette while still echoing the artwork.
    final tinted = Color.lerp(dominantColor, kPageBg, 0.35)!;
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  tinted,
                  Color.lerp(tinted, kPageBg, 1.0 - fadeStrength)!,
                  kPageBg,
                ],
                stops: const [0.0, 0.65, 1.0],
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// Extracts a representative dominant color from a network image.
/// Returns null on failure (network error, decode failure, etc.) so
/// callers can fall back to a neutral default.
///
/// Implementation samples the center pixel via the Image decoder. For
/// most album/artist artwork this is "close enough" — true k-means
/// clustering (via PaletteGenerator) is more accurate but heavier.
/// Use this helper when you want a fast cheap dominant color; use
/// PaletteGenerator when you want the best result.
Future<Color?> extractDominantColor(ImageProvider provider) async {
  try {
    final completer = Completer<ui.Image>();
    final stream = provider.resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(info.image);
        stream.removeListener(listener);
      },
      onError: (e, _) {
        if (!completer.isCompleted) completer.completeError(e);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    final image = await completer.future;
    // Sample center pixel for a "good enough" dominant.
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return null;
    final bytes = byteData.buffer.asUint8List();
    final cx = image.width ~/ 2;
    final cy = image.height ~/ 2;
    final offset = (cy * image.width + cx) * 4;
    if (offset + 3 >= bytes.length) return null;
    return Color.fromARGB(
      bytes[offset + 3],
      bytes[offset],
      bytes[offset + 1],
      bytes[offset + 2],
    );
  } catch (_) {
    return null;
  }
}

// ============================================================================
// HoverCard
// ============================================================================

/// Wraps any tap-targetable widget with hover and press feedback:
///   - On hover: subtle cyan border + slight elevation shadow
///   - On press: brief scale-down to 0.97 then back
///
/// Use anywhere a tile or card behaves like a button — album covers,
/// playlist tiles, quick-access tiles, etc. Replaces the bare
/// `GestureDetector` + `Container` pattern in dozens of places with
/// consistent interaction feedback.
///
/// Use:
/// ```dart
/// HoverCard(
///   onTap: () => Navigator.push(...),
///   borderRadius: BorderRadius.circular(8),
///   child: ...tile content...,
/// );
/// ```
class HoverCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final BorderRadius borderRadius;
  final Color? hoverBorderColor;

  const HoverCard({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.hoverBorderColor,
  });

  @override
  State<HoverCard> createState() => _HoverCardState();
}

class _HoverCardState extends State<HoverCard>
    with SingleTickerProviderStateMixin {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final border = widget.hoverBorderColor ?? kAccent;
    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              borderRadius: widget.borderRadius,
              border: Border.all(
                color: _hovered ? border.withOpacity(0.6) : Colors.transparent,
                width: 1.5,
              ),
              boxShadow: _hovered
                  ? [
                      BoxShadow(
                        color: border.withOpacity(0.18),
                        blurRadius: 12,
                        spreadRadius: -2,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: ClipRRect(
              borderRadius: widget.borderRadius,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
