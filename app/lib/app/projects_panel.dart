import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../workers/workers.dart';
import 'main_view.dart';
import 'workers_panel.dart';

/// The projects, cards floating in a column at the left of the orb, the most recently active
/// first ([Workers.projectsBoard]): each one's name and how it is going, from its latest worker
/// (status, when, its title and latest note), else its README's first line and when its folder
/// last changed. As many as fit, never scrolled; nothing while there are none.
class ProjectsPanel extends StatefulWidget {
  const ProjectsPanel({super.key, required this.workers});

  final Workers workers;

  @override
  State<ProjectsPanel> createState() => _ProjectsPanelState();
}

class _ProjectsPanelState extends State<ProjectsPanel> {
  static const _gap = 10.0;

  /// About a card's height, to tell how many fit.
  static const _cardExtent = 120.0;

  /// How often (in ticks) the folders are looked at again; workers' changes come at once.
  static const _reload = 30;

  late List<ProjectInfo> _shown;

  /// Ticks a running worker's time, and every [_reload] ticks reloads the projects.
  Timer? _tick;
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    _shown = widget.workers.projectsBoard();
    widget.workers.addListener(_changed);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (++_ticks % _reload == 0) {
        _changed();
      } else if (_shown.any((p) => p.worker?.running ?? false)) {
        setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(ProjectsPanel old) {
    super.didUpdateWidget(old);
    if (old.workers != widget.workers) {
      old.workers.removeListener(_changed);
      widget.workers.addListener(_changed);
      _shown = widget.workers.projectsBoard();
    }
  }

  @override
  void dispose() {
    widget.workers.removeListener(_changed);
    _tick?.cancel();
    super.dispose();
  }

  void _changed() => setState(() => _shown = widget.workers.projectsBoard());

  @override
  Widget build(BuildContext context) {
    if (_shown.isEmpty) return const SizedBox.shrink();
    final now = DateTime.now();
    return SizedBox(
      width: sidePanelWidth(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 12, 12),
        child: LayoutBuilder(
          builder: (context, box) {
            final fit = math.max(1, ((box.maxHeight - 12) / (_cardExtent + _gap)).floor());
            return ClipRect(
              child: SingleChildScrollView(
                // Never scrolled: only so a card taller than counted is cut off, not overflowing.
                physics: const NeverScrollableScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final p in _shown.take(fit)) ...[
                      _ProjectCard(project: p, now: now),
                      const SizedBox(height: _gap),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.project, required this.now});

  final ProjectInfo project;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final p = project;
    final w = p.worker;
    final l = AppLocalizations.of(context);
    final t = Theme.of(context).textTheme;
    final small = t.bodySmall;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: sideCardDecoration(active: w?.running ?? false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.folder_outlined, size: 14, color: kAccent.withValues(alpha: 0.8)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.labelLarge?.copyWith(color: Colors.white, height: 1.25)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (w != null) ...[
            Builder(builder: (context) {
              final (status, color) = workerStatusLook(l, w.status);
              final when = w.running ? workerDuration(w.elapsed(now)) : ago(l, w.finished ?? w.started, now);
              return Row(
                children: [
                  WorkerStatusIcon(status: w.status, color: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('$status · $when',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: small?.copyWith(color: color)),
                  ),
                ],
              );
            }),
            const SizedBox(height: 4),
            Text(w.title,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: small?.copyWith(color: Colors.white70)),
            if (w.latest case final latest?) ...[
              const SizedBox(height: 2),
              Text(latest,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: small?.copyWith(color: Colors.white54, height: 1.35)),
            ],
          ] else ...[
            if (p.summary.isNotEmpty)
              Text(p.summary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: small?.copyWith(color: Colors.white70, height: 1.35)),
            const SizedBox(height: 4),
            Text(l.projectEdited(ago(l, p.modified, now)), style: small?.copyWith(color: Colors.white38)),
          ],
        ],
      ),
    );
  }

  /// "ahora mismo", "hace 5 min", "hace 2 h", "ayer", "hace 3 días".
  static String ago(AppLocalizations l, DateTime at, DateTime now) {
    final d = now.difference(at);
    if (d.inMinutes < 1) return l.timeJustNow;
    if (d.inHours < 1) return l.timeMinutesAgo(d.inMinutes);
    if (d.inDays < 1) return l.timeHoursAgo(d.inHours);
    return l.timeDaysAgo(d.inDays);
  }
}
