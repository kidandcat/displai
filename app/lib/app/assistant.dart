import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show GlobalKey, WidgetsBinding;

import '../audio/native_audio.dart';
import '../brain/claude_session.dart';
import '../brain/system_prompt.dart';
import '../display/display.dart';
import '../mcp/display_mcp_server.dart';
import '../presence/presence.dart';
import '../computer/computer_tools.dart';
import '../tools/command_tools.dart';
import '../tools/tool_provider.dart';
import '../voice/listener.dart';
import '../voice/model_store.dart';
import '../voice/speaker.dart';

/// Wires voice, brain and display together (docs/design.md §2 and §5).
///
/// Mic (echo-cancelled) → [Listener] → [ClaudeSession] → sentences → [Speaker] → [NativeAudio].
/// Display tool calls arrive through the embedded MCP server; partial tool input streams into
/// the [DisplayController] while Claude is still writing it.
class Assistant extends ChangeNotifier {
  Assistant({required this.models, this.model = 'opus', this.effort = 'low', this.voice = 1});

  final ModelStore models;
  final String model;
  final String effort;

  /// Supertonic 3 speaker id: 0–4 are female voices (F1–F5), 5–9 male (M1–M5).
  final int voice;

  /// The user can resume talking this long after the answer became audible and it still
  /// counts as the same turn (design §5, continuation merge).
  static const continuationWindow = Duration(seconds: 2);

  final audio = NativeAudio();
  final display = DisplayController();
  final presence = PresenceSignal();

  late final Listener _listener;
  late final Speaker _speaker;
  late final ClaudeSession _claude;
  late final DisplayMcpServer _mcp;
  final _subs = <StreamSubscription<Object?>>[];

  /// DisplAI's own host tools (served from our MCP server, not the brain's built-ins).
  final List<ToolProvider> providers = [CommandTools(), ComputerTools()];

  /// Wraps what DisplAI shows (display, presence, cards) so the brain can capture it.
  final GlobalKey screenKey = GlobalKey(debugLabel: 'displai-screen');

  static const _snapshotTool = McpTool(
    'snapshot',
    'Capture how DisplAI\'s own display looks right now, as an image. Use it to check a view '
        'you just showed (layout, fit, readability). For the rest of the Mac use screen.',
    {'type': 'object', 'properties': {}},
  );

  /// A risky action waiting for the user's yes/no (shown as a card, asked by voice).
  String? confirmation;
  Completer<bool>? _confirm;
  Timer? _confirmTimeout;

  /// Something the user said while a confirmation was pending that was not a yes/no:
  /// sent as the next turn once the current one ends.
  String? _queued;

  static const confirmTimeout = Duration(seconds: 45);

  bool ready = false;
  String? error;

  bool _muted = false;
  bool get muted => _muted;

  /// Last thing the user said (shown in the status bar).
  String lastHeard = '';

  /// What the brain is doing right now, e.g. "Buscando en la web…" (empty when nothing).
  String activity = '';

  // Turn state.
  int _generation = 0;
  int _pendingTts = 0;
  final _sentence = StringBuffer();
  bool _barged = false;
  String _lastText = '';
  String _carry = '';
  DateTime? _firstAudioAt;
  DateTime? _turnSpeechEnd;
  Float32List? _earcon;

  bool get speaking => _pendingTts > 0 || audio.isPlaying;
  bool get busy => _claude.busy || speaking;

  Future<void> start() async {
    try {
      _speaker = await Speaker.start(modelDir: models.supertonic, voice: voice);
      _listener = await Listener.start(vadModel: models.vad, parakeetDir: models.parakeet);
      _mcp = DisplayMcpServer(
        tools: [
          for (final t in DisplayController.toolSpecs) McpTool(t.name, t.description, t.inputSchema),
          _snapshotTool,
          for (final p in providers) ...p.tools,
        ],
        handler: _handleTool,
        onCall: (name) => _setActivity(''),
      );
      await _mcp.start();
      _claude = ClaudeSession(
        model: model,
        effort: effort,
        systemPrompt: systemPrompt,
        mcpUrl: _mcp.url,
        workDir: '${Directory.systemTemp.path}/displai-work',
      );
      await _claude.start();
      final format = await audio.start(playRate: _speaker.sampleRate);
      debugPrint('audio: $format');
      _earcon = _makeEarcon(_speaker.sampleRate);

      _subs
        ..add(audio.mic.listen(_onMic))
        ..add(audio.output.listen((o) => presence.addAudio(o.$1, o.$2)))
        ..add(audio.idle.listen((_) => _updatePresence()))
        ..add(_listener.events.listen(_onHeard))
        ..add(_speaker.speech.listen(_onSpeech))
        ..add(_claude.events.listen(_onBrain))
        ..add(display.userEvents.listen(_onDisplayEvent));
      ready = true;
      _updatePresence();
    } catch (e, st) {
      error = '$e';
      debugPrint('assistant start failed: $e\n$st');
    }
    notifyListeners();
  }

  set muted(bool value) {
    if (value == _muted) return;
    _muted = value;
    if (value) _listener.reset();
    _updatePresence();
    notifyListeners();
  }

  void toggleMute() => muted = !_muted;

  // ---------------------------------------------------------------- input

  void _onMic(Float32List samples) {
    if (_muted) return;
    _listener.add(samples);
    if (!audio.isPlaying) presence.addAudio(samples, 16000);
  }

  void _onHeard(HeardEvent e) {
    switch (e) {
      case SpeechStarted():
        if (confirmation != null) return; // the user is answering, not interrupting
        if (busy && !_barged) _bargeIn();
      case Utterance():
        final wasBargeIn = _barged;
        _barged = false;
        if (_muted) return;
        if (confirmation != null) {
          _answerByVoice(e.text);
          return;
        }
        if (busy && !wasBargeIn) {
          debugPrint('ignored ${e.seconds.toStringAsFixed(1)}s of audio while speaking (no barge-in)');
          return;
        }
        var text = e.text;
        if (text.isEmpty) return;
        if (_carry.isNotEmpty) {
          text = '$_carry $text';
          _carry = '';
        }
        _lastText = text;
        lastHeard = text;
        debugPrint('heard: "$text" (${e.seconds.toStringAsFixed(1)}s, '
            'stt done ${e.sttDone.difference(e.speechEnd).inMilliseconds}ms after speech end)');
        _earconTick();
        _turnSpeechEnd = e.speechEnd;
        _ask(text);
    }
  }

  void _onDisplayEvent(String event) {
    if (confirmation != null) answerConfirmation(false);
    if (busy) {
      _stopTurn();
      _carry = '';
    }
    _turnSpeechEnd = null;
    _ask(event);
  }

  /// The user talked over the assistant: stop the voice and the brain at once.
  void _bargeIn() {
    _barged = true;
    final fa = _firstAudioAt;
    final continuation = fa == null || DateTime.now().difference(fa) < continuationWindow;
    _carry = continuation ? _lastText : '';
    debugPrint('barge-in${continuation ? ' (continuation: merging with previous utterance)' : ''}');
    _stopTurn();
  }

  void _stopTurn() {
    if (confirmation != null) answerConfirmation(false);
    _generation++;
    _pendingTts = 0;
    _sentence.clear();
    unawaited(audio.stop());
    _claude.interrupt();
    display.cancelPartial();
    _setActivity('');
    _updatePresence();
  }

  void _ask(String text) {
    _generation++;
    _pendingTts = 0;
    _sentence.clear();
    _firstAudioAt = null;
    _setActivity('Pensando…');
    unawaited(_claude.send(text));
    _updatePresence();
    notifyListeners();
  }

  // ---------------------------------------------------------------- brain

  static final _sentenceEnd = RegExp(r'[.!?…:;](\s|$)');

  void _onBrain(BrainEvent e) {
    switch (e) {
      case TextDelta():
        if (activity.isNotEmpty) _setActivity('');
        _sentence.write(e.text);
        _flushSentences(final_: false);
      case ToolStart():
        _flushSentences(final_: true);
        _setActivity(switch (e.name) {
          'WebSearch' || 'web_search' => 'Buscando en la web…',
          'WebFetch' || 'web_fetch' => 'Leyendo una página…',
          'get_state' => 'Mirando la pantalla…',
          _ => 'Preparando la pantalla…',
        });
      case ToolInput():
        presence.bumpActivity(0.1);
        if (_isDisplayTool(e.name)) display.streamPartial(e.name, e.partialJson);
      case TurnDone():
        if (e.interrupted) {
          display.cancelPartial();
        } else {
          _flushSentences(final_: true);
        }
        _setActivity('');
        if (confirmation != null) answerConfirmation(false);
        final queued = _queued;
        _queued = null;
        if (queued != null && !e.interrupted) {
          _turnSpeechEnd = null;
          _ask(queued);
          return;
        }
        if (e.error != null) {
          debugPrint('turn error: ${e.error}');
          _say('Ha habido un error con el cerebro. Vuelve a intentarlo.');
        }
        _updatePresence();
    }
  }

  bool _isDisplayTool(String name) => DisplayController.toolSpecs.any((t) => t.name == name);

  void _flushSentences({required bool final_}) {
    var text = _sentence.toString();
    while (true) {
      final m = _sentenceEnd.firstMatch(text);
      if (m == null) break;
      _say(text.substring(0, m.end));
      text = text.substring(m.end);
    }
    _sentence.clear();
    if (final_) {
      _say(text);
    } else {
      _sentence.write(text);
    }
  }

  void _say(String text) {
    if (Speaker.cleanForSpeech(text).isEmpty) return;
    _pendingTts++;
    _speaker.say(_generation, text);
    _updatePresence();
  }

  // ---------------------------------------------------------------- tools

  Future<ToolResult> _handleTool(String name, Map<String, dynamic> args) async {
    for (final p in providers) {
      if (p.handles(name)) {
        _setActivity(_activityFor(name));
        return p.call(name, args, _requestConfirmation);
      }
    }
    if (name == _snapshotTool.name) return _snapshot();
    final text = display.callTool(name, args);
    if (text.startsWith('error:')) return ToolResult.error(text);
    if (const {'show', 'update', 'form', 'back'}.contains(name)) {
      // Let the view lay out (and report what does not fit) before answering.
      // Bounded: a hidden or minimised window produces no frames.
      await _frame();
      await _frame();
      final cut = display.overflow;
      if (cut > 0) {
        return ToolResult('$text\nwarning: the view does not fit the screen; about ${cut.round()} px '
            'at the bottom are cut off (the display never scrolls). Update it to show less or split '
            'it into several views.');
      }
    }
    return ToolResult(text);
  }

  /// Waits for the next frame. Forced, because Flutter stops drawing while the window is hidden
  /// behind others (lifecycle hidden), and the display must still lay out and be captured.
  static Future<void> _frame() {
    WidgetsBinding.instance.scheduleForcedFrame();
    return WidgetsBinding.instance.endOfFrame.timeout(const Duration(milliseconds: 400), onTimeout: () {});
  }

  Future<ToolResult> _snapshot() async {
    await _frame();
    final boundary = screenKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return const ToolResult.error('error: display not ready');
    final size = boundary.size;
    final ratio = math.min(2.0, 1280 / math.max(size.width, size.height));
    final image = await boundary.toImage(pixelRatio: ratio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) return const ToolResult.error('error: could not encode the capture');
    return ToolResult('DisplAI display, ${size.width.round()}×${size.height.round()} logical px',
        png: data.buffer.asUint8List());
  }

  static String _activityFor(String tool) => switch (tool) {
        'run_command' => 'Ejecutando un comando…',
        'read_file' || 'list_dir' => 'Leyendo ficheros…',
        'write_file' => 'Escribiendo un fichero…',
        'screen' => 'Mirando la pantalla…',
        'ui_tree' || 'apps' || 'windows' => 'Leyendo la interfaz…',
        _ => 'Usando el ordenador…',
      };

  /// Shows [summary] on a card and asks "¿Lo hago?" by voice; resolves on yes/no or timeout.
  Future<bool> _requestConfirmation(String summary) {
    if (confirmation != null) answerConfirmation(false);
    confirmation = summary;
    final c = _confirm = Completer<bool>();
    _confirmTimeout = Timer(confirmTimeout, () => answerConfirmation(false));
    _flushSentences(final_: true);
    _say('¿Lo hago?');
    _setActivity('Esperando tu confirmación…');
    notifyListeners();
    return c.future;
  }

  /// The user's answer to the pending confirmation (card buttons, voice, or a timeout).
  void answerConfirmation(bool yes) {
    final c = _confirm;
    if (c == null) return;
    debugPrint('confirmation ${yes ? 'approved' : 'declined'}: $confirmation');
    _confirm = null;
    confirmation = null;
    _confirmTimeout?.cancel();
    _setActivity(yes ? 'Hecho, sigo…' : '');
    if (yes) _earconTick();
    c.complete(yes);
    notifyListeners();
  }

  void _answerByVoice(String text) {
    if (text.isEmpty) return;
    lastHeard = text;
    final answer = parseYesNo(text);
    answerConfirmation(answer == true);
    // Anything that is not a plain yes/no is a new request: run it after this turn.
    if (answer == null) _queued = text;
  }

  static final _yes = RegExp(
      r'^(si|sí|vale|ok|okay|adelante|hazlo|hazla|confirmo|confirmado|dale|claro|correcto|afirmativo|yes|venga|por supuesto|de acuerdo|perfecto|exacto)(?=\s|$)');
  static final _no = RegExp(r'^(no|cancela|cancelar|para|espera|nada|negativo|mejor no|ni hablar)(?=\s|$)');

  /// true = yes, false = no, null = something else.
  static bool? parseYesNo(String text) {
    final t = text.toLowerCase().replaceAll(RegExp(r'[¡!¿?.,;:]'), ' ').trim();
    if (_yes.hasMatch(t)) {
      // "sí, pero ..." is a yes; "sí no" is ambiguous: treat as no.
      return !RegExp(r'\bno\b').hasMatch(t);
    }
    if (_no.hasMatch(t)) return false;
    return null;
  }

  // ---------------------------------------------------------------- output

  void _onSpeech(Speech s) {
    if (s.generation != _generation) return; // interrupted turn
    _pendingTts = math.max(0, _pendingTts - 1);
    if (_firstAudioAt == null) {
      _firstAudioAt = DateTime.now();
      final end = _turnSpeechEnd;
      if (end != null) debugPrint('first voice ${_firstAudioAt!.difference(end).inMilliseconds}ms after speech end');
    }
    unawaited(audio.play(s.samples));
    _updatePresence();
  }

  void _earconTick() {
    final e = _earcon;
    if (e != null && !audio.isPlaying) unawaited(audio.play(e));
  }

  /// A soft 40 ms tick that says "heard you".
  static Float32List _makeEarcon(int rate) {
    final n = (rate * 0.04).round();
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      final t = i / rate;
      final env = math.sin(math.pi * i / n);
      out[i] = 0.08 * env * env * math.sin(2 * math.pi * 1320 * t);
    }
    return out;
  }

  // ---------------------------------------------------------------- state

  void _setActivity(String text) {
    if (activity == text) return;
    activity = text;
    notifyListeners();
  }

  void _updatePresence() {
    if (!ready) return;
    final mode = audio.isPlaying || _pendingTts > 0 && _firstAudioAt != null
        ? PresenceMode.speaking
        : _claude.busy || _pendingTts > 0
            ? PresenceMode.thinking
            : _muted
                ? PresenceMode.idle
                : PresenceMode.listening;
    if (presence.mode != mode) presence.mode = mode;
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    if (ready) {
      _claude.dispose();
      _listener.dispose();
      _speaker.dispose();
      unawaited(_mcp.stop());
    }
    presence.dispose();
    display.dispose();
    super.dispose();
  }
}
