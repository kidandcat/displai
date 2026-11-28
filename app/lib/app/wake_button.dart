import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../presence/presence.dart';
import 'main_view.dart';
import 'settings.dart';

/// Wake word mode in the status bar, on the Mac and on the phone: off, always, or automatic by
/// voice (with how long it stays on, and the voice profile). Blue while it is on, like the orb.
class WakeButton extends StatelessWidget {
  const WakeButton({super.key, required this.assistant});

  final AssistantSettings assistant;

  static const _reset = 'reset';

  @override
  Widget build(BuildContext context) {
    final a = assistant;
    final l = AppLocalizations.of(context);
    final note = voiceIdNote(l, a.voiceId, a.voiceSamples);
    return PopupMenuButton<Object>(
      tooltip: a.wakeActive ? l.wakeActive : l.wakeMode,
      icon: Icon(
        a.wakeMode == WakeMode.off ? Icons.hearing_outlined : Icons.hearing,
        color: a.wakeActive
            ? kPresenceWakeAccent
            : a.wakeMode == WakeMode.off
                ? Colors.white54
                : kAccent,
      ),
      onSelected: (v) => switch (v) {
        WakeMode m => a.setWakeMode(m),
        int minutes => a.setWakeTimeout(minutes),
        _reset => a.resetVoiceProfile(),
        _ => null,
      },
      itemBuilder: (_) => [
        PopupMenuItem(enabled: false, child: Text(l.wakeMode)),
        for (final m in WakeMode.values)
          CheckedPopupMenuItem(value: m, checked: a.wakeMode == m, child: Text(wakeModeName(l, m))),
        if (a.wakeMode == WakeMode.auto) ...[
          const PopupMenuDivider(),
          for (final n in wakeTimeouts)
            CheckedPopupMenuItem(value: n, checked: a.wakeTimeout == n, child: Text(l.wakeTimeoutMinutes(n))),
          const PopupMenuDivider(),
          if (note != null) PopupMenuItem(enabled: false, child: Text(note)),
          PopupMenuItem(value: _reset, enabled: a.voiceSamples > 0, child: Text(l.voiceIdReset)),
        ],
      ],
    );
  }
}
