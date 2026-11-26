import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../brain/models.dart';
import '../l10n/l10n.dart';
import 'usage.dart';

/// The usage limits of the providers Minerva runs on, at the start of the status bar: one dial
/// per provider, its logo in the middle and a ring per limit around it (outermost the five
/// hours, then the week, then a model's own week), each full and green with the whole limit left
/// and emptying as it is spent, through amber to red when little is left (see [leftColor]).
/// Hovering a dial enlarges it and opens a card with each limit's percent left, reset and
/// projection. Nothing when no provider could be read.
class UsageRings extends StatelessWidget {
  const UsageRings({super.key, required this.monitor});

  final UsageMonitor monitor;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: monitor,
        builder: (context, _) {
          final shown = monitor.shown;
          if (shown.isEmpty) return const SizedBox.shrink();
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, u) in shown.indexed) ...[
                if (i > 0) const SizedBox(width: 10),
                UsageDial(usage: u),
              ],
            ],
          );
        },
      );
}

/// A projection's color (the card's outlook line): green while the limit lasts until its reset,
/// orange when it ends close to it, red when it runs out before.
Color usageColor(UsageLevel level) => switch (level) {
      UsageLevel.good => const Color(0xFF4ADE80),
      UsageLevel.fair => const Color(0xFFFFA94D),
      UsageLevel.bad => const Color(0xFFFF5C5C),
    };

/// The ring's color for [left] percent of the limit left: green down to half, then amber at a
/// quarter, then red as it runs out.
Color leftColor(double left) {
  const green = Color(0xFF4ADE80), amber = Color(0xFFFFB020), red = Color(0xFFFF5C5C);
  if (left >= 50) return green;
  if (left >= 25) return Color.lerp(amber, green, (left - 25) / 25)!;
  return Color.lerp(red, amber, (left / 25).clamp(0, 1))!;
}

/// The rings from the outside in: the plan's own limits first (shortest window outermost), then
/// the ones of a model or model group.
List<UsageWindow> ringOrder(List<UsageWindow> windows) => [...windows]..sort((a, b) {
    final s = (a.scope == null ? 0 : 1).compareTo(b.scope == null ? 0 : 1);
    if (s != 0) return s;
    final k = a.kind.index.compareTo(b.kind.index);
    return k != 0 ? k : (a.minutes ?? 0).compareTo(b.minutes ?? 0);
  });

/// One provider's dial, and its card while hovered.
class UsageDial extends StatefulWidget {
  const UsageDial({super.key, required this.usage, this.size = 40});

  final ProviderUsage usage;
  final double size;

  @override
  State<UsageDial> createState() => _UsageDialState();
}

class _UsageDialState extends State<UsageDial> with SingleTickerProviderStateMixin {
  final _card = OverlayPortalController();
  final _link = LayerLink();
  late final _hover = AnimationController(vsync: this, duration: const Duration(milliseconds: 180))
    ..addStatusListener((s) {
      if (s == AnimationStatus.dismissed && _card.isShowing) _card.hide();
    });
  late final _curve = CurvedAnimation(parent: _hover, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);

  void _enter() {
    if (!_card.isShowing) _card.show();
    _hover.forward();
  }

  @override
  void dispose() {
    _hover.dispose();
    _curve.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final rings = ringOrder(widget.usage.windows);
    return MouseRegion(
      onEnter: (_) => _enter(),
      onExit: (_) => _hover.reverse(),
      child: OverlayPortal(
        controller: _card,
        overlayChildBuilder: (context) => CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.topLeft,
          followerAnchor: Alignment.bottomLeft,
          offset: const Offset(-6, -8),
          child: Align(
            alignment: Alignment.bottomLeft,
            child: IgnorePointer(
              child: FadeTransition(
                opacity: _curve,
                child: ScaleTransition(
                  scale: Tween(begin: 0.85, end: 1.0).animate(_curve),
                  alignment: Alignment.bottomLeft,
                  child: _UsageCard(usage: widget.usage, rings: rings, now: now),
                ),
              ),
            ),
          ),
        ),
        child: CompositedTransformTarget(
          link: _link,
          child: ScaleTransition(
            scale: Tween(begin: 1.0, end: 1.18).animate(_curve),
            child: Semantics(
              label: widget.usage.provider.label,
              child: SizedBox.square(
                dimension: widget.size,
                child: CustomPaint(
                  painter: _RingsPainter([for (final w in rings) (w.leftAt(now), leftColor(w.leftAt(now)))]),
                  child: Center(
                    child: SizedBox.square(
                      dimension: _logoSize(widget.size, rings.length),
                      child: ProviderLogo(widget.usage.provider),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Ring thickness and gap for [count] rings in a dial of [size].
(double, double) _ringMetrics(double size, int count) {
  final band = size / 2 * (count > 3 ? 0.62 : 0.5);
  final step = band / math.max(count, 1);
  return (math.min(3.2, step * 0.66), math.min(1.8, step * 0.34));
}

double _logoSize(double size, int count) {
  final (stroke, gap) = _ringMetrics(size, count);
  return math.max(10, size - 2 * count * (stroke + gap) - 2 * gap);
}

class _RingsPainter extends CustomPainter {
  _RingsPainter(this.left);

  /// Percent left and color of each ring, outermost first.
  final List<(double, Color)> left;

  @override
  void paint(Canvas canvas, Size size) {
    final (stroke, gap) = _ringMetrics(size.shortestSide, left.length);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    var rect = (Offset.zero & size).deflate(stroke / 2);
    for (final (l, color) in left) {
      canvas.drawArc(rect, 0, 2 * math.pi, false, paint..color = Colors.white.withValues(alpha: 0.09));
      final sweep = 2 * math.pi * (l / 100).clamp(0, 1);
      if (sweep > 0) canvas.drawArc(rect, -math.pi / 2, sweep, false, paint..color = color);
      rect = rect.deflate(stroke + gap);
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) =>
      old.left.length != left.length || [for (var i = 0; i < left.length; i++) old.left[i] != left[i]].any((d) => d);
}

/// The card a hovered dial opens: per ring (same order and color) which limit it is, the percent
/// left, when it starts over, and where it is heading (when it runs out, if before).
class _UsageCard extends StatelessWidget {
  const _UsageCard({required this.usage, required this.rings, required this.now});

  final ProviderUsage usage;
  final List<UsageWindow> rings;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = Theme.of(context).textTheme;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        constraints: const BoxConstraints(minWidth: 240, maxWidth: 360),
        padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
        decoration: BoxDecoration(
          color: const Color(0xF2141019),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 16, offset: Offset(0, 4))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(dimension: 16, child: ProviderLogo(usage.provider)),
                const SizedBox(width: 8),
                Text(usage.provider.label, style: t.labelLarge?.copyWith(color: Colors.white)),
              ],
            ),
            const SizedBox(height: 8),
            for (final w in rings) _row(context, l, t, w),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, AppLocalizations l, TextTheme t, UsageWindow w) {
    final left = w.leftAt(now);
    final p = w.projectAt(now);
    final color = leftColor(left);
    final limit = switch (w.kind) {
      UsageKind.session => l.usageSessionLimit,
      UsageKind.week => l.usageWeekLimit,
      UsageKind.other => l.usageOtherLimit(((w.minutes ?? 0) / 60).round()),
    };
    final resets = w.resetsAt;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(dimension: 14, child: CustomPaint(painter: _RingsPainter([(left, color)]))),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(w.scope == null ? limit : '${w.scope} · $limit',
                    style: t.bodySmall?.copyWith(color: Colors.white70)),
                if (resets != null && resets.isAfter(now))
                  Text(l.usageResets(_when(context, resets)),
                      style: t.bodySmall?.copyWith(color: Colors.white38, fontSize: 11)),
                if (_outlook(context, l, p) case final outlook?)
                  Text(outlook, style: t.bodySmall?.copyWith(color: usageColor(p.level).withValues(alpha: 0.85), fontSize: 11)),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Text(l.usageLeft(left.round()),
              style: t.bodySmall?.copyWith(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  /// "proyección: 130 % al reiniciarse · se agota hacia las 17:20", or "límite alcanzado".
  String? _outlook(BuildContext context, AppLocalizations l, UsageProjection p) {
    if (p.spent) return l.usageSpent;
    final projected = p.projected;
    if (projected == null) return null;
    final runsOut = p.runsOutAt;
    final today = runsOut != null && DateUtils.isSameDay(runsOut.toLocal(), now);
    return [
      l.usageProjection(projected.round()),
      if (runsOut != null) today ? l.usageRunsOutAt(_when(context, runsOut)) : l.usageRunsOutOn(_when(context, runsOut)),
    ].join(' · ');
  }

  /// "14:00" today, "jue 14:00" this week, else "3 dic".
  String _when(BuildContext context, DateTime t) {
    final tag = Localizations.localeOf(context).toLanguageTag();
    final locale = DateFormat.localeExists(tag) ? tag : 'en';
    final local = t.toLocal();
    final days = DateUtils.dateOnly(local).difference(DateUtils.dateOnly(now)).inDays;
    if (days == 0) return DateFormat.Hm(locale).format(local);
    if (days < 7) return DateFormat('E HH:mm', locale).format(local);
    return DateFormat.MMMd(locale).format(local);
  }
}

/// A provider's mark, drawn (not a bundled image): Claude's spark, OpenAI's knot for Codex and
/// Gemini's four-point star for Antigravity.
class ProviderLogo extends StatelessWidget {
  const ProviderLogo(this.provider, {super.key});

  final BrainProvider provider;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _LogoPainter(provider));
}

class _LogoPainter extends CustomPainter {
  _LogoPainter(this.provider);

  final BrainProvider provider;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    switch (provider) {
      case BrainProvider.claude:
        _spark(canvas, c, r);
      case BrainProvider.codex:
        _knot(canvas, c, r);
      case BrainProvider.antigravity:
        _star(canvas, c, r);
    }
  }

  /// Claude: rounded rays of uneven length around the center.
  static void _spark(Canvas canvas, Offset c, double r) {
    final paint = Paint()
      ..color = const Color(0xFFD97757)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = r * 0.2;
    const lengths = [1.0, 0.78, 0.92, 0.72, 0.96, 0.8, 0.9, 0.74, 1.0, 0.82, 0.88, 0.76];
    for (var i = 0; i < lengths.length; i++) {
      final a = -math.pi / 2 + i * 2 * math.pi / lengths.length;
      final d = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + d * r * 0.16, c + d * (r - paint.strokeWidth / 2) * lengths[i], paint);
    }
  }

  /// OpenAI: six rounded links turning around a hexagon.
  static void _knot(Canvas canvas, Offset c, double r) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.92)
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.11;
    final link = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(r * 0.12, -r * 0.42), width: r * 0.78, height: r * 0.62),
      Radius.circular(r * 0.31),
    );
    for (var i = 0; i < 6; i++) {
      canvas
        ..save()
        ..translate(c.dx, c.dy)
        ..rotate(i * math.pi / 3)
        ..drawRRect(link, paint)
        ..restore();
    }
  }

  /// Gemini: a four-point star with curved sides, blue to violet.
  static void _star(Canvas canvas, Offset c, double r) {
    final path = Path()
      ..moveTo(c.dx, c.dy - r)
      ..quadraticBezierTo(c.dx + r * 0.08, c.dy - r * 0.08, c.dx + r, c.dy)
      ..quadraticBezierTo(c.dx + r * 0.08, c.dy + r * 0.08, c.dx, c.dy + r)
      ..quadraticBezierTo(c.dx - r * 0.08, c.dy + r * 0.08, c.dx - r, c.dy)
      ..quadraticBezierTo(c.dx - r * 0.08, c.dy - r * 0.08, c.dx, c.dy - r)
      ..close();
    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
        colors: [Color(0xFF4796E3), Color(0xFF9177C7), Color(0xFFCA6673)],
      ).createShader(Rect.fromCircle(center: c, radius: r));
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_LogoPainter old) => old.provider != provider;
}
