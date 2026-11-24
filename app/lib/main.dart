import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'app/assistant.dart';
import 'app/main_view.dart';
import 'presence/presence.dart';
import 'store/legacy_data.dart';
import 'remote/remote_app.dart';
import 'vault/vault.dart';
import 'vault/vault_strings.dart';
import 'voice/model_store.dart';
import 'webhooks/webhooks.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // On a phone Minerva is the remote of a desktop that does all the processing, held upright.
  if (Platform.isAndroid || Platform.isIOS) {
    unawaited(SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]));
    runApp(const RemoteApp());
  } else {
    runApp(const MinervaApp());
  }
}

class MinervaApp extends StatelessWidget {
  const MinervaApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Minerva',
        debugShowCheckedModeBanner: false,
        theme: minervaTheme(),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _models = ModelStore();
  Assistant? _assistant;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    _boot();
  }

  Future<void> _boot() async {
    // Before anything creates the data folder: it may still be under the app's former name.
    if (Platform.environment['MINERVA_DATA_DIR'] == null) {
      await migrateLegacyData((await getApplicationSupportDirectory()).path);
    }
    await _models.ensure();
    if (!_models.ready) return;
    final a = Assistant(models: _models);
    setState(() => _assistant = a);
    await a.start();
  }

  /// While the window has focus (and the user is not typing in a field): Space toggles the mic,
  /// the left and right arrows move between the views in the timeline.
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return false;
    final a = _assistant;
    if (a == null || !a.ready || _typing()) return false;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.space && e is KeyDownEvent) {
      a.toggleMute();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
      if (a.display.timeline.isEmpty) return false;
      key == LogicalKeyboardKey.arrowLeft ? a.display.previous() : a.display.next();
      return true;
    }
    return false;
  }

  static bool _typing() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _assistant?.dispose();
    _models.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = _assistant;
    if (a == null) {
      return Scaffold(
        body: ListenableBuilder(listenable: _models, builder: (context, _) => _ModelsScreen(models: _models)),
      );
    }
    return ListenableBuilder(
      listenable: Listenable.merge([a, a.display, a.window]),
      builder: (context, _) => a.window.overlay
          // A phone is connected: the window is just the orb on a dark disc, the rest transparent.
          ? Scaffold(
              backgroundColor: Colors.transparent,
              body: Center(
                child: Container(
                  width: 124,
                  height: 124,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: kBackground.withValues(alpha: 0.88),
                    border: Border.all(color: kAccent.withValues(alpha: 0.25)),
                  ),
                  child: ClipOval(
                    child: PresenceView(signal: a.presence, compact: true, compactSize: 122),
                  ),
                ),
              ),
            )
          : Scaffold(
              body: MainView(
                assistant: a,
                actions: [
                  if (a.ready && a.webhooks != null) _WebhookButton(webhooks: a.webhooks!),
                  if (a.ready) _VaultButton(vault: a.vault),
                  if (a.ready) _PhoneButton(assistant: a),
                ],
              ),
            ),
    );
  }
}

/// First run: downloading the local voice models.
class _ModelsScreen extends StatelessWidget {
  const _ModelsScreen({required this.models});

  final ModelStore models;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Minerva', style: t.headlineMedium?.copyWith(color: kAccent, letterSpacing: 4)),
            const SizedBox(height: 24),
            if (models.error != null) ...[
              Text('No se pudieron descargar los modelos de voz.', style: t.bodyLarge),
              const SizedBox(height: 8),
              Text(models.error!, style: t.bodySmall?.copyWith(color: Colors.white54)),
            ] else ...[
              Text(models.status.isEmpty ? 'Preparando…' : models.status, style: t.bodyMedium),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: models.status.startsWith('Instalando') ? null : models.progress),
              const SizedBox(height: 8),
              Text('Solo la primera vez. Todo se procesa en este Mac.',
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
    return IconButton(
      tooltip: on ? 'Móvil conectado' : 'Conectar el móvil',
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
    return ListenableBuilder(
      listenable: widget.assistant,
      builder: (context, _) {
        final phone = widget.assistant.phone;
        final status = widget.assistant.onPhone
            ? 'Móvil conectado. Mientras lo esté, el Mac no escucha ni habla.'
            : phone != null && phone.link.online
                ? 'Esperando al móvil…'
                : 'Conectando con el intermediario…';
        return AlertDialog(
          title: const Text('Conectar el móvil'),
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
                Text('Escanéalo con la app Minerva del móvil. El móvil será el micrófono, el altavoz y '
                    'la pantalla; todo se sigue procesando en este Mac.',
                    style: t.bodyMedium, textAlign: TextAlign.center),
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
              child: const Text('Nuevo código'),
            ),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar')),
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
          return IconButton(
            tooltip: on ? 'Webhooks activos' : 'Webhooks',
            onPressed: () => showDialog<void>(context: context, builder: (_) => _WebhookDialog(webhooks: webhooks)),
            icon: Icon(Icons.webhook, color: on ? kAccent : Colors.white54),
          );
        },
      );
}

/// The address third parties can send webhooks to; the assistant hears about each one.
class _WebhookDialog extends StatelessWidget {
  const _WebhookDialog({required this.webhooks});

  final Webhooks webhooks;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: webhooks,
      builder: (context, _) {
        final url = webhooks.url;
        return AlertDialog(
          title: const Text('Webhooks'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Otros servicios pueden avisar a Minerva llamando a esta dirección (con cualquier ruta '
                    'detrás). El cifrado termina en este Mac: el intermediario no ve lo que llega. '
                    'Mantenla en privado: quien la tenga puede escribir a Minerva.',
                    style: t.bodyMedium),
                const SizedBox(height: 16),
                SelectableText(url ?? '—', style: t.titleSmall?.copyWith(fontFamily: 'Menlo')),
                const SizedBox(height: 12),
                Text(webhooks.status, style: t.bodySmall?.copyWith(color: kAccent)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: url == null
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: url));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Dirección copiada')));
                      }
                    },
              child: const Text('Copiar'),
            ),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar')),
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
        tooltip: VaultStrings.button,
        onPressed: () => showDialog<void>(context: context, builder: (_) => _VaultDialog(vault: vault)),
        icon: const Icon(Icons.key, color: Colors.white54),
      );
}

/// The saved credentials: names, descriptions and field names (values are never shown), and
/// deleting them.
class _VaultDialog extends StatelessWidget {
  const _VaultDialog({required this.vault});

  final Vault vault;

  Future<void> _delete(BuildContext context, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(VaultStrings.deleteConfirm(name)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text(VaultStrings.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text(VaultStrings.delete)),
        ],
      ),
    );
    if (ok == true) await vault.delete(name);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: vault,
      builder: (context, _) {
        final items = vault.credentials;
        return AlertDialog(
          title: const Text(VaultStrings.dialogTitle),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(VaultStrings.dialogIntro, style: t.bodyMedium),
                const SizedBox(height: 16),
                if (vault.loadError != null)
                  Text(VaultStrings.unavailable(vault.loadError!), style: t.bodySmall?.copyWith(color: Colors.redAccent))
                else if (items.isEmpty)
                  Text(VaultStrings.empty, style: t.bodySmall?.copyWith(color: Colors.white54))
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
                                VaultStrings.fields([for (final f in c.fields) f.name]),
                              ].join('\n'),
                              style: t.bodySmall?.copyWith(color: Colors.white54),
                            ),
                            trailing: IconButton(
                              tooltip: VaultStrings.delete,
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
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text(VaultStrings.close)),
          ],
        );
      },
    );
  }
}
