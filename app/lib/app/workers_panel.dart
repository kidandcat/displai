import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../presence/presence.dart';
import '../workers/workers.dart';
import 'main_view.dart';

/// The background workers, in a column at the side of the full view: the running ones, then the
/// ones that finished lately ([Workers.board]). Each card has the worker's title, status, how
/// long it has run, its latest progress note (a couple of lines, faded in as a new one comes),
/// its model and its project. As many as fit, never scrolled; nothing while there are none.
class WorkersPanel extends StatefulWidget {
  const WorkersPanel({super.key, required this.workers});

  final Workers workers;

  @override
  State<WorkersPanel> createState() => _WorkersPanelState();
}

class _WorkersPanelState extends State<WorkersPanel> {
  static const _gap = 10.0;

  /// About a card's height, to tell how many fit.
  static const _cardExtent = 165.0;

  /// Ticks the running times, and lets finished workers go once they are no longer recent.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    widget.workers.addListener(_changed);
  }

  @override
  void didUpdateWidget(WorkersPanel old) {
    super.didUpdateWidget(old);
    if (old.workers != widget.workers) {
      old.workers.removeListener(_changed);
      widget.workers.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.workers.removeListener(_changed);
    _tick?.cancel();
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final shown = widget.workers.board();
    if (shown.isEmpty) {
      _tick?.cancel();
      _tick = null;
      return const SizedBox.shrink();
    }
    _tick ??= Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    final l = AppLocalizations.of(context);
    final t = Theme.of(context).textTheme;
    final width = (MediaQuery.sizeOf(context).width * 0.3).clamp(220.0, 340.0);
    final now = DateTime.now();
    return Container(
      width: width,
      padding: const EdgeInsets.fromLTRB(12, 14, 14, 12),
      decoration: const BoxDecoration(
        color: Color(0xFF0B0810),
        border: Border(left: BorderSide(color: Color(0x1FA87CFF))),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final fit = math.max(1, ((box.maxHeight - 32) / (_cardExtent + _gap)).floor());
          final cards = shown.length > fit ? shown.take(fit - (fit > 1 ? 1 : 0)).toList() : shown;
          final more = shown.length - cards.length;
          return ClipRect(
            child: SingleChildScrollView(
              // Never scrolled: only so a card taller than counted is cut off, not overflowing.
              physics: const NeverScrollableScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(l.workersTitle.toUpperCase(),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, letterSpacing: 1.6, color: kAccent.withValues(alpha: 0.6))),
                      ),
                      Text('${widget.workers.runningCount}',
                          style: t.labelSmall?.copyWith(color: kPresenceWorkerAccent)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  for (final w in cards) ...[
                    _WorkerCard(worker: w, now: now),
                    const SizedBox(height: _gap),
                  ],
                  if (more > 0)
                    Center(child: Text(l.workersMore(more), style: t.bodySmall?.copyWith(color: Colors.white38))),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _WorkerCard extends StatelessWidget {
  const _WorkerCard({required this.worker, required this.now});

  final WorkerInfo worker;
  final DateTime now;

  static const _done = Color(0xFF4ADE80);
  static const _failed = Color(0xFFFF5C5C);

  @override
  Widget build(BuildContext context) {
    final w = worker;
    final l = AppLocalizations.of(context);
    final t = Theme.of(context).textTheme;
    final (status, color) = switch (w.status) {
      'running' => (l.workerRunning, kPresenceWorkerAccent),
      'done' => (l.workerDone, _done),
      'failed' => (l.workerFailed, _failed),
      'interrupted' => (l.workerInterrupted, Colors.white54),
      _ => (l.workerStopped, Colors.white54),
    };
    final latest = w.latest ?? (w.running ? l.workerStarting : null);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF141019),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: w.running ? kPresenceWorkerAccent.withValues(alpha: 0.35) : Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 2), child: _StatusIcon(status: w.status, color: color)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(w.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: t.labelLarge?.copyWith(color: Colors.white, height: 1.25)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('$status · ${_duration(w.elapsed(now))}', style: t.bodySmall?.copyWith(color: color)),
          if (latest != null) ...[
            const SizedBox(height: 6),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              layoutBuilder: (current, previous) =>
                  Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
              child: Text(latest,
                  key: ValueKey(latest),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodySmall?.copyWith(color: Colors.white70, height: 1.35)),
            ),
          ],
          if (w.model != null || w.project != null) ...[
            const SizedBox(height: 8),
            if (w.model != null) _Detail(icon: Icons.memory, text: w.model!),
            if (w.project != null) _Detail(icon: Icons.folder_outlined, text: w.project!),
          ],
        ],
      ),
    );
  }

  /// "45 s", "4 min 12 s", "1 h 05 min".
  static String _duration(Duration d) {
    if (d.isNegative) d = Duration.zero;
    if (d.inHours > 0) return '${d.inHours} h ${(d.inMinutes % 60).toString().padLeft(2, '0')} min';
    if (d.inMinutes > 0) return '${d.inMinutes} min ${d.inSeconds % 60} s';
    return '${d.inSeconds} s';
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status, required this.color});

  final String status;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: 14,
        child: switch (status) {
          'running' => CircularProgressIndicator(strokeWidth: 2, color: color),
          'done' => Icon(Icons.check_circle, size: 14, color: color),
          'failed' => Icon(Icons.error_outline, size: 14, color: color),
          _ => Icon(Icons.stop_circle_outlined, size: 14, color: color),
        },
      );
}

/// A line of a card's details (model, project), with its icon.
class _Detail extends StatelessWidget {
  const _Detail({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          children: [
            Icon(icon, size: 12, color: Colors.white38),
            const SizedBox(width: 6),
            Expanded(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white38)),
            ),
          ],
        ),
      );
}
