import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/main_view.dart';
import '../app/model_picker.dart';
import '../app/settings.dart';
import '../brain/models.dart';
import '../l10n/l10n.dart';
import 'remote_assistant.dart';

/// The desktop's settings on the phone: the same ones its status bar has (the models, the
/// language, the voice, the wake word, the credentials and the webhooks), in one scrolling screen. Every change
/// goes to the desktop, which applies it.
class RemoteSettingsPage extends StatelessWidget {
  const RemoteSettingsPage({super.key, required this.assistant});

  final RemoteAssistant assistant;

  static const _system = 'system';

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.settings), backgroundColor: Theme.of(context).scaffoldBackgroundColor),
      body: ListenableBuilder(
        listenable: assistant,
        builder: (context, _) {
          final a = assistant;
          final t = Theme.of(context).textTheme;
          final on = a.ready && a.settingsKnown;
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(on ? l.settingsAppliedOnComputer : l.settingsOffline,
                    style: t.bodySmall?.copyWith(color: on ? Colors.white54 : kAccent)),
              ),
              _Section(l.modelTitle),
              _modelTile(context, l.modelConversation, a.brainModel, workers: false, enabled: on),
              _modelTile(context, l.modelWorkers, a.workerModel, workers: true, enabled: on),
              const Divider(height: 24, color: Colors.white12),
              _menuTile<int>(
                context,
                icon: Icons.record_voice_over_outlined,
                title: l.voice,
                value: a.voice,
                enabled: on,
                items: {for (var v = 0; v < voiceCount; v++) v: voiceName(l, v)},
                onChanged: a.setVoice,
              ),
              _menuTile<String>(
                context,
                icon: Icons.translate,
                title: l.language,
                value: languageSetting.value ?? _system,
                enabled: on,
                items: {_system: l.languageSystem, for (final c in languageChoices) c: languageNames[c] ?? c},
                onChanged: (v) => a.setLanguage(v == _system ? null : v),
              ),
              ..._wake(context, on),
              _Section(l.vaultCredentials),
              ..._credentials(context, on),
              if (a.webhooks != null) ...[
                _Section(l.webhooks),
                ..._webhooks(context),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _modelTile(BuildContext context, String title, ModelChoice choice,
      {required bool workers, required bool enabled}) {
    final l = AppLocalizations.of(context);
    final model = assistant.catalogFor(choice.provider)?.find(choice.model);
    final effort = effortFor(model, choice.effort);
    return ListTile(
      enabled: enabled,
      leading: Icon(workers ? Icons.engineering_outlined : Icons.memory),
      title: Text(title),
      subtitle: Text(
        [
          choice.provider.label,
          model?.name ?? choice.model,
          if (effort != null) effortName(l, effort),
          if (choice.fast && (model?.fast ?? false)) l.speedFast,
        ].join(' · '),
        style: const TextStyle(color: Colors.white54),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => ModelPicker(assistant: assistant, workers: workers),
      ),
    );
  }

  Widget _menuTile<T>(
    BuildContext context, {
    required IconData icon,
    required String title,
    required T value,
    required bool enabled,
    required Map<T, String> items,
    required void Function(T) onChanged,
  }) =>
      ListTile(
        enabled: enabled,
        leading: Icon(icon),
        title: Text(title),
        trailing: DropdownButton<T>(
          value: items.containsKey(value) ? value : null,
          underline: const SizedBox(),
          items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: enabled ? (v) => v == null ? null : onChanged(v) : null,
        ),
      );

  /// Wake word mode, and in automatic mode how long it stays on and the voice profile.
  List<Widget> _wake(BuildContext context, bool enabled) {
    final a = assistant;
    final l = AppLocalizations.of(context);
    final note = voiceIdNote(l, a.voiceId, a.voiceSamples);
    return [
      _menuTile<WakeMode>(
        context,
        icon: Icons.hearing,
        title: l.wakeMode,
        value: a.wakeMode,
        enabled: enabled,
        items: {for (final m in WakeMode.values) m: wakeModeName(l, m)},
        onChanged: a.setWakeMode,
      ),
      if (a.wakeMode == WakeMode.auto) ...[
        _menuTile<int>(
          context,
          icon: Icons.timer_outlined,
          title: l.wakeTimeout,
          value: a.wakeTimeout,
          enabled: enabled,
          items: {for (final n in wakeTimeouts) n: l.minutes(n)},
          onChanged: a.setWakeTimeout,
        ),
        ListTile(
          enabled: enabled,
          leading: const Icon(Icons.record_voice_over),
          title: Text(note ?? l.wakeModeAuto),
          trailing: IconButton(
            tooltip: l.voiceIdReset,
            icon: const Icon(Icons.restart_alt),
            onPressed: enabled && a.voiceSamples > 0 ? a.resetVoiceProfile : null,
          ),
        ),
      ],
    ];
  }

  List<Widget> _credentials(BuildContext context, bool enabled) {
    final a = assistant;
    final l = AppLocalizations.of(context);
    final t = Theme.of(context).textTheme;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Text(l.vaultDialogIntro, style: t.bodySmall?.copyWith(color: Colors.white54)),
      ),
      if (a.vaultError != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(l.vaultUnavailable(a.vaultError!), style: t.bodySmall?.copyWith(color: Colors.redAccent)),
        )
      else if (a.credentials.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(l.vaultEmpty, style: t.bodyMedium?.copyWith(color: Colors.white54)),
        )
      else
        for (final c in a.credentials)
          ListTile(
            key: ValueKey('vault-${c.name}'),
            leading: const Icon(Icons.vpn_key_outlined),
            title: Text(c.name, style: const TextStyle(color: kAccent)),
            subtitle: Text(
              [if (c.description.isNotEmpty) c.description, l.vaultFields(c.fields.join(', '))].join('\n'),
              style: const TextStyle(color: Colors.white54),
            ),
            trailing: IconButton(
              tooltip: l.delete,
              icon: const Icon(Icons.delete_outline, color: Colors.white54),
              onPressed: enabled ? () => _delete(context, c.name) : null,
            ),
          ),
    ];
  }

  Future<void> _delete(BuildContext context, String name) async {
    final l = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l.vaultDeleteConfirm(name)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.delete)),
        ],
      ),
    );
    if (ok == true) assistant.deleteCredential(name);
  }

  List<Widget> _webhooks(BuildContext context) {
    final a = assistant;
    final l = AppLocalizations.of(context);
    final t = Theme.of(context).textTheme;
    final hooks = a.webhooks!;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Row(
          children: [
            Icon(Icons.webhook, size: 16, color: a.webhooksOn ? kAccent : Colors.white38),
            const SizedBox(width: 8),
            Expanded(child: Text(a.webhooksStatus, style: t.bodySmall?.copyWith(color: kAccent))),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Text(l.webhooksExplanation, style: t.bodySmall?.copyWith(color: Colors.white54)),
      ),
      if (hooks.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(l.webhooksNone, style: t.bodyMedium?.copyWith(color: Colors.white54)),
        ),
      for (final h in hooks)
        ListTile(
          title: Text(h.name),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (h.description.isNotEmpty) Text(h.description, style: const TextStyle(color: Colors.white70)),
              SelectableText(h.url ?? '—', style: t.bodySmall?.copyWith(fontFamily: 'monospace')),
            ],
          ),
          trailing: IconButton(
            tooltip: l.copy,
            icon: const Icon(Icons.copy, size: 18),
            onPressed: h.url == null
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: h.url!));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.addressCopied)));
                    }
                  },
          ),
        ),
    ];
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(title.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: kAccent, letterSpacing: 1.2)),
      );
}
