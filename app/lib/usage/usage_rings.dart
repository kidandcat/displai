import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/main_view.dart' show kAccent;
import '../l10n/l10n.dart';
import 'usage.dart';

/// The usage limits of the providers Minerva runs on, at the start of the status bar: per
/// provider its name and a small ring per limit (five hours, week, a model's week) with the
/// percent spent. The details (and when it starts over) show on hover. Nothing when no provider
/// could be read.
class UsageRings extends StatelessWidget {
  const UsageRings({super.key, required this.monitor});

  final UsageMonitor monitor;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: monitor,
        builder: (context, _) {
          final shown = monitor.shown;
          if (shown.isEmpty) return const SizedBox.shrink();
          final now = DateTime.now();
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, u) in shown.indexed) ...[
                if (i > 0) const SizedBox(width: 14),
                Text(u.provider.label,
                    style: const TextStyle(fontSize: 10, color: Colors.white38, letterSpacing: 0.3)),
                for (final w in u.windows) ...[
                  const SizedBox(width: 6),
                  _Ring(provider: u.provider.label, window: w, now: now),
                ],
              ],
            ],
          );
        },
      );
}

/// The ring's color: the accent, amber from three quarters spent, red when nearly out.
Color usageColor(double used) => used >= 90
    ? Colors.redAccent
    : used >= 75
        ? Colors.amberAccent
        : kAccent;

/// The ring's short label: `5h`, `7d`, or the model it is for (`Fable 7d`).
String usageLabel(UsageWindow w) {
  final length = switch (w.kind) {
    UsageKind.session => '5h',
    UsageKind.week => '7d',
    UsageKind.other => w.minutes == null
        ? '?'
        : w.minutes! % 1440 == 0
            ? '${w.minutes! ~/ 1440}d'
            : '${(w.minutes! / 60).round()}h',
  };
  return w.scope == null ? length : '${w.scope} $length';
}

class _Ring extends StatelessWidget {
  const _Ring({required this.provider, required this.window, required this.now});

  final String provider;
  final UsageWindow window;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final used = window.usedAt(now);
    final color = usageColor(used);
    final limit = switch (window.kind) {
      UsageKind.session => l.usageSessionLimit,
      UsageKind.week => l.usageWeekLimit,
      UsageKind.other => l.usageOtherLimit(((window.minutes ?? 0) / 60).round()),
    };
    final resets = window.resetsAt;
    final tip = [
      '$provider${window.scope == null ? '' : ' · ${window.scope}'} · $limit',
      l.usageUsed(used.round()),
      if (resets != null && resets.isAfter(now)) l.usageResets(_when(context, resets)),
    ].join('\n');
    return Tooltip(
      message: tip,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 28,
            child: CustomPaint(
              painter: _RingPainter(used / 100, color),
              child: Center(
                child: Text('${used.round()}',
                    style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w600, color: color.withValues(alpha: 0.9))),
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(usageLabel(window), style: const TextStyle(fontSize: 8.5, color: Colors.white38)),
        ],
      ),
    );
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

class _RingPainter extends CustomPainter {
  _RingPainter(this.fraction, this.color);

  final double fraction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.6;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, 2 * math.pi, false, paint..color = Colors.white12);
    final sweep = 2 * math.pi * fraction.clamp(0, 1);
    if (sweep > 0) canvas.drawArc(rect, -math.pi / 2, sweep, false, paint..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction || old.color != color;
}
