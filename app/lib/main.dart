import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'app/assistant.dart';
import 'app/desktop_window.dart';
import 'app/main_view.dart';
import 'app/model_picker.dart';
import 'app/mute_key.dart';
import 'app/overlay_shell.dart';
import 'app/projects_panel.dart';
import 'app/settings.dart';
import 'app/wake_button.dart';
import 'app/workers_panel.dart';
import 'l10n/l10n.dart';
import 'store/legacy_data.dart';
import 'usage/usage_rings.dart';
import 'remote/remote_app.dart';
import 'vault/vault.dart';
import 'voice/model_store.dart';
import 'webhooks/webhooks.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // On a phone Minerva is the remote of a desktop that does all the processing, held upright.
  if (Platform.isAndroid || Platform.isIOS) {
    unawaited(SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]));
    // True black bars around its true black screens, so an OLED screen switches them off.
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      systemNavigationBarColor: Colors.black,
      systemNavigationBarDividerColor: Colors.black,
    ));
    runApp(const RemoteApp());
  } else {
    runApp(const MinervaApp());
  }
}

class MinervaApp extends StatefulWidget {
  const MinervaApp({super.key});

  @override
  State<MinervaApp> createState() => _MinervaAppState();
}

class _MinervaAppState extends State<MinervaApp> {
  final _window = DesktopWindow();
  final _models = ModelStore();
  final _assistant = ValueNotifier<Assistant?>(null);

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocus);
    _window.onMuteKey = () {
      final a = _assistant.value;
      if (a != null && a.ready) a.toggleMute();
    };
    unawaited(_window.init());
    _boot();
  }

  Future<void> _boot() async {
    // Before anything creates the data folder: it may still be under the app's former name.
    if (Platform.environment['MINERVA_DATA_DIR'] == null) {
      await migrateLegacyData((await getApplicationSupportDirectory()).path);
    }
    await _models.ensure();
    if (!_models.ready) return;
    final a = Assistant(models: _models, window: _window);
    _assistant.value = a;
    await a.start();
  }

  /// The native side takes the mute key ([DesktopWindow.onMuteKey]), in this window too, but not
  /// while the user types in one of its fields (unless the key is a global one).
  void _onFocus() => _window.setTyping(_typing());

  static bool _typing() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocus);
    _assistant.value?.dispose();
    _models.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: languageSetting,
        builder: (context, language, _) => MaterialApp(
          title: 'Minerva',
          debugShowCheckedModeBanner: false,
          theme: minervaTheme(),
          // The window covers the whole screen and is transparent: the app (its navigator, so
          // dialogs too) lives in the full view's panel, next to the orb and the widgets.
          color: Colors.transparent,
          builder: (context, child) => OverlayShell(window: _window, assistant: _assistant, child: child!),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: language == null ? null : Locale(language),
          localeListResolutionCallback: (_, _) => appLocale,
          home: HomePage(models: _models, assistant: _assistant),
        ),
      );
}

/// The full view's content: the first-run model download, then the main screen.
class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.models, required this.assistant});

  final ModelStore models;
  final ValueListenable<Assistant?> assistant;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: assistant,
        builder: (context, a, _) {
          if (a == null) {
            return Scaffold(
              body: ListenableBuilder(listenable: models, builder: (context, _) => _ModelsScreen(models: models)),
            );
          }
          return ListenableBuilder(
            listenable: Listenable.merge([a, a.display, a.window, a.window.panelShown]),
            builder: (context, _) => Scaffold(
              body: MainView(
                assistant: a,
                muteKey: a.muteKey.label(AppLocalizations.of(context)),
                // Once the panel has become the orb, the display shows as Minerva's widgets.
                showDisplay: a.window.panelShown.value,
                // Not in a narrow window, where the bar is full of buttons.
                leading: a.ready && MediaQuery.sizeOf(context).width >= 600 ? UsageRings(monitor: a.usage) : null,
                left: a.ready ? ProjectsPanel(workers: a.workers) : null,
                right: a.ready ? WorkersPanel(workers: a.workers) : null,
                actions: [
                  if (a.ready && a.webhooks != null) _WebhookButton(webhooks: a.webhooks!),
                  if (a.ready) _VaultButton(vault: a.vault),
                  if (a.ready) ModelButton(assistant: a),
                  if (a.ready) _LanguageButton(assistant: a),
                  if (a.ready) _VoiceButton(assistant: a),
                  if (a.ready) WakeButton(assistant: a),
                  if (a.ready) _MuteKeyButton(assistant: a),
                  if (a.ready) _PhoneButton(assistant: a),
                ],
              ),
            ),
          );
        },
      );
}

/// First run: downloading the local voice models.
class _ModelsScreen extends StatelessWidget {
  const _ModelsScreen({required this.models});

  final ModelStore models;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context);
    return Center(
      child: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Minerva', style: t.headlineMedium?.copyWith(color: kAccent, letterSpacing: 4)),
            const SizedBox(height: 24),
            if (models.error != null) ...[
              Text(l.modelsDownloadFailed, style: t.bodyLarge),
              const SizedBox(height: 8),
              Text(models.error!, style: t.bodySmall?.copyWith(color: Colors.white54)),
            ] else ...[
              Text(models.status.isEmpty ? l.modelsPreparing : models.status, style: t.bodyMedium),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: models.installing ? null : models.progress),
              const SizedBox(height: 8),
              Text(l.modelsFirstRunNote,
                  style: t.bodySmall?.copyWith(color: Colors.white38)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Opens the pairing code for the phone remote; lit while a phone is connected.
class _PhoneButton extends StatelessWidget {
  const _PhoneButton({required this.assistant});

  final Assistant assistant;

  @override
  Widget build(BuildContext context) {
    final on = assistant.onPhone;
    final l = AppLocalizations.of(context);
    return IconButton(
      tooltip: on ? l.phoneConnected : l.phoneConnect,
      onPressed: () => showDialog<void>(context: context, builder: (_) => _PairingDialog(assistant: assistant)),
      icon: Icon(on ? Icons.phone_android : Icons.phonelink_setup_outlined,
          color: on ? kAccent : Colors.white54),
    );
  }
}

/// The QR code the Minerva app on the phone scans to pair with this Mac.
class _PairingDialog extends StatefulWidget {
  const _PairingDialog({required this.assistant});

  final Assistant assistant;

  @override
  State<_PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<_PairingDialog> {
  late String _link = widget.assistant.pairingLink();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: widget.assistant,
      builder: (context, _) {
        final phone = widget.assistant.phone;
        final status = widget.assistant.onPhone
            ? l.pairingConnected
            : phone != null && phone.link.online
                ? l.pairingWaiting
                : l.connectingToRelay;
        return AlertDialog(
          title: Text(l.phoneConnect),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(12),
                  child: QrImageView(data: _link, size: 260, backgroundColor: Colors.white),
                ),
                const SizedBox(height: 16),
                Text(l.pairingInstructions, style: t.bodyMedium, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Text(status, style: t.bodySmall?.copyWith(color: kAccent), textAlign: TextAlign.center),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final link = await widget.assistant.newPairing();
                if (mounted) setState(() => _link = link);
              },
              child: Text(l.pairingNewCode),
            ),
            FilledButton(onPressed: () => Navigator.pop(context), child: Text(l.close)),
          ],
        );
      },
    );
  }
}

/// Opens this Mac's webhook address; lit while it can receive them.
class _WebhookButton extends StatelessWidget {
  const _WebhookButton({required this.webhooks});

  final Webhooks webhooks;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: webhooks,
        builder: (context, _) {
          final on = webhooks.online && webhooks.certOk;
          final l = AppLocalizations.of(context);
          return IconButton(
            tooltip: on ? l.webhooksActive : l.webhooks,
            onPressed: () => showDialog<void>(context: context, builder: (_) => _WebhookDialog(webhooks: webhooks)),
            icon: Icon(Icons.webhook, color: on ? kAccent : Colors.white54),
          );
        },
      );
}

/// The webhooks third parties can call, each at its own secret address; the assistant hears about
/// each request and creates new webhooks when asked.
class _WebhookDialog extends StatelessWidget {
  const _WebhookDialog({required this.webhooks});

  final Webhooks webhooks;

  Widget _row(BuildContext context, Webhook h) {
    final t = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context);
    final url = webhooks.urlOf(h);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(h.name, style: t.titleSmall),
                if (h.description.isNotEmpty) Text(h.description, style: t.bodySmall?.copyWith(color: Colors.white70)),
                SelectableText(url ?? '—', style: t.bodySmall?.copyWith(fontFamily: 'Menlo')),
              ],
            ),
          ),
          IconButton(
            tooltip: l.copy,
            icon: const Icon(Icons.copy, size: 18),
            onPressed: url == null
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: url));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.addressCopied)));
                    }
                  },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: webhooks,
      builder: (context, _) {
        final hooks = webhooks.hooks;
        return AlertDialog(
          title: Text(l.webhooks),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.webhooksExplanation, style: t.bodyMedium),
                const SizedBox(height: 16),
                if (hooks.isEmpty) Text(l.webhooksNone, style: t.bodyMedium?.copyWith(color: Colors.white54)),
                if (hooks.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: ListView(shrinkWrap: true, children: [for (final h in hooks) _row(context, h)]),
                  ),
                const SizedBox(height: 12),
                Text(webhooks.status, style: t.bodySmall?.copyWith(color: kAccent)),
              ],
            ),
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(context), child: Text(l.close)),
          ],
        );
      },
    );
  }
}

/// Minerva's language: the system's, or one the app has.
class _LanguageButton extends StatelessWidget {
  const _LanguageButton({required this.assistant});

  final Assistant assistant;
  static const _system = 'system';

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final current = languageSetting.value;
    return PopupMenuButton<String>(
      tooltip: l.language,
      icon: const Icon(Icons.translate, color: Colors.white54),
      onSelected: (v) => unawaited(assistant.setLanguage(v == _system ? null : v)),
      itemBuilder: (_) => [
        CheckedPopupMenuItem(value: _system, checked: current == null, child: Text(l.languageSystem)),
        for (final c in languageChoices)
          CheckedPopupMenuItem(value: c, checked: current == c, child: Text(languageNames[c] ?? c)),
      ],
    );
  }
}

/// The voice Minerva reads its replies with.
class _VoiceButton extends StatelessWidget {
  const _VoiceButton({required this.assistant});

  final Assistant assistant;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return PopupMenuButton<int>(
      tooltip: l.voice,
      icon: const Icon(Icons.record_voice_over_outlined, color: Colors.white54),
      onSelected: assistant.setVoice,
      itemBuilder: (_) => [
        for (var v = 0; v < voiceCount; v++)
          CheckedPopupMenuItem(value: v, checked: assistant.voice == v, child: Text(voiceName(l, v))),
      ],
    );
  }
}

/// Opens the mute key setting.
class _MuteKeyButton extends StatelessWidget {
  const _MuteKeyButton({required this.assistant});

  final Assistant assistant;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: AppLocalizations.of(context).muteKey,
        onPressed: () => showDialog<void>(context: context, builder: (_) => _MuteKeyDialog(assistant: assistant)),
        icon: const Icon(Icons.keyboard_outlined, color: Colors.white54),
      );
}

/// The key that mutes and unmutes the mic: the current one, recording another, Caps Lock, back to
/// Space, and the permission it needs in other apps.
class _MuteKeyDialog extends StatefulWidget {
  const _MuteKeyDialog({required this.assistant});

  final Assistant assistant;

  @override
  State<_MuteKeyDialog> createState() => _MuteKeyDialogState();
}

class _MuteKeyDialogState extends State<_MuteKeyDialog> {
  bool _recording = false;

  Assistant get _a => widget.assistant;

  Future<void> _record() async {
    setState(() => _recording = true);
    final key = await _a.window.recordMuteKey();
    if (!mounted) return;
    setState(() => _recording = false);
    if (key != null) _a.setMuteKey(key);
  }

  @override
  void dispose() {
    if (_recording) unawaited(_a.window.cancelMuteKeyRecord());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([_a, _a.window]),
      builder: (context, _) {
        final key = _a.muteKey;
        return AlertDialog(
          title: Text(l.muteKey),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_recording ? l.muteKeyRecording : l.muteKeyCurrent(key.label(l)),
                    style: t.titleMedium?.copyWith(color: _recording ? kAccent : null)),
                const SizedBox(height: 12),
                Text(l.muteKeyHint, style: t.bodySmall?.copyWith(color: Colors.white54)),
                if (!_a.window.keyAccess || (key.global && !_a.window.keyActive)) ...[
                  const SizedBox(height: 12),
                  Text(l.muteKeyNoAccess, style: t.bodySmall?.copyWith(color: Colors.orangeAccent)),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(onPressed: _a.window.requestKeyAccess, child: Text(l.muteKeyGrant)),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            if (key != MuteKey.space)
              TextButton(onPressed: _recording ? null : () => _a.setMuteKey(MuteKey.space), child: Text(l.muteKeyReset)),
            if (key != MuteKey.capsLock)
              TextButton(
                  onPressed: _recording ? null : () => _a.setMuteKey(MuteKey.capsLock), child: Text(l.muteKeyCapsLock)),
            TextButton(onPressed: _recording ? null : _record, child: Text(l.muteKeyChange)),
            FilledButton(onPressed: () => Navigator.pop(context), child: Text(l.close)),
          ],
        );
      },
    );
  }
}

class _VaultButton extends StatelessWidget {
  const _VaultButton({required this.vault});

  final Vault vault;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: AppLocalizations.of(context).vaultCredentials,
        onPressed: () => showDialog<void>(context: context, builder: (_) => _VaultDialog(vault: vault)),
        icon: const Icon(Icons.vpn_key, color: Colors.white54),
      );
}

/// The saved credentials: names, descriptions and field names (values are never shown), and
/// deleting them.
class _VaultDialog extends StatelessWidget {
  const _VaultDialog({required this.vault});

  final Vault vault;

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
    if (ok == true) await vault.delete(name);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: vault,
      builder: (context, _) {
        final items = vault.credentials;
        return AlertDialog(
          title: Text(l.vaultCredentials),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.vaultDialogIntro, style: t.bodyMedium),
                const SizedBox(height: 16),
                if (vault.loadError != null)
                  Text(l.vaultUnavailable(vault.loadError!), style: t.bodySmall?.copyWith(color: Colors.redAccent))
                else if (items.isEmpty)
                  Text(l.vaultEmpty, style: t.bodySmall?.copyWith(color: Colors.white54))
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final c in items)
                          ListTile(
                            key: ValueKey('vault-${c.name}'),
                            contentPadding: EdgeInsets.zero,
                            title: Text(c.name, style: t.titleSmall?.copyWith(color: kAccent)),
                            subtitle: Text(
                              [
                                if (c.description.isNotEmpty) c.description,
                                l.vaultFields([for (final f in c.fields) f.name].join(', ')),
                              ].join('\n'),
                              style: t.bodySmall?.copyWith(color: Colors.white54),
                            ),
                            trailing: IconButton(
                              tooltip: l.delete,
                              icon: const Icon(Icons.delete_outline, color: Colors.white54),
                              onPressed: () => _delete(context, c.name),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(context), child: Text(l.close)),
          ],
        );
      },
    );
  }
}
