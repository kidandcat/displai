import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'app/assistant.dart';
import 'app/main_view.dart';
import 'remote/remote_app.dart';
import 'voice/model_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // On a phone Minerva is the remote of a desktop that does all the processing.
  runApp(Platform.isAndroid || Platform.isIOS ? const RemoteApp() : const MinervaApp());
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
    return Scaffold(
      body: a == null
          ? ListenableBuilder(listenable: _models, builder: (context, _) => _ModelsScreen(models: _models))
          : ListenableBuilder(
              listenable: Listenable.merge([a, a.display]),
              builder: (context, _) => MainView(
                assistant: a,
                actions: [if (a.ready) _PhoneButton(assistant: a)],
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
