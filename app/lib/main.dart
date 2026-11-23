import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/assistant.dart';
import 'display/display.dart';
import 'presence/presence.dart';
import 'voice/model_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DisplaiApp());
}

const _background = Color(0xFF05070A);
const _accent = Color(0xFF4FD8FF);

class DisplaiApp extends StatelessWidget {
  const DisplaiApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'DisplAI',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(seedColor: _accent, brightness: Brightness.dark),
          scaffoldBackgroundColor: _background,
        ),
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
              builder: (context, _) => _Main(assistant: a),
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
            Text('DisplAI', style: t.headlineMedium?.copyWith(color: _accent, letterSpacing: 4)),
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

class _Main extends StatelessWidget {
  const _Main({required this.assistant});

  final Assistant assistant;

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
              if (a.confirmation != null)
                Positioned.fill(child: _ConfirmCard(assistant: a, summary: a.confirmation!)),
              // While something is on screen the presence shrinks to a large orb in the corner.
              if (showing)
                Positioned(
                  top: 12,
                  right: 12,
                  child: IgnorePointer(
                    child: PresenceView(signal: a.presence, compact: true, compactSize: 180),
                  ),
                ),
            ],
              ),
            ),
          ),
        ),
        _StatusBar(assistant: a),
      ],
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.assistant});

  final Assistant assistant;

  @override
  Widget build(BuildContext context) {
    final a = assistant;
    final t = Theme.of(context).textTheme;
    final line = !a.ready
        ? 'Cargando la voz…'
        : a.activity.isNotEmpty
            ? a.activity
            : a.lastHeard;
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0x1AFFFFFF)))),
      child: Row(
        children: [
          IconButton(
            tooltip: a.muted ? 'Activar micrófono (espacio)' : 'Silenciar micrófono (espacio)',
            onPressed: a.ready ? a.toggleMute : null,
            icon: Icon(a.muted ? Icons.mic_off : Icons.mic, color: a.muted ? Colors.redAccent : _accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              line,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.bodyMedium?.copyWith(
                color: a.activity.isNotEmpty ? _accent : Colors.white60,
                fontStyle: a.activity.isNotEmpty ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          ),
          if (a.muted)
            Text('Micrófono silenciado · espacio para activar',
                style: t.bodySmall?.copyWith(color: Colors.redAccent.withValues(alpha: 0.8))),
        ],
      ),
    );
  }
}

/// A risky action waiting for the user's OK (also asked by voice: "sí" / "no").
class _ConfirmCard extends StatelessWidget {
  const _ConfirmCard({required this.assistant, required this.summary});

  final Assistant assistant;
  final String summary;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ColoredBox(
      color: const Color(0xB3000000),
      child: Center(
        child: Container(
          width: 560,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: const Color(0xFF0D1B22),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.6)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.amberAccent),
                const SizedBox(width: 10),
                Text('¿Lo hago?', style: t.titleLarge),
              ]),
              const SizedBox(height: 16),
              SelectableText(summary, style: t.bodyLarge?.copyWith(fontFamily: 'Menlo', height: 1.4)),
              const SizedBox(height: 20),
              Row(
                children: [
                  Text('Di «sí» o «no»', style: t.bodySmall?.copyWith(color: Colors.white54)),
                  const Spacer(),
                  TextButton(onPressed: () => assistant.answerConfirmation(false), child: const Text('No')),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: () => assistant.answerConfirmation(true), child: const Text('Sí, hazlo')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
