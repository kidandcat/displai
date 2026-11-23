import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../display/display.dart';
import '../presence/presence.dart';
import 'assistant_ui.dart';

const kBackground = Color(0xFF05070A);
const kAccent = Color(0xFF4FD8FF);

ThemeData displaiTheme() => ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(seedColor: kAccent, brightness: Brightness.dark),
      scaffoldBackgroundColor: kBackground,
    );

/// The main screen, the same on the desktop and on the phone: the presence orb, the display
/// on top of it, and a status bar.
class MainView extends StatelessWidget {
  const MainView({
    super.key,
    required this.assistant,
    this.actions = const [],
    this.compactOrb = 180,
  });

  final AssistantUi assistant;

  /// Extra buttons at the end of the status bar.
  final List<Widget> actions;

  /// Size of the corner orb while something is on screen.
  final double compactOrb;

  void _tapOrb() {
    if (!assistant.ready) return;
    HapticFeedback.selectionClick();
    assistant.toggleMute();
  }

  @override
  Widget build(BuildContext context) {
    final a = assistant;
    if (a.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('No se pudo arrancar: ${a.error}', style: const TextStyle(color: Colors.white70)),
        ),
      );
    }
    final showing = !a.display.isEmpty;
    return Column(
      children: [
        Expanded(
          // The display is transparent while empty, so the presence animation shows through
          // (with the timeline strip still on top).
          child: RepaintBoundary(
            key: a.screenKey,
            child: ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedOpacity(
                    opacity: showing ? 0 : 1,
                    duration: const Duration(milliseconds: 350),
                    child: showing ? const SizedBox.expand() : PresenceView(signal: a.presence),
                  ),
                  DisplayView(controller: a.display),
                  // The full orb: the sphere and its inner rings, ~0.3 of the short side around the center.
                  // Tapping it (or the corner orb) mutes or unmutes the mic.
                  if (!showing)
                    LayoutBuilder(
                      builder: (context, box) => Center(
                        child: ClipOval(
                          child: _OrbTap(
                            onTap: _tapOrb,
                            child: SizedBox.square(dimension: 0.6 * box.biggest.shortestSide),
                          ),
                        ),
                      ),
                    ),
                  // While something is on screen the presence shrinks to a large orb in the corner.
                  if (showing)
                    Positioned(
                      top: 12,
                      right: 12,
                      child: _OrbTap(
                        onTap: _tapOrb,
                        child: PresenceView(signal: a.presence, compact: true, compactSize: compactOrb),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        StatusBar(assistant: a, actions: actions),
      ],
    );
  }
}

class StatusBar extends StatelessWidget {
  const StatusBar({super.key, required this.assistant, this.actions = const []});

  final AssistantUi assistant;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final a = assistant;
    final t = Theme.of(context).textTheme;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final line = !a.ready
        ? (a.linkNote.isNotEmpty ? a.linkNote : 'Cargando la voz…')
        : a.activity.isNotEmpty
            ? a.activity
            : a.lastHeard;
    return Container(
      height: 52,
      padding: EdgeInsets.symmetric(horizontal: narrow ? 4 : 16),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0x1AFFFFFF)))),
      child: Row(
        children: [
          IconButton(
            tooltip: a.muted ? 'Activar micrófono (espacio)' : 'Silenciar micrófono (espacio)',
            onPressed: a.ready ? a.toggleMute : null,
            icon: Icon(a.muted ? Icons.mic_off : Icons.mic, color: a.muted ? Colors.redAccent : kAccent),
          ),
          SizedBox(width: narrow ? 4 : 12),
          Expanded(
            child: Text(
              line,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.bodyMedium?.copyWith(
                color: a.activity.isNotEmpty ? kAccent : Colors.white60,
                fontStyle: a.activity.isNotEmpty ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          ),
          if (a.ready && a.backgroundJobs > 0) ...[
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
            ),
            const SizedBox(width: 8),
            Text(
              narrow
                  ? '${a.backgroundJobs}'
                  : a.backgroundJobs == 1
                      ? '1 trabajo en segundo plano'
                      : '${a.backgroundJobs} trabajos en segundo plano',
              style: t.bodySmall?.copyWith(color: kAccent),
            ),
            const SizedBox(width: 16),
          ],
          if (a.muted && !narrow)
            Text('Micrófono silenciado · espacio para activar',
                style: t.bodySmall?.copyWith(color: Colors.redAccent.withValues(alpha: 0.8))),
          if (a.ready && a.linkNote.isNotEmpty && !narrow) ...[
            const SizedBox(width: 16),
            Text(a.linkNote, style: t.bodySmall?.copyWith(color: kAccent)),
          ],
          ...actions,
        ],
      ),
    );
  }
}

/// Tap target over the orb, with a pointer cursor on desktop.
class _OrbTap extends StatelessWidget {
  const _OrbTap({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: child),
      );
}
