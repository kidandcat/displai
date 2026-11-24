import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'app/assistant.dart';
import 'app/main_view.dart';
import 'l10n/l10n.dart';
import 'presence/presence.dart';
import 'store/legacy_data.dart';
import 'remote/remote_app.dart';
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
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        localeListResolutionCallback: (locales, _) => resolveLocale(locales),
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

/// The address third parties can send webhooks to; the assistant hears about each one.
class _WebhookDialog extends StatelessWidget {
  const _WebhookDialog({required this.webhooks});

  final Webhooks webhooks;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: webhooks,
      builder: (context, _) {
        final url = webhooks.url;
        return AlertDialog(
          title: Text(l.webhooks),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.webhooksExplanation, style: t.bodyMedium),
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
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.addressCopied)));
                      }
                    },
              child: Text(l.copy),
            ),
            FilledButton(onPressed: () => Navigator.pop(context), child: Text(l.close)),
          ],
        );
      },
    );
  }
}
