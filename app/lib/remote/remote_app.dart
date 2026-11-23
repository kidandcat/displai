import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';

import '../app/main_view.dart';
import 'protocol.dart';
import 'remote_assistant.dart';

/// DisplAI on a phone: the remote of a desktop that does all the processing.
class RemoteApp extends StatelessWidget {
  const RemoteApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'DisplAI',
        debugShowCheckedModeBanner: false,
        theme: displaiTheme(),
        home: const RemoteHome(),
      );
}

class RemoteHome extends StatefulWidget {
  const RemoteHome({super.key});

  @override
  State<RemoteHome> createState() => _RemoteHomeState();
}

class _RemoteHomeState extends State<RemoteHome> with WidgetsBindingObserver {
  /// Pairing links opened from outside the app (displai://pair?...), see MainActivity.
  static const _links = MethodChannel('displai/link');

  RemoteAssistant? _assistant;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _links.setMethodCallHandler((call) async {
      if (call.method == 'link' && call.arguments is String) _pair(call.arguments as String);
    });
    unawaited(_load());
  }

  Future<File> _pairingFile() async =>
      File('${(await getApplicationSupportDirectory()).path}/remote.json');

  Future<void> _load() async {
    try {
      final initial = await _links.invokeMethod<String>('initial');
      if (initial != null && await _pair(initial)) return;
    } on MissingPluginException {
      // No native link handler on this platform.
    }
    try {
      final f = await _pairingFile();
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        _connect(m['relay'] as String, m['key'] as String);
      }
    } catch (e) {
      debugPrint('could not read the pairing: $e');
    }
    if (mounted) setState(() => _loaded = true);
  }

  /// Pairs with the desktop in [link]; false when it is not a pairing link.
  Future<bool> _pair(String link) async {
    final p = RemoteProtocol.parsePairingLink(link);
    if (p == null) return false;
    final (relay, key) = p;
    if (_assistant?.key == key) return true;
    await (await _pairingFile()).writeAsString(jsonEncode({'relay': relay, 'key': key}));
    _connect(relay, key);
    return true;
  }

  void _connect(String relay, String key) {
    _assistant?.dispose();
    final a = RemoteAssistant(relay: relay, key: key)..start();
    if (!mounted) return;
    setState(() {
      _assistant = a;
      _loaded = true;
    });
  }

  Future<void> _unpair() async {
    final f = await _pairingFile();
    if (await f.exists()) await f.delete();
    _assistant?.dispose();
    setState(() => _assistant = null);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _assistant?.resumed();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _assistant?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = _assistant;
    return Scaffold(
      body: SafeArea(
        child: !_loaded
            ? const SizedBox.shrink()
            : a == null
                ? _PairScreen(onCode: _pair)
                : ListenableBuilder(
                    listenable: Listenable.merge([a, a.display]),
                    builder: (context, _) => LayoutBuilder(builder: (context, box) {
                      // The display is the screen minus the status bar.
                      a.setDisplaySize(Size(box.maxWidth, box.maxHeight - 52));
                      return MainView(
                        assistant: a,
                        compactOrb: 96,
                        actions: [
                          PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert, color: Colors.white54),
                            onSelected: (v) {
                              if (v == 'unpair') _unpair();
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'unpair', child: Text('Desvincular del ordenador')),
                            ],
                          ),
                        ],
                      );
                    }),
                  ),
      ),
    );
  }
}

/// Not paired yet: scan the QR code that DisplAI shows on the desktop.
class _PairScreen extends StatefulWidget {
  const _PairScreen({required this.onCode});

  final Future<bool> Function(String link) onCode;

  @override
  State<_PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<_PairScreen> {
  bool _scanning = false;
  bool _busy = false;
  String? _note;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v == null) continue;
      _busy = true;
      final ok = await widget.onCode(v);
      _busy = false;
      if (!ok && mounted) setState(() => _note = 'Ese código no es de DisplAI.');
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          Text('DisplAI', textAlign: TextAlign.center,
              style: t.headlineMedium?.copyWith(color: kAccent, letterSpacing: 4)),
          const SizedBox(height: 16),
          Text('En el ordenador, pulsa el botón del móvil en la barra de abajo y escanea el código.',
              textAlign: TextAlign.center, style: t.bodyLarge),
          const SizedBox(height: 8),
          Text('El móvil será el micrófono, el altavoz y la pantalla; todo se procesa en el ordenador.',
              textAlign: TextAlign.center, style: t.bodySmall?.copyWith(color: Colors.white54)),
          const SizedBox(height: 24),
          Expanded(
            child: _scanning
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: MobileScanner(onDetect: _onDetect),
                  )
                : Center(
                    child: FilledButton.icon(
                      onPressed: () => setState(() => _scanning = true),
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Escanear el código'),
                    ),
                  ),
          ),
          if (_note != null) ...[
            const SizedBox(height: 12),
            Text(_note!, textAlign: TextAlign.center, style: t.bodyMedium?.copyWith(color: Colors.redAccent)),
          ],
        ],
      ),
    );
  }
}
