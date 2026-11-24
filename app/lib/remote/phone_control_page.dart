import 'package:flutter/material.dart';

import '../app/main_view.dart';
import '../l10n/l10n.dart';
import 'remote_assistant.dart';

/// Lets Minerva use this phone: guides the user through the accessibility service, the overlay
/// permission and screenshots, with their status (read again when the user comes back from the
/// phone's settings).
class PhoneControlPage extends StatefulWidget {
  const PhoneControlPage({super.key, required this.assistant});

  final RemoteAssistant assistant;

  @override
  State<PhoneControlPage> createState() => _PhoneControlPageState();
}

class _PhoneControlPageState extends State<PhoneControlPage> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.assistant.refreshControl();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.assistant.refreshControl();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = widget.assistant.phoneControl;
    return Scaffold(
      appBar: AppBar(title: Text(l.phoneControl), backgroundColor: kBackground),
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final t = Theme.of(context).textTheme;
          final note = t.bodySmall?.copyWith(color: Colors.white54);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Text(l.phoneControlIntro, style: t.bodyMedium),
              const SizedBox(height: 16),
              _Step(
                number: 1,
                title: l.phoneControlAccessibility,
                on: c.running,
                help: [
                  c.accessibility && !c.running ? l.phoneControlAccessibilityStopped : l.phoneControlAccessibilityHelp,
                  if (!c.running && c.sdk >= 33) l.phoneControlRestricted,
                ],
                actions: [
                  FilledButton.tonal(onPressed: c.openAccessibilitySettings, child: Text(l.openSettings)),
                  if (!c.running && c.sdk >= 33)
                    TextButton(onPressed: c.openAppInfo, child: Text(l.openAppInfo)),
                ],
              ),
              _Step(
                number: 2,
                title: l.phoneControlOverlay,
                on: c.overlay || c.running,
                help: [l.phoneControlOverlayHelp],
                actions: [
                  if (!c.overlay) FilledButton.tonal(onPressed: c.openOverlaySettings, child: Text(l.openSettings)),
                ],
              ),
              _Step(
                number: 3,
                title: l.phoneControlScreenshots,
                on: c.running && (c.screenshots != 'ask'),
                help: [
                  switch (c.screenshots) {
                    'accessibility' => l.phoneControlScreenshotsAuto,
                    'projection' => l.phoneControlScreenshotsReady,
                    _ => l.phoneControlScreenshotsAsk,
                  },
                ],
                actions: const [],
              ),
              const SizedBox(height: 8),
              Text('Android API ${c.sdk}', style: note),
            ],
          );
        },
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.title,
    required this.on,
    required this.help,
    required this.actions,
  });

  final int number;
  final String title;
  final bool on;
  final List<String> help;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = Theme.of(context).textTheme;
    return Card(
      color: const Color(0xFF120E18),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('$number. $title', style: t.titleMedium)),
                Icon(on ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 18, color: on ? kAccent : Colors.white38),
                const SizedBox(width: 6),
                Text(on ? l.statusOn : l.statusOff,
                    style: t.bodySmall?.copyWith(color: on ? kAccent : Colors.white54)),
              ],
            ),
            for (final h in help) ...[
              const SizedBox(height: 8),
              Text(h, style: t.bodySmall?.copyWith(color: Colors.white70)),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}
