// ─────────────────────────────────────────────────────────────────────────────
// LIQUID GLASS — the app's shared surface language, modelled on Apple's
// iOS 26 "Liquid Glass" material. Flutter can't use the native UIKit
// material, so it's rebuilt here from the same ingredients:
//
//   1. a colourful ambient backdrop (GlassBackdrop) -- glass only reads as
//      glass when there's something behind it to refract;
//   2. a backdrop blur clipped to an Apple squircle (RoundedSuperellipseBorder);
//   3. a translucent top-lit fill, optionally tinted (e.g. a habit's colour);
//   4. a specular rim -- bright along the top-left edge where the "light"
//      hits, fading through the sides, faintly catching again bottom-right.
//
// Everything here is self-contained (no dependency on main.dart) and adapts
// to light/dark via Theme.of(context).brightness.
// ─────────────────────────────────────────────────────────────────────────────
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

/// Base canvas colours behind the glass. AppColors.bg in main.dart mirrors
/// these so the loading screen cross-fades into a page without a flash.
const Color kGlassBaseDark = Color(0xFF07070C);
const Color kGlassBaseLight = Color(0xFFEFF1F7);

/// Default orb palette for the backdrop -- the app's own preset colours.
const List<Color> kGlassOrbColors = [
  Color(0xFF5490D7), // blue
  Color(0xFFA054D7), // purple
  Color(0xFFD7546C), // red
  Color(0xFF547B66), // green
];

bool _isDark(BuildContext context) => Theme.of(context).brightness == Brightness.dark;

// ─────────────────────────────────────────────────────────────────────────────
// BACKDROP
// ─────────────────────────────────────────────────────────────────────────────

/// Full-screen ambient background: a dark/light base with a few large, soft
/// colour orbs. Wraps [child] in a [BackdropGroup] so every [Glass] on the
/// page shares one backdrop read instead of each card re-reading the screen.
///
/// The orbs are static (painted once, behind a RepaintBoundary) on purpose:
/// animating them would force every blurred surface on top to re-blur every
/// frame.
class GlassBackdrop extends StatelessWidget {
  final Widget child;
  final List<Color> colors;

  const GlassBackdrop({required this.child, this.colors = kGlassOrbColors, super.key});

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: CustomPaint(
            painter: _OrbPainter(colors: colors, dark: dark),
          ),
        ),
        BackdropGroup(child: child),
      ],
    );
  }
}

class _OrbPainter extends CustomPainter {
  final List<Color> colors;
  final bool dark;

  _OrbPainter({required this.colors, required this.dark});

  // (x, y) as a fraction of the canvas, radius as a fraction of the longest
  // side. Laid out so a phone in either orientation always has colour behind
  // the top bar, the middle of the list, and the bottom.
  static const _orbs = [
    (0.05, 0.08, 0.62),
    (0.98, 0.30, 0.55),
    (0.10, 0.78, 0.58),
    (0.85, 0.98, 0.50),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = dark ? kGlassBaseDark : kGlassBaseLight);
    if (colors.isEmpty) return;
    final longest = size.longestSide;
    final alpha = dark ? 0.42 : 0.48;
    for (var i = 0; i < _orbs.length; i++) {
      final (fx, fy, fr) = _orbs[i];
      final color = colors[i % colors.length];
      final center = Offset(size.width * fx, size.height * fy);
      final radius = longest * fr;
      final paint = Paint()
        ..shader = ui.Gradient.radial(
          center,
          radius,
          [color.withValues(alpha: alpha), color.withValues(alpha: alpha * 0.35), color.withValues(alpha: 0)],
          const [0.0, 0.45, 1.0],
        );
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.dark != dark || !_listEquals(old.colors, colors);

  static bool _listEquals(List<Color> a, List<Color> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// GLASS SURFACE
// ─────────────────────────────────────────────────────────────────────────────

/// Which glass "material" a [Glass] surface renders as.
enum GlassStyle {
  /// The app's standard liquid glass: top-lit sheen, a specular rim that
  /// follows the light around the shape, and a soft drop shadow.
  liquid,

  /// A frosted pane after photographed glass: diffuse inner glow, an even
  /// thin rim with sharp glints riding the edges, and almost no shadow.
  /// Used for the NOPE button.
  pane,
}

/// Apple-style continuous-corner ("squircle") shape used for glass panels.
ShapeBorder glassRounded(double radius) =>
    RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius));

/// A liquid-glass panel.
///
/// * [tint] washes the glass in a colour (top-left strongest), at
///   [tintStrength] opacity -- used for habit cards and prominent buttons.
/// * [frost] (0-1) thickens the glass for legibility over busy content --
///   dialogs and sheets use ~0.6, cards sitting on the backdrop use 0.
/// * [blur] is the backdrop-blur sigma. Pass 0 for small elements nested
///   inside another glass panel (chips, swatches): the parent already
///   blurred what's behind them, so a second blur only costs frames.
/// * [style] picks the material -- see [GlassStyle].
class Glass extends StatelessWidget {
  final Widget? child;
  final ShapeBorder shape;
  final EdgeInsetsGeometry? padding;
  final Color? tint;
  final double tintStrength;
  final double frost;
  final double blur;
  final double rim;
  final List<BoxShadow>? shadows;
  final GlassStyle style;

  const Glass({
    this.child,
    this.shape = const RoundedSuperellipseBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
    this.padding,
    this.tint,
    this.tintStrength = 0.2,
    this.frost = 0,
    this.blur = 22,
    this.rim = 1,
    this.shadows,
    this.style = GlassStyle.liquid,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    final pane = style == GlassStyle.pane;

    // Fill: a frosted base (dark mode thickens toward charcoal, light mode
    // toward milk-white) with a top-lit white sheen on top.
    // A strong (filled) tint is coloured glass all the way through: no milky
    // base under it, and only a thin top highlight over it, so its colour
    // stays saturated -- especially in light mode -- and white labels read.
    final strongTint = tint != null && tintStrength >= 0.5;
    final Color base;
    final List<Color> sheen;
    if (strongTint) {
      base = Color.lerp(tint, Colors.black, 0.08)!.withValues(alpha: 0.55);
      sheen = [Colors.white.withValues(alpha: pane ? 0.18 : 0.22), Colors.white.withValues(alpha: pane ? 0.02 : 0)];
    } else if (dark && pane) {
      // Frosted pane: a neutral milky layer that sits visibly lighter than
      // whatever is behind it, brightest in the middle.
      base = Colors.white.withValues(alpha: 0.08 + frost * 0.2);
      sheen = [Colors.white.withValues(alpha: 0.16), Colors.white.withValues(alpha: 0.02)];
    } else if (dark) {
      base = const Color(0xFF15151C).withValues(alpha: frost * 0.75);
      sheen = [Colors.white.withValues(alpha: 0.11), Colors.white.withValues(alpha: 0.03)];
    } else if (pane) {
      // Light-mode pane: a faint cool grey rather than milk-white, so the
      // white rim and glints still have something darker to read against.
      base = const Color(0xFF5E6270).withValues(alpha: 0.16 + frost * 0.3);
      sheen = [Colors.white.withValues(alpha: 0.26), Colors.white.withValues(alpha: 0.05)];
    } else {
      // Light liquid glass: a thinner milky layer so the blurred colour
      // behind shows through, under a stronger top-lit sheen.
      base = Colors.white.withValues(alpha: 0.16 + frost * 0.55);
      sheen = [Colors.white.withValues(alpha: 0.58), Colors.white.withValues(alpha: 0.04)];
    }
    // Liquid glass is lit from the top; a pane glows diffusely from within.
    final Gradient sheenGradient = pane
        ? RadialGradient(center: const Alignment(0, -0.1), radius: 0.75, colors: sheen)
        : LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: sheen);

    Widget content = DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        color: base,
      ),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: shape,
          gradient: sheenGradient,
        ),
        child: tint == null
            ? _pad(child)
            : DecoratedBox(
                decoration: ShapeDecoration(
                  shape: shape,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    // Light washes fade off diagonally; strong (filled)
                    // tints stay nearly flat so white labels on them keep
                    // their contrast.
                    colors: [
                      tint!.withValues(alpha: tintStrength),
                      tint!.withValues(alpha: tintStrength * (tintStrength >= 0.5 ? 0.85 : 0.35)),
                    ],
                  ),
                ),
                child: _pad(child),
              ),
      ),
    );

    if (!pane) {
      content = CustomPaint(
        foregroundPainter: _LiquidEdgePainter(shape: shape, dark: dark, strength: rim, tint: tint),
        child: content,
      );
    }

    if (blur > 0) {
      // Blur, then boost saturation -- Apple's glass makes what's behind
      // it more vivid ("vibrancy") rather than greying it out.
      final filter = ui.ImageFilter.compose(
        outer: _vibrancy,
        inner: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
      );
      content = BackdropGroup.of(context) != null
          ? BackdropFilter.grouped(filter: filter, child: content)
          : BackdropFilter(filter: filter, child: content);
    }

    content = ClipPath(
      clipper: ShapeBorderClipper(shape: shape, textDirection: Directionality.maybeOf(context)),
      child: content,
    );

    // A pane's edge is painted outside the clip, so the bloom around its
    // glints can spill past the edge the way real glare does.
    if (pane) {
      content = CustomPaint(
        foregroundPainter: _PaneEdgePainter(shape: shape, dark: dark, strength: rim, tint: tint),
        child: content,
      );
    }

    final effectiveShadows = shadows ??
        [
          pane
              // Barely there: real glass panes cast almost no shadow.
              ? BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.18 : 0.05),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                )
              : BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.30 : 0.13),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
        ];
    if (effectiveShadows.isEmpty) return content;
    return CustomPaint(
      painter: _OuterShadowPainter(shape: shape, shadows: effectiveShadows),
      child: content,
    );
  }

  Widget? _pad(Widget? c) => padding == null ? c : Padding(padding: padding!, child: c);
}

/// The specular edge: a thin stroke along the shape whose brightness follows
/// a diagonal light source -- hottest at the top-left, nearly invisible on
/// the sides, with a faint secondary catch at the bottom-right.
/// Drop shadows painted only *outside* the shape. A normal BoxShadow fills
/// the whole shape too, which shows through translucent glass and makes it
/// look smoky; a real glass object's shadow falls around it, not inside it.
class _OuterShadowPainter extends CustomPainter {
  final ShapeBorder shape;
  final List<BoxShadow> shadows;

  _OuterShadowPainter({required this.shape, required this.shadows});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    var reach = 0.0;
    for (final s in shadows) {
      reach = [reach, s.blurRadius * 2 + s.spreadRadius + s.offset.distance].reduce((a, b) => a > b ? a : b);
    }
    // Draw the shadows into their own layer, then punch the shape's body
    // out of that layer so nothing darkens the glass from underneath.
    canvas.saveLayer(rect.inflate(reach + 2), Paint());
    for (final s in shadows) {
      final shadowRect = rect.shift(s.offset).inflate(s.spreadRadius);
      canvas.drawPath(shape.getOuterPath(shadowRect), s.toPaint());
    }
    canvas.drawPath(shape.getOuterPath(rect), Paint()..blendMode = BlendMode.clear);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OuterShadowPainter old) => old.shape != shape || !listEquals(old.shadows, shadows);
}

/// Saturation-boost colour matrix (1.35x) applied after the backdrop blur.
const ColorFilter _vibrancy = ColorFilter.matrix(<double>[
  1.2378, -0.2149, -0.0229, 0, 0,
  -0.0622, 1.0851, -0.0229, 0, 0,
  -0.0622, -0.2149, 1.2771, 0, 0,
  0, 0, 0, 1, 0,
]);

/// Shared base for the edge painters: everything an edge needs to know
/// about the surface it's drawn on. Subclasses supply the look.
abstract class _GlassEdgePainter extends CustomPainter {
  final ShapeBorder shape;
  final bool dark;
  final double strength;
  final Color? tint;

  _GlassEdgePainter({required this.shape, required this.dark, required this.strength, this.tint});

  @override
  bool shouldRepaint(_GlassEdgePainter old) =>
      old.runtimeType != runtimeType ||
      old.shape != shape ||
      old.dark != dark ||
      old.strength != strength ||
      old.tint != tint;
}

/// [GlassStyle.liquid]'s edge. Brightness follows the light around the
/// shape (a sweep, so curved corners catch it the way real glass does):
/// hottest at the top-left, a secondary catch at the bottom-right, nearly
/// invisible along the sides. A soft, wider inner band under the hairline
/// gives the edge visible thickness.
class _LiquidEdgePainter extends _GlassEdgePainter {
  _LiquidEdgePainter({required super.shape, required super.dark, required super.strength, super.tint});

  // Sweep angles run clockwise from 3 o'clock: 45° is bottom-right,
  // 225° top-left.
  static const _stops = [0.0, 0.125, 0.3, 0.5, 0.625, 0.75, 1.0];

  Shader _sweep(Rect rect, Color edge, double hi, double lo, double dim) =>
      SweepGradient(
        colors: [
          edge.withValues(alpha: dim), // right
          edge.withValues(alpha: lo), // bottom-right catch
          edge.withValues(alpha: dim * 0.5), // bottom-left
          edge.withValues(alpha: dim), // left
          edge.withValues(alpha: hi), // top-left: the light source
          edge.withValues(alpha: hi * 0.7), // top
          edge.withValues(alpha: dim), // back to right
        ],
        stops: _stops,
      ).createShader(rect);

  @override
  void paint(Canvas canvas, Size size) {
    if (strength <= 0) return;
    final rect = Offset.zero & size;
    final hi = (dark ? 0.70 : 1.0) * strength;
    final lo = (dark ? 0.30 : 0.70) * strength;
    final dim = (dark ? 0.07 : 0.30) * strength;
    // A tinted panel's rim picks up a little of its own colour, the way a
    // coloured glass edge does.
    final edge = tint == null ? Colors.white : Color.lerp(Colors.white, tint, 0.2)!;

    // Thickness: a blurred band just inside the edge.
    canvas.drawPath(
      shape.getOuterPath(rect.deflate(2)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
        ..shader = _sweep(rect, edge, hi * (dark ? 0.35 : 0.6), lo * (dark ? 0.35 : 0.6), 0),
    );

    // The crisp specular hairline.
    canvas.drawPath(
      shape.getOuterPath(rect.deflate(0.55)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..shader = _sweep(rect, edge, hi, lo, dim),
    );

    // A dark hairline just inside the rim keeps light-mode glass from
    // dissolving into a light backdrop.
    if (!dark) {
      canvas.drawPath(
        shape.getOuterPath(rect.deflate(1.4)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = Colors.black.withValues(alpha: 0.13 * strength),
      );
    }
  }
}

/// [GlassStyle.pane]'s edge, after real photographed glass:
///
/// * a crisp, even rim all the way round;
/// * sharp specular glints riding the edge, each tapering to nothing at
///   its ends with a soft bloom that spills a little past the edge. Circles
///   catch them on the diagonals (top-right bright, bottom-left fainter);
///   other shapes along the top and bottom, and down the sides when tall;
/// * inside: a slight darkening toward the rim, for depth, and small soft
///   highlights near two corners.
///
/// Painted outside [Glass]'s clip (so blooms can spill out); the interior
/// parts clip themselves to the shape.
class _PaneEdgePainter extends _GlassEdgePainter {
  _PaneEdgePainter({required super.shape, required super.dark, required super.strength, super.tint});

  /// Strokes [outline] inside [band], with [shader] fading it along the
  /// band: a crisp line plus a wider blurred copy for the bloom.
  void _glint(Canvas canvas, Path outline, Rect band, Shader Function() shader, double width) {
    canvas.save();
    canvas.clipRect(band);
    canvas.drawPath(
      outline,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width * 3
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, width * 1.6)
        ..shader = shader(),
    );
    canvas.drawPath(
      outline,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..shader = shader(),
    );
    canvas.restore();
  }

  Shader Function() _along(Rect band, {required bool horizontal, required double peak, required double center, double spread = 0.36}) {
    return () => LinearGradient(
          begin: horizontal ? Alignment.centerLeft : Alignment.topCenter,
          end: horizontal ? Alignment.centerRight : Alignment.bottomCenter,
          // A bright plateau through the middle of the glint, tapering
          // off to nothing at both ends.
          colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: peak),
            Colors.white.withValues(alpha: peak),
            Colors.white.withValues(alpha: 0),
          ],
          stops: [
            (center - spread).clamp(0.0, 1.0),
            (center - spread * 0.35).clamp(0.0, 1.0),
            (center + spread * 0.35).clamp(0.0, 1.0),
            (center + spread).clamp(0.0, 1.0),
          ],
        ).createShader(band);
  }

  /// A full-circle sweep that is dark everywhere except two tapered
  /// glints, at sweep positions [a] (peak [pa]) and [b] (peak [pb]).
  /// Sweep positions run clockwise from 3 o'clock (0.375 = bottom-left,
  /// 0.875 = top-right).
  Shader _diagonalGlints(Rect rect, double pa, double pb) {
    const a = 0.875, b = 0.375, wa = 0.085, wb = 0.07;
    Color c(double alpha) => Colors.white.withValues(alpha: alpha);
    return SweepGradient(
      colors: [c(0), c(0), c(pb), c(pb), c(0), c(0), c(pa), c(pa), c(0), c(0)],
      stops: [0, b - wb, b - wb * 0.3, b + wb * 0.3, b + wb, a - wa, a - wa * 0.3, a + wa * 0.3, a + wa, 1],
    ).createShader(rect);
  }

  void _strokeGlint(Canvas canvas, Path outline, Shader shader, double width) {
    canvas.drawPath(
      outline,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width * 3.5
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, width * 2)
        ..shader = shader,
    );
    canvas.drawPath(
      outline,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..shader = shader,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (strength <= 0) return;
    final rect = Offset.zero & size;
    final body = shape.getOuterPath(rect);
    final outline = shape.getOuterPath(rect.deflate(0.7));
    final k = strength;
    final w = size.width, h = size.height;

    // ── Interior (clipped to the shape) ──
    canvas.save();
    canvas.clipPath(body);

    // Depth: the glass darkens slightly toward its rim.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          radius: 0.72,
          colors: [
            Colors.transparent,
            Colors.transparent,
            Colors.black.withValues(alpha: (dark ? 0.16 : 0.06) * k),
          ],
          stops: const [0.0, 0.72, 1.0],
        ).createShader(rect),
    );

    // Soft corner highlights just inside the top-left and bottom-left.
    final spot = math.min(w, h) * 0.16;
    if (spot >= 6) {
      final spotPaint = Paint()
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, spot * 0.45)
        ..color = Colors.white.withValues(alpha: (dark ? 0.12 : 0.30) * k);
      canvas.drawOval(Rect.fromCenter(center: Offset(w * 0.12 + spot * 0.4, h * 0.14 + spot * 0.2), width: spot * 1.6, height: spot * 0.7), spotPaint);
      canvas.drawOval(Rect.fromCenter(center: Offset(w * 0.14 + spot * 0.4, h * 0.86 - spot * 0.2), width: spot * 1.6, height: spot * 0.6), spotPaint);
    }
    canvas.restore();

    // ── Edge ──
    // Crisp, even rim.
    canvas.drawPath(
      outline,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = Colors.white.withValues(alpha: (dark ? 0.48 : 0.85) * k),
    );

    // Dark hairline just inside, so light-mode glass doesn't dissolve into a
    // light background.
    if (!dark) {
      canvas.drawPath(
        shape.getOuterPath(rect.deflate(1.7)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6
          ..color = Colors.black.withValues(alpha: 0.07 * k),
      );
    }

    // Dark mode needs far less glare to read as glass; full strength there
    // looks like a hard shine rather than light catching an edge.
    final glintPeak = k.clamp(0.0, 1.0) * (dark ? 0.5 : 1.0);

    if (shape is CircleBorder) {
      _strokeGlint(canvas, outline, _diagonalGlints(rect, glintPeak, glintPeak * 0.75), dark ? 1.3 : 1.7);
      return;
    }

    final edgeBand = math.min(h * 0.22, 26.0);
    // Bands reach a few px past the edge so the bloom isn't cut off there.
    final top = Rect.fromLTRB(-8, -8, w + 8, edgeBand);
    _glint(canvas, outline, top, _along(top, horizontal: true, peak: glintPeak, center: 0.5, spread: 0.4), 1.6);

    final bottom = Rect.fromLTRB(-8, h - edgeBand, w + 8, h + 8);
    _glint(canvas, outline, bottom, _along(bottom, horizontal: true, peak: glintPeak * 0.7, center: 0.58, spread: 0.32), 1.3);

    if (h > w * 1.25) {
      final sideBand = math.min(w * 0.22, 26.0);
      final left = Rect.fromLTRB(-8, -8, sideBand, h + 8);
      final right = Rect.fromLTRB(w - sideBand, -8, w + 8, h + 8);
      _glint(canvas, outline, left, _along(left, horizontal: false, peak: glintPeak * 0.7, center: 0.4, spread: 0.3), 1.1);
      _glint(canvas, outline, right, _along(right, horizontal: false, peak: glintPeak * 0.55, center: 0.62, spread: 0.3), 1.1);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LENS OPTICS
// ─────────────────────────────────────────────────────────────────────────────

/// A faint glow along the bottom of a round glass button, where light
/// passing through the glass gathers -- coloured by [tint] when there is
/// one. (The rim, glints and corner highlights come from [Glass] itself.)
///
/// Purely painted (no extra backdrop read), so it's cheap enough for every
/// habit card. [glow] (0-1) brightens it a little, for a press.
class LiquidLensOptics extends StatelessWidget {
  final Color? tint;
  final double glow;

  const LiquidLensOptics({this.tint, this.glow = 0, super.key});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _LensPainter(dark: _isDark(context), tint: tint, glow: glow),
      size: Size.infinite,
    );
  }
}

class _LensPainter extends CustomPainter {
  final bool dark;
  final Color? tint;
  final double glow;

  _LensPainter({required this.dark, required this.tint, required this.glow});

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final c = size.center(Offset.zero);

    // Light pooling along the bottom edge.
    final poolRect = Rect.fromCenter(center: c + Offset(0, r * 0.78), width: r * 1.2, height: r * 0.42);
    final poolColor = tint == null ? Colors.white : Color.lerp(tint, Colors.white, 0.5)!;
    canvas.drawOval(
      poolRect,
      Paint()
        ..shader = RadialGradient(
          colors: [
            poolColor.withValues(alpha: (dark ? 0.10 : 0.26) + glow * 0.12),
            poolColor.withValues(alpha: 0),
          ],
        ).createShader(poolRect),
    );
  }

  @override
  bool shouldRepaint(_LensPainter old) => old.dark != dark || old.tint != tint || old.glow != glow;
}

// ─────────────────────────────────────────────────────────────────────────────
// BUTTONS
// ─────────────────────────────────────────────────────────────────────────────

/// A pressable glass surface. On press it squishes slightly and lights up
/// from within, like Liquid Glass controls do.
///
/// [prominent] fills the glass with [tint] (Apple's "glassProminent" style)
/// and expects white content; otherwise the glass stays clear and [tint]
/// only lightly washes it.
class GlassButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final ShapeBorder shape;
  final EdgeInsetsGeometry? padding;
  final Color? tint;
  final bool prominent;
  final double blur;
  final List<BoxShadow>? shadows;
  final double pressedScale;

  /// Overrides how strongly [tint] colours the glass (defaults: 0.82 when
  /// [prominent], 0.14 otherwise) -- e.g. a selected swatch sits between.
  final double? tintStrength;

  const GlassButton({
    required this.child,
    required this.onTap,
    this.shape = const StadiumBorder(),
    this.padding,
    this.tint,
    this.prominent = false,
    this.blur = 22,
    this.shadows,
    this.pressedScale = 0.95,
    this.tintStrength,
    super.key,
  });

  @override
  State<GlassButton> createState() => _GlassButtonState();
}

class _GlassButtonState extends State<GlassButton> {
  bool _pressed = false;

  void _set(bool v) {
    if (widget.onTap == null || _pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final tintStrength = widget.tintStrength ?? (widget.prominent ? 0.82 : 0.14);
    return Semantics(
      button: true,
      enabled: enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _set(true),
        onTapUp: (_) {
          _set(false);
          widget.onTap?.call();
        },
        onTapCancel: () => _set(false),
        child: AnimatedScale(
          scale: _pressed ? widget.pressedScale : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            opacity: enabled ? 1 : 0.45,
            duration: const Duration(milliseconds: 150),
            child: Glass(
              shape: widget.shape,
              tint: widget.tint,
              tintStrength: tintStrength,
              blur: widget.blur,
              rim: widget.prominent ? 0.8 : 1,
              shadows: widget.shadows ??
                  (widget.prominent && widget.tint != null
                      ? [BoxShadow(color: widget.tint!.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 6))]
                      : null),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Press glow -- light gathering in the glass under the finger.
                  Positioned.fill(
                    child: AnimatedOpacity(
                      opacity: _pressed ? 1 : 0,
                      duration: const Duration(milliseconds: 110),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            radius: 0.9,
                            colors: [Colors.white.withValues(alpha: 0.28), Colors.white.withValues(alpha: 0.04)],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(padding: widget.padding ?? EdgeInsets.zero, child: widget.child),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A circular glass icon button -- the iOS 26 toolbar/back-button look.
class GlassIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final double iconSize;
  final Color? color;
  final Color? tint;
  final bool prominent;
  final double blur;
  final List<BoxShadow>? shadows;

  const GlassIconButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.size = 44,
    this.iconSize = 20,
    this.color,
    this.tint,
    this.prominent = false,
    this.blur = 22,
    this.shadows,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final ink = color ?? (prominent ? Colors.white : Theme.of(context).colorScheme.onSurface);
    final button = SizedBox(
      width: size,
      height: size,
      child: GlassButton(
        onTap: onTap,
        shape: const CircleBorder(),
        tint: tint,
        prominent: prominent,
        blur: blur,
        shadows: shadows,
        pressedScale: 0.9,
        child: Center(child: Icon(icon, size: iconSize, color: ink)),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// A row of icon actions sharing one glass capsule, like the grouped
/// toolbar items in iOS 26 navigation bars.
class GlassToolbar extends StatelessWidget {
  final List<Widget> children;
  final double height;

  const GlassToolbar({required this.children, this.height = 44, super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Glass(
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// A bare icon for use inside a [GlassToolbar] -- no glass of its own, just
/// a press-squish, since the toolbar capsule is the glass.
class GlassToolbarItem extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  final double size;
  final double iconSize;
  final Color? color;

  const GlassToolbarItem({
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.size = 40,
    this.iconSize = 21,
    this.color,
    super.key,
  });

  @override
  State<GlassToolbarItem> createState() => _GlassToolbarItemState();
}

class _GlassToolbarItemState extends State<GlassToolbarItem> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        label: widget.tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) {
            setState(() => _pressed = false);
            widget.onTap();
          },
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedScale(
            scale: _pressed ? 0.82 : 1.0,
            duration: const Duration(milliseconds: 110),
            child: SizedBox(
              width: widget.size,
              height: widget.size,
              child: Icon(
                widget.icon,
                size: widget.iconSize,
                color: widget.color ?? Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
