import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'presence_view.dart';

/// Canvas-only version of the presence (used when the fragment shader cannot
/// be loaded). Simpler look: glowing core, a few rotating dashed rings and a
/// spectrum contour, same inputs as the shader.
class PresenceFallbackPainter extends CustomPainter {
  PresenceFallbackPainter({
    required this.frame,
    required this.accent,
    required this.compact,
  }) : super(repaint: frame);

  final PresenceFrame frame;
  final Color accent;
  final bool compact;

  static const int _contourPoints = 96;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final accent = frame.tint(this.accent);
    if (!compact) {
      canvas.drawRect(rect, Paint()..color = kPresenceBackground);
    }
    final c = size.center(Offset.zero);
    final unit = size.shortestSide / (compact ? 0.62 : 1.0);
    final s = frame.state;
    final react = s[1] + s[3];
    final lvl = frame.level * react;
    final breath = 0.5 + 0.5 * math.sin(frame.time * 0.85);
    final think = s[2];
    final thinkPulse = (0.5 + 0.5 * math.sin(frame.time * 4.2)) * think;

    // Core glow.
    final coreI = (0.55 + 0.18 * breath * s[0] + 1.1 * lvl + 0.35 * thinkPulse)
        .clamp(0.0, 1.6);
    final coreR = unit * 0.09 * (1 + 0.6 * lvl);
    canvas.drawCircle(
      c,
      coreR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Color.lerp(
              accent,
              const Color(0xFFFFFFFF),
              0.7,
            )!.withValues(alpha: (coreI / 1.6).clamp(0.0, 1.0)),
            accent.withValues(alpha: 0.25 * coreI / 1.6),
            accent.withValues(alpha: 0),
          ],
          stops: const [0, 0.25, 1],
        ).createShader(Rect.fromCircle(center: c, radius: coreR)),
    );

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..isAntiAlias = true;
    final minStroke = compact ? 1.0 : 0.0;

    void dashedRing(
      double radius,
      int segments,
      double duty,
      double rotation,
      double width,
      double alpha,
    ) {
      stroke
        ..strokeWidth = math.max(width, minStroke)
        ..color = accent.withValues(alpha: alpha.clamp(0.0, 1.0));
      final r = Rect.fromCircle(center: c, radius: radius);
      final step = 2 * math.pi / segments;
      for (var i = 0; i < segments; i++) {
        canvas.drawArc(r, rotation + i * step, step * duty, false, stroke);
      }
    }

    final swell = lvl * 0.012 + breath * 0.004 * s[0];
    final spin = frame.spin * 2 * math.pi;
    dashedRing(unit * (0.045 + swell * 0.15), 2, 0.32, spin * 0.16, 1.2, 0.8);
    dashedRing(unit * (0.075 + swell * 0.35), 1, 1, 0, 1.0, 0.7);
    dashedRing(
      unit * (0.145 + swell * 0.7),
      3,
      0.27,
      -spin * 0.035,
      unit * 0.012,
      0.35,
    );
    if (!compact) {
      dashedRing(
        unit * (0.19 + swell * 0.85),
        48,
        0.5,
        spin * 0.012,
        1.2,
        0.45,
      );
      dashedRing(unit * (0.30 + swell * 0.6), 60, 0.3, -spin * 0.006, 1.5, 0.2);
    }
    dashedRing(
      unit * (0.24 + swell),
      2,
      0.07 + 0.05 * think,
      spin * 0.06,
      2.2,
      0.85,
    );

    // Spectrum contour (mirrored: lows on top, highs at the bottom).
    final path = Path();
    final b = frame.bands;
    for (var i = 0; i <= _contourPoints; i++) {
      final a = i / _contourPoints * 2 * math.pi; // 0 at top, clockwise
      final t = (a <= math.pi ? a : 2 * math.pi - a) / math.pi;
      final x = t * 7;
      final i0 = x.floor().clamp(0, 7);
      final i1 = math.min(i0 + 1, 7);
      final spec = (b[i0] + (b[i1] - b[i0]) * (x - i0)) * react;
      final rr = unit * (0.24 + swell + spec * 0.05);
      final p = c + Offset(math.sin(a) * rr, -math.cos(a) * rr);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    stroke
      ..strokeWidth = math.max(1.0, minStroke)
      ..color = accent.withValues(alpha: 0.25 + 0.5 * react);
    canvas.drawPath(path, stroke);

    // Thinking: expanding pulse ring.
    if (think > 0.001) {
      final f = (frame.time * 0.45) % 1.0;
      stroke
        ..strokeWidth = 1.5
        ..color = accent.withValues(alpha: (think * (1 - f) * (1 - f) * 0.6));
      canvas.drawCircle(c, unit * (0.04 + f * 0.28), stroke);
    }
  }

  @override
  bool shouldRepaint(PresenceFallbackPainter old) =>
      old.frame != frame || old.accent != accent || old.compact != compact;
}
