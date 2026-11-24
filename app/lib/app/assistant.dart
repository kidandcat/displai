import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show GlobalKey;
import 'package:path_provider/path_provider.dart';

import '../audio/native_audio.dart';
import 'desktop_window.dart';
import '../brain/claude_session.dart';
import '../brain/system_prompt.dart';
import '../display/display.dart';
import '../display/display_runner.dart';
import '../mcp/display_mcp_server.dart';
import '../presence/presence.dart';
import '../remote/phone_host.dart';
import '../remote/protocol.dart';
import '../computer/computer_tools.dart';
import '../routines/routines.dart';
import '../store/store.dart';
import '../tools/command_tools.dart';
import '../tools/history_tools.dart';
import '../tools/memory_tools.dart';
import '../tools/skill_tools.dart';
import '../tools/tool_provider.dart';
import '../workers/workers.dart';
import '../voice/listener.dart';
import '../voice/model_store.dart';
import '../voice/speaker.dart';
import 'assistant_ui.dart';

/// Wires voice, brain and display together (docs/design.md §2 and §5).
///
/// Mic (echo-cancelled) → [Listener] → [ClaudeSession] → sentences → [Speaker] → [NativeAudio].
/// Display tool calls arrive through the embedded MCP server; partial tool input streams into
/// the [DisplayController] while Claude is still writing it.
class Assistant extends ChangeNotifier implements AssistantUi {
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

  /// The desktop window: the Mac listens only while it is open, and it becomes a corner orb
  /// while a phone is connected.
  final window = DesktopWindow();
  @override
  final display = DisplayController();
  @override
  final presence = PresenceSignal();

  /// The paired phone remote, once a pairing key exists (see [pairingLink]).
  PhoneHost? phone;

  /// What built the display, so it can move to the phone and back.
  final _displayLog = DisplayLog();

  /// A phone is connected: it is the mic, the speaker and the display ("Mac callado").
  bool get onPhone => phone?.active ?? false;

  late final Listener _listener;
  late final Speaker _speaker;
  late final ClaudeSession _claude;
  late final DisplayMcpServer _mcp;
  final _subs = <StreamSubscription<Object?>>[];

  /// Minerva's own data: history, memories, workers, routines (and skills on disk).
  late final Store store;

  /// Minerva's own tools besides the display (served from our MCP server, not the brain's
  /// built-ins): commands, computer use, memories, history, skills, workers and routines.
  late final List<ToolProvider> providers;
  late final Workers workers;
  late final Routines routines;

  String get _skillsDir => '${store.dir}/skills';

  /// Worker reports and routine prompts waiting for the brain to be free.
  final _notices = <String>[];
  Timer? _noticeTimer;
  bool _userSpeaking = false;

  /// What the brain has said in the current turn (saved to the history when it ends).
  final _reply = StringBuffer();

  /// Wraps what Minerva shows (display and presence) so the brain can capture it.
  @override
  final GlobalKey screenKey = GlobalKey(debugLabel: 'minerva-screen');

  static const _snapshotTool = McpTool(
    'snapshot',
    'Capture how Minerva\'s own display looks right now, as an image. Use it to check a view '
        'you just showed (layout, fit, readability). For the rest of the Mac use screen.',
    {'type': 'object', 'properties': {}},
  );

  static const _windowTool = McpTool(
    'minerva_window',
    'Minerva\'s own window on the Mac. It shrinks to the corner orb on its own when you act on '
        'other apps, and comes back when you show something. orb: shrink it now; full: bring it '
        'back without showing anything.',
    {
      'type': 'object',
      'properties': {
        'mode': {
          'type': 'string',
          'enum': ['orb', 'full'],
        },
      },
      'required': ['mode'],
    },
  );

  /// Display tools that put something in front of the user: the window comes back for them.
  static const _showingTools = {'show', 'html', 'form', 'video', 'back'};

  /// The window is the corner orb because Minerva works in other apps of the Mac.
  bool _usingMac = false;

  @override
  bool ready = false;
  @override
  String? error;

  bool _muted = false;
  @override
  bool get muted => _muted;

  /// Last thing the user said (shown in the status bar).
  @override
  String lastHeard = '';

  /// What the brain is doing right now, e.g. "Buscando en la web…" (empty when nothing).
  @override
  String activity = '';

  @override
  int get backgroundJobs => ready ? workers.runningCount : 0;

  @override
  String get linkNote => onPhone ? 'Móvil conectado · el Mac está en silencio' : '';

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

  /// The voice is playing, on the phone while it is connected, else on the Mac.
  bool get _playing => onPhone ? phone!.playing : audio.isPlaying;

  bool get speaking => _pendingTts > 0 || _playing;
  bool get busy => _claude.busy || speaking;

  Future<void> start() async {
    try {
      final dataDir = Platform.environment['MINERVA_DATA_DIR'] ??
          (await getApplicationSupportDirectory()).path;
      store = await Store.open(dataDir);
      workers = Workers(
        store: store,
        hostTools: [CommandTools(), MemoryTools(store, readOnly: true), HistoryTools(store), SkillTools(_skillsDir, readOnly: true)],
        notify: notify,
      )..addListener(notifyListeners);
      routines = Routines(store: store, notify: notify);
      providers = [
        CommandTools(),
        ComputerTools(),
        MemoryTools(store),
        HistoryTools(store),
        SkillTools(_skillsDir),
        workers,
        routines,
      ];
      var sessionId = store.get('brain_session');
      if (sessionId == null) {
        sessionId = ClaudeSession.newSessionId();
        store.set('brain_session', sessionId);
      }
      _speaker = await Speaker.start(modelDir: models.supertonic, voice: voice);
      _listener = await Listener.start(vadModel: models.vad, parakeetDir: models.parakeet);
      _mcp = DisplayMcpServer(
        tools: [
          for (final t in DisplayController.toolSpecs) McpTool(t.name, t.description, t.inputSchema),
          _snapshotTool,
          _windowTool,
          for (final p in providers) ...p.tools,
        ],
        handler: _handleTool,
        onCall: (name) => _setActivity(''),
      );
      await _mcp.start();
      _claude = ClaudeSession(
        model: model,
        effort: effort,
        systemPrompt: buildSystemPrompt([MemoryTools.promptSection(store), SkillTools.promptSection(_skillsDir)]),
        mcpUrl: _mcp.url,
        workDir: '${store.dir}/brain',
        sessionId: sessionId,
      );
      await _claude.start();
      window.onTap = toggleMute;
      window.onOpenRequested = () => unawaited(_useMac(false));
      await window.init();
      window.addListener(_syncAudio);
      _syncAudio();
      _earcon = _makeEarcon(_speaker.sampleRate);
      presence.addListener(_pushState);
      if (store.get('remote_key') != null) _startPhone();

      _subs
        ..add(audio.mic.listen(_onMic))
        ..add(audio.output.listen((o) => presence.addAudio(o.$1, o.$2)))
        ..add(audio.idle.listen((_) => _onAudioIdle()))
        ..add(_listener.events.listen(_onHeard))
        ..add(_speaker.speech.listen(_onSpeech))
        ..add(_claude.events.listen(_onBrain))
        ..add(display.userEvents.listen(_onDisplayEvent));
      ready = true;
      _updatePresence();
      routines.start();
      _noticeTimer = Timer.periodic(const Duration(seconds: 2), (_) => _drainNotices());
    } catch (e, st) {
      error = '$e';
      debugPrint('assistant start failed: $e\n$st');
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------- phone remote

  String get _relay =>
      Platform.environment['MINERVA_RELAY'] ?? store.get('remote_relay') ?? RemoteProtocol.defaultRelay;

  /// The link the phone scans to pair (creates the pairing key the first time).
  String pairingLink() {
    var key = store.get('remote_key');
    if (key == null) {
      key = RemoteProtocol.newKey();
      store.set('remote_key', key);
    }
    if (phone == null) _startPhone();
    return RemoteProtocol.pairingLink(_relay, key);
  }

  /// Forgets the old pairing (the phone that has it can no longer connect) and makes a new one.
  Future<String> newPairing() async {
    final old = phone;
    if (old != null) {
      if (old.active) {
        old.active = false;
        _phoneLeft();
      }
      phone = null;
      await old.close();
    }
    store.set('remote_key', RemoteProtocol.newKey());
    return pairingLink();
  }

  void _startPhone() {
    final p = phone = PhoneHost(relay: _relay, key: store.get('remote_key')!, playRate: _speaker.sampleRate, log: _displayLog)
      ..onMic = _onPhoneMic
      ..onEvent = _onDisplayEvent
      ..onMute = ((on) => muted = on)
      ..onIdle = _onAudioIdle
      ..onJoin = _phoneJoined
      ..onLeave = _phoneLeft;
    p.addListener(notifyListeners);
  }

  void _phoneJoined() {
    // The Mac goes quiet: its voice stops, its mic is released, the phone takes over, and the
    // window shrinks to the corner orb.
    unawaited(audio.stop());
    _usingMac = false;
    unawaited(window.setOverlay(true));
    _syncAudio();
    _listener.reset();
    _pushState();
    _updatePresence();
    notifyListeners();
  }

  void _phoneLeft() {
    unawaited(window.setOverlay(false));
    _syncAudio();
    _listener.reset();
    // Bring the display back to the Mac as the phone had it.
    display.reset();
    _displayLog.replay((name, args) => display.callTool(name, args));
    _updatePresence();
    _drainNotices();
    notifyListeners();
  }

  Future<void> _audioSync = Future.value();

  /// The Mac's own mic and speaker run only while its window is open and no phone is connected
  /// (and never with MINERVA_NO_MIC set, for test instances next to people).
  void _syncAudio() {
    _audioSync = _audioSync.then((_) async {
      final want = window.open && !onPhone && Platform.environment['MINERVA_NO_MIC'] == null;
      if (want == audio.running) return;
      try {
        if (want) {
          debugPrint('audio: ${await audio.start(playRate: _speaker.sampleRate)}');
        } else {
          await audio.shutdown();
          debugPrint('audio: off (window closed or phone connected)');
        }
      } catch (e) {
        debugPrint('audio ${want ? 'start' : 'shutdown'} failed: $e');
      }
      if (!onPhone) _listener.reset();
      _updatePresence();
    });
  }

  void _onPhoneMic(Float32List samples) {
    if (_muted) return;
    _listener.add(samples);
  }

  void _onAudioIdle() {
    _updatePresence();
    _drainNotices();
  }

  void _pushState() {
    final p = phone;
    if (p == null || !p.active) return;
    p.pushState({
      'mode': presence.mode.name,
      'activity': activity,
      'heard': lastHeard,
      'jobs': backgroundJobs,
      'muted': _muted,
    });
  }

  @override
  void notifyListeners() {
    _pushState();
    super.notifyListeners();
  }

  set muted(bool value) {
    if (value == _muted) return;
    _muted = value;
    presence.muted = value;
    if (value) _listener.reset();
    _updatePresence();
    notifyListeners();
  }

  @override
  void toggleMute() => muted = !_muted;

  // ---------------------------------------------------------------- input

  void _onMic(Float32List samples) {
    if (_muted || onPhone) return;
    _listener.add(samples);
    if (!audio.isPlaying) presence.addAudio(samples, 16000);
  }

  void _onHeard(HeardEvent e) {
    switch (e) {
      case SpeechStarted():
        _userSpeaking = true;
        if (busy && !_barged) _bargeIn();
      case Utterance():
        _userSpeaking = false;
        final wasBargeIn = _barged;
        _barged = false;
        if (_muted) return;
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
    _logReply(interrupted: true);
    _generation++;
    _pendingTts = 0;
    _sentence.clear();
    _stopAudio();
    _claude.interrupt();
    display.cancelPartial();
    phone?.cancelPartial();
    _setActivity('');
    _updatePresence();
  }

  void _ask(String text) {
    final event = text.startsWith('[display]') || text.startsWith('[worker') || text.startsWith('[routine');
    store.addMessage(event ? 'event' : 'user', text);
    _generation++;
    _pendingTts = 0;
    _sentence.clear();
    _firstAudioAt = null;
    _setActivity('Pensando…');
    final p = phone;
    final where = p != null && p.active ? ' [phone ${p.width.round()}x${p.height.round()}]' : '';
    unawaited(_claude.send('[${formatStamp(DateTime.now())}]$where $text'));
    _updatePresence();
    notifyListeners();
  }

  // ---------------------------------------------------------------- brain

  static final _sentenceEnd = RegExp(r'[.!?…:;](\s|$)');

  void _onBrain(BrainEvent e) {
    switch (e) {
      case TextDelta():
        _reply.write(e.text);
        if (activity.isNotEmpty) _setActivity('');
        _sentence.write(e.text);
        _flushSentences(final_: false);
      case ToolStart():
        if (_reply.isNotEmpty) _reply.write(' ');
        _flushSentences(final_: true);
        _setActivity(switch (e.name) {
          'WebSearch' || 'web_search' => 'Buscando en la web…',
          'WebFetch' || 'web_fetch' => 'Leyendo una página…',
          'get_state' => 'Mirando la pantalla…',
          _ => 'Preparando la pantalla…',
        });
      case ToolInput():
        presence.bumpActivity(0.1);
        if (_isDisplayTool(e.name)) {
          if (onPhone) {
            phone!.partial(e.name, e.partialJson);
          } else {
            display.streamPartial(e.name, e.partialJson);
          }
        }
      case Compacting():
        // Takes a few seconds once the context is full; say why the answer is late.
        _setActivity(e.active ? 'Resumiendo la conversación…' : 'Pensando…');
      case TurnDone():
        _logReply(interrupted: e.interrupted);
        if (e.interrupted) {
          display.cancelPartial();
          phone?.cancelPartial();
        } else {
          _flushSentences(final_: true);
        }
        _setActivity('');
        if (e.error != null) {
          debugPrint('turn error: ${e.error}');
          _say('Ha habido un error con el cerebro. Vuelve a intentarlo.');
        }
        _updatePresence();
        _drainNotices();
    }
  }

  void _logReply({required bool interrupted}) {
    final text = _reply.toString().trim();
    _reply.clear();
    if (text.isNotEmpty) store.addMessage('assistant', interrupted ? '$text [interrupted]' : text);
  }

  /// Hands a worker report or a routine prompt to the brain as soon as it is free (not
  /// talking, not thinking, the user not speaking).
  void notify(String text) {
    _notices.add(text);
    _drainNotices();
  }

  void _drainNotices() {
    if (!ready || _notices.isEmpty || busy || _userSpeaking) return;
    _turnSpeechEnd = null;
    _ask(_notices.removeAt(0));
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
        if (ComputerTools.needsScreen(name, args)) await _useMac(true);
        return p.call(name, args);
      }
    }
    if (name == _windowTool.name) {
      final orb = args['mode'] == 'orb';
      if (onPhone) return const ToolResult('ok: the phone is connected, the Mac window stays the orb.');
      if (!window.open) return const ToolResult('ok: the window is closed (the user is not at the Mac).');
      await _useMac(orb);
      return ToolResult(orb ? 'ok: the window is the corner orb.' : 'ok: the window is back.');
    }
    if (_showingTools.contains(name)) await _useMac(false);
    if (onPhone) {
      final r = await _onPhoneTool(name, args);
      if (r != null) return r;
      // The phone left or did not answer: the call runs here (it is replayed if it comes back).
    }
    if (name == _snapshotTool.name) return _snapshot();
    final text = await DisplayRunner.run(display, name, args);
    if (text.startsWith('error:')) return ToolResult.error(text);
    _displayLog.record(name, args);
    return ToolResult(text);
  }

  /// Shrinks the window to the corner orb while Minerva works in other apps of the Mac (the
  /// Mac keeps listening and speaking), or brings it back. Nothing changes while a phone is
  /// connected (the window is already the orb) or while the window is closed.
  Future<void> _useMac(bool on) async {
    if (on == _usingMac) return;
    if (on && (onPhone || !window.open)) return;
    _usingMac = on;
    debugPrint('window: ${on ? 'orb while using the Mac' : 'back from using the Mac'}');
    if (onPhone) return;
    await window.setOverlay(on, reason: 'computer');
    // Let the window settle (and the app behind it take the keyboard) before acting.
    await Future<void>.delayed(const Duration(milliseconds: 350));
  }

  /// Runs a display tool (or snapshot) on the phone; null when it did not answer.
  Future<ToolResult?> _onPhoneTool(String name, Map<String, dynamic> args) async {
    final m = await phone!.call(name, args);
    if (m == null) return null;
    final text = '${m['text'] ?? ''}';
    if (m['error'] == true) return ToolResult.error(text);
    final png = m['png'];
    if (name != _snapshotTool.name) _displayLog.record(name, args);
    return ToolResult(text, png: png is String ? base64Decode(png) : null);
  }

  Future<ToolResult> _snapshot() async {
    final shot = await DisplayRunner.capture(screenKey);
    if (shot == null) return const ToolResult.error('error: display not ready');
    final (png, size) = shot;
    return ToolResult('Minerva display, ${size.width.round()}×${size.height.round()} logical px', png: png);
  }

  static String _activityFor(String tool) => switch (tool) {
        'remember' || 'search_memories' || 'forget_memory' => 'Recordando…',
        'search_history' => 'Buscando en el historial…',
        'read_skill' || 'save_skill' || 'delete_skill' => 'Repasando cómo se hace…',
        'start_worker' || 'message_worker' => 'Lanzando trabajo en segundo plano…',
        'list_workers' || 'worker_status' || 'stop_worker' => 'Mirando los trabajos en curso…',
        'create_routine' || 'list_routines' || 'update_routine' || 'delete_routine' => 'Programando…',
        'run_command' => 'Ejecutando un comando…',
        'read_file' || 'list_dir' => 'Leyendo ficheros…',
        'write_file' => 'Escribiendo un fichero…',
        'screen' => 'Mirando la pantalla…',
        'ui_tree' || 'apps' || 'windows' => 'Leyendo la interfaz…',
        _ => 'Usando el ordenador…',
      };

  // ---------------------------------------------------------------- output

  void _onSpeech(Speech s) {
    if (s.generation != _generation) return; // interrupted turn
    _pendingTts = math.max(0, _pendingTts - 1);
    if (_firstAudioAt == null) {
      _firstAudioAt = DateTime.now();
      final end = _turnSpeechEnd;
      if (end != null) debugPrint('first voice ${_firstAudioAt!.difference(end).inMilliseconds}ms after speech end');
    }
    _play(s.samples);
    _updatePresence();
  }

  void _play(Float32List samples) {
    if (onPhone) {
      phone!.sendVoice(samples);
    } else {
      unawaited(audio.play(samples));
    }
  }

  void _stopAudio() {
    phone?.stopVoice();
    unawaited(audio.stop());
  }

  void _earconTick() {
    final e = _earcon;
    if (e != null && !_playing) _play(e);
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
    final mode = _playing || _pendingTts > 0 && _firstAudioAt != null
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
    _noticeTimer?.cancel();
    window.removeListener(_syncAudio);
    window.dispose();
    presence.removeListener(_pushState);
    unawaited(phone?.close());
    if (ready) {
      routines.dispose();
      workers.dispose();
      _claude.dispose();
      _listener.dispose();
      _speaker.dispose();
      unawaited(_mcp.stop());
      store.close();
    }
    presence.dispose();
    display.dispose();
    super.dispose();
  }
}
