import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../display/display.dart';
import '../l10n/l10n.dart';
import '../presence/presence.dart';
import 'assistant_ui.dart';

const kBackground = Color(0xFF07050A);
const kAccent = Color(0xFFA87CFF);

ThemeData minervaTheme() => ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(seedColor: kAccent, brightness: Brightness.dark),
      scaffoldBackgroundColor: kBackground,
    );

/// The main screen, the same on the desktop and on the phone: the presence orb, the display
/// on top of it, and a slim bar of status notes and actions (the transcript and the activity
/// are spoken, not shown; the orb turns red when the mic is muted).
class MainView extends StatelessWidget {
  const MainView({
    super.key,
    required this.assistant,
    this.actions = const [],
    this.compactOrb = 180,
    this.showDisplay = true,
  });

  final AssistantUi assistant;

  /// Extra buttons at the end of the status bar.
  final List<Widget> actions;

  /// Size of the corner orb while something is on screen.
  final double compactOrb;

  /// Draws the display (false while it is shown elsewhere, as a widget over other apps).
  final bool showDisplay;

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
          child: Text(AppLocalizations.of(context).startFailed('${a.error}'),
              style: const TextStyle(color: Colors.white70)),
        ),
      );
    }
    final showing = showDisplay && !a.display.isEmpty;
    return Column(
      children: [
        Expanded(
          // The display is transparent while empty, so the presence animation shows through.
          child: RepaintBoundary(
            key: showDisplay ? a.screenKey : null,
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
                  // The header of each view leaves room for the corner orb.
                  if (showDisplay) DisplayView(controller: a.display, cornerReserve: Size.square(12 + compactOrb)),
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
    final l = AppLocalizations.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Container(
      height: 52,
      padding: EdgeInsets.symmetric(horizontal: narrow ? 4 : 16),
      child: Row(
        children: [
          const Spacer(),
          if (!a.ready) ...[
            Text(a.linkNote.isNotEmpty ? a.linkNote : l.loadingVoice,
                style: t.bodySmall?.copyWith(color: kAccent, fontStyle: FontStyle.italic)),
            const SizedBox(width: 16),
          ],
          if (a.ready && a.backgroundJobs > 0) ...[
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
            ),
            const SizedBox(width: 8),
            Text(
              narrow ? '${a.backgroundJobs}' : l.backgroundJobs(a.backgroundJobs),
              style: t.bodySmall?.copyWith(color: kAccent),
            ),
            const SizedBox(width: 16),
          ],
          if (a.muted && !narrow)
            Text(l.micMuted,
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
