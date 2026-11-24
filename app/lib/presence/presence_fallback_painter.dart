import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'presence_view.dart';

/// Canvas-only version of the presence (used when the fragment shader cannot
/// be loaded). Same layout and inputs as the shader, far fewer details: the
/// glowing nucleus, the shell's outline, the three gyroscope orbits with their
/// comets and the ring of spectrum bars.
class PresenceFallbackPainter extends CustomPainter {
  PresenceFallbackPainter({
    required this.frame,
    required this.accent,
    required this.compact,
  }) : super(repaint: frame);

  final PresenceFrame frame;
  final Color accent;
  final bool compact;

  static const int _bars = 48;
  static const Color _white = Color(0xFFFFFFFF);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    if (!compact) {
      canvas.drawRect(Offset.zero & size, Paint()..color = kPresenceBackground);
    }
    final accent = frame.tint(this.accent);
    final accent2 = frame.tint2;
    final rect = PresenceView.orbRect(size, compact: compact);
    final c = rect.center;
    // Shell radius, as in the shader.
    final unit = rect.width * (compact ? 0.26 : 0.19);
    final s = frame.state;
    final listen = s[1], think = s[2], speak = s[3];
    final react = listen + speak;
    final hear = frame.level * listen, say = frame.level * speak;
    final breath = math.sin(frame.time * 0.9);
    final pulse = 0.5 + 0.5 * math.sin(frame.spin * 0.5);
    final minStroke = compact ? 1.0 : 0.0;

    // Nucleus.
    final coreR = unit * (0.5 + 0.04 * breath + 0.35 * say + 0.1 * think * pulse);
    final coreI = (0.7 + 0.3 * say + 0.2 * think * pulse).clamp(0.0, 1.0);
    canvas.drawCircle(
      c,
      coreR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Color.lerp(accent, _white, 0.8)!.withValues(alpha: coreI),
            accent.withValues(alpha: 0.3 * coreI),
            accent.withValues(alpha: 0),
          ],
          stops: const [0, 0.3, 1],
        ).createShader(Rect.fromCircle(center: c, radius: coreR)),
    );

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..isAntiAlias = true;

    // Shell.
    final shellR = unit * (1 + 0.01 * breath + 0.05 * say + 0.015 * hear);
    stroke
      ..strokeWidth = math.max(1.2, minStroke)
      ..color = Color.lerp(
        accent,
        accent2,
        0.3,
      )!.withValues(alpha: (0.45 + 0.4 * react * frame.level).clamp(0.0, 1.0));
    canvas.drawCircle(c, shellR, stroke);

    // Thinking: an expanding pulse inside the shell.
    if (think > 0.001) {
      final f = (frame.spin * 0.08) % 1.0;
      stroke
        ..strokeWidth = 1.5
        ..color = accent2.withValues(alpha: think * (1 - f) * 0.7);
      canvas.drawCircle(c, shellR * (0.2 + 0.8 * f), stroke);
    }

    // Gyroscope: each orbit is a circle in a tilted plane, so an ellipse here.
    final fill = Paint()..isAntiAlias = true;
    for (var i = 0; i < PresenceFrame.ringCount; i++) {
      final ux = frame.ringBasis[i * 6], uy = frame.ringBasis[i * 6 + 1];
      final vx = frame.ringBasis[i * 6 + 3], vy = frame.ringBasis[i * 6 + 4];
      final radius =
          unit * ((compact ? 1.21 : 1.25) + (compact ? 0.105 : 0.12) * i);
      final ringColor = Color.lerp(accent, accent2, i == 1 ? 0.85 : 0.12)!;
      // Plane normal = u x v; the ellipse's short axis points along its
      // screen projection, squeezed by the normal's z.
      final nx =
          uy * frame.ringBasis[i * 6 + 5] - frame.ringBasis[i * 6 + 2] * vy;
      final ny =
          frame.ringBasis[i * 6 + 2] * vx - ux * frame.ringBasis[i * 6 + 5];
      final nz = ux * vy - uy * vx;
      canvas
        ..save()
        ..translate(c.dx, c.dy)
        ..rotate(math.atan2(-ny, nx));
      stroke
        ..strokeWidth = math.max(1.0, minStroke)
        ..color = ringColor.withValues(alpha: 0.4 + 0.25 * think);
      canvas
        ..drawOval(
          Rect.fromCenter(
            center: Offset.zero,
            width: 2 * radius * nz.abs(),
            height: 2 * radius,
          ),
          stroke,
        )
        ..restore();
      // The comet's head sits at -u (screen y points down, the plane's up).
      fill.color = Color.lerp(ringColor, _white, 0.7)!;
      canvas.drawCircle(
        c + Offset(-ux, uy) * radius,
        math.max(unit * 0.03, 1.5),
        fill,
      );
    }

    // Spectrum bars, mirrored four ways like the shader's.
    final r0 = unit * (compact ? 1.50 : 1.70);
    final b = frame.bands;
    stroke
      ..strokeWidth = math.max(unit * 0.02, 1.0)
      ..color = Color.lerp(
        accent,
        accent2,
        0.15 + 0.85 * listen,
      )!.withValues(alpha: (0.35 + 0.5 * react).clamp(0.0, 1.0));
    for (var i = 0; i < _bars; i++) {
      final turn = (i + 0.5) / _bars;
      final t = ((turn * 2) % 1.0 * 2 - 1).abs() * 7;
      final i0 = t.floor().clamp(0, 7);
      final i1 = math.min(i0 + 1, 7);
      final band = b[i0] + (b[i1] - b[i0]) * (t - i0);
      final len =
          unit *
          (0.02 + (compact ? 0.25 : 0.32) * band * (listen + 0.4 * speak));
      final a = turn * 2 * math.pi;
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + dir * r0, c + dir * (r0 + len), stroke);
    }

    // Speaking: a ring that swells with the voice.
    if (speak > 0.001) {
      stroke
        ..strokeWidth = 1.5
        ..color = Color.lerp(
          accent,
          _white,
          0.6,
        )!.withValues(alpha: speak * (0.3 + 0.6 * frame.level));
      canvas.drawCircle(c, shellR + unit * (0.08 + 0.25 * say), stroke);
    }
  }

  @override
  bool shouldRepaint(PresenceFallbackPainter old) =>
      old.frame != frame || old.accent != accent || old.compact != compact;
}
