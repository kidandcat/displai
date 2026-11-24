import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show GlobalKey;
import 'package:path_provider/path_provider.dart';

import '../audio/native_audio.dart';
import 'desktop_window.dart';
import '../brain/claude_models.dart';
import '../brain/claude_session.dart';
import '../brain/system_prompt.dart';
import '../display/display.dart';
import '../display/display_runner.dart';
import '../l10n/l10n.dart';
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
import '../vault/vault.dart';
import '../vault/vault_tools.dart';
import '../workers/workers.dart';
import '../voice/listener.dart';
import '../voice/model_store.dart';
import '../voice/speaker.dart';
import '../webhooks/webhook_tools.dart';
import '../webhooks/webhooks.dart';
import 'assistant_ui.dart';
import 'settings.dart';

/// Wires voice, brain and display together (docs/design.md §2 and §5).
///
/// Mic (echo-cancelled) → [Listener] → [ClaudeSession] → sentences → [Speaker] → [NativeAudio].
/// Display tool calls arrive through the embedded MCP server; partial tool input streams into
/// the [DisplayController] while Claude is still writing it.
class Assistant extends ChangeNotifier implements AssistantUi, AssistantSettings {
  Assistant({required this.models, this.voice = defaultVoice, DesktopWindow? window})
      : window = window ?? DesktopWindow();

  final ModelStore models;

  /// The conversation's model (the main brain) and the workers', saved in the store.
  @override
  ModelChoice brainModel = defaultBrainModel;
  @override
  ModelChoice workerModel = defaultWorkerModel;

  /// The models of the installed Claude Code (null until it first reported them).
  @override
  ClaudeCatalog? catalog;

  /// Why Claude Code says fast mode can't be used on this account (a reason code such as
  /// `extra_usage_disabled`), else null.
  @override
  String? fastUnavailable;

  /// Supertonic 3 speaker id: 0–4 are female voices (F1–F5), 5–9 male (M1–M5); the one in the
  /// store once started.
  @override
  int voice;

  /// The user can resume talking this long after the answer became audible and it still
  /// counts as the same turn (design §5, continuation merge).
  static const continuationWindow = Duration(seconds: 2);

  final audio = NativeAudio();

  /// The desktop window: the Mac listens only while it is open, and it becomes a corner orb
  /// while a phone is connected or Minerva works in other apps.
  final DesktopWindow window;
  @override
  final display = DisplayController();
  @override
  final presence = PresenceSignal();

  /// The paired phone remote, once a pairing key exists (see [pairingLink]).
  PhoneHost? phone;

  /// Webhooks from third parties at this Mac's own address, through the relay.
  Webhooks? webhooks;

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

  /// Credentials the brain uses by placeholder without seeing them (design §3.9).
  late final Vault vault;

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
        'other apps; meanwhile show and html pop up as a widget over them (at: where) and the '
        'window stays the orb, while form, video and back bring it back. orb: shrink it now; '
        'full: bring it back without showing anything.',
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

  static final _languageTool = McpTool(
    'set_language',
    'Minerva\'s language: the screen texts and the voice that reads your replies. system follows '
        'the Mac\'s language. Only when the user asks to change it for good.',
    {
      'type': 'object',
      'properties': {
        'language': {
          'type': 'string',
          'enum': ['system', ...languageChoices],
        },
      },
      'required': ['language'],
    },
  );

  /// Display tools that put something in front of the user: the window comes back for them,
  /// but for [_widgetTools] while Minerva works in other apps.
  static const _showingTools = {'show', 'html', 'form', 'video', 'back'};

  /// Views that pop up as a widget over the other apps while the window is the orb.
  static const _widgetTools = {'show', 'html'};

  /// The window is the corner orb because Minerva works in other apps of the Mac.
  bool _usingMac = false;

  /// Views from this one on (by [DisplayViewEntry.seq]) pop up as a widget: the ones shown
  /// since the window became the orb.
  int _widgetFrom = 1 << 62;

  /// The widget the user closed.
  int? _widgetClosed;

  /// Where the widget goes on the screen (the show and html tools' `at`).
  String widgetAt = 'top-right';

  static final _atPattern = RegExp(r'"at"\s*:\s*"([a-z-]+)"');

  /// The view to show as a widget over the other apps, or null.
  DisplayViewEntry? get widgetView {
    final e = display.current;
    if (!_usingMac || e == null || e.seq < _widgetFrom || e.seq == _widgetClosed) return null;
    return e.kind == 'view' || e.kind == 'html' ? e : null;
  }

  /// The user closed the widget.
  void closeWidget() {
    _widgetClosed = display.current?.seq;
    notifyListeners();
  }

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

  /// What the brain is doing right now, e.g. "Searching the web…" (empty when nothing), in the
  /// UI language.
  @override
  String activity = '';

  @override
  int get backgroundJobs => ready ? workers.runningCount : 0;

  @override
  String get linkNote => onPhone ? strings.linkNoteOnPhone : '';

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

  /// Status lines ([activity]) are spoken too, so nobody has to read them: after
  /// [statusDelay] (a status replaced sooner is skipped), only while the voice is silent, and
  /// not the same one twice in a row. Their audio comes back under [_statusGeneration].
  static const statusDelay = Duration(seconds: 1);
  Timer? _statusTimer;
  String _spokenStatus = '';

  /// The voice is playing, on the phone while it is connected, else on the Mac.
  bool get _playing => onPhone ? phone!.playing : audio.isPlaying;

  bool get speaking => _pendingTts > 0 || _playing;
  bool get busy => _claude.busy || speaking;

  Future<void> start() async {
    try {
      final dataDir = Platform.environment['MINERVA_DATA_DIR'] ??
          (await getApplicationSupportDirectory()).path;
      store = await Store.open(dataDir);
      languageSetting.value = validLanguage(store.get('language'));
      catalog = ClaudeCatalog.load(store);
      brainModel = ModelChoice.load(store, 'brain', defaultBrainModel);
      workerModel = ModelChoice.load(store, 'workers', defaultWorkerModel);
      voice = validVoice(int.tryParse(store.get('voice') ?? '')) ?? voice;
      vault = await Vault.open('${store.dir}/vault');
      vault.addListener(_pushSettings);
      workers = Workers(
        store: store,
        hostTools: [
          CommandTools(vault: vault),
          MemoryTools(store, readOnly: true),
          HistoryTools(store),
          SkillTools(_skillsDir, readOnly: true),
          VaultTools(vault, readOnly: true),
        ],
        scrub: vault.scrubResult,
        notify: notify,
      )
        ..addListener(notifyListeners)
        ..addListener(() => presence.workers = workers.runningIds);
      _applyWorkerModel();
      routines = Routines(store: store, notify: notify);
      if (Platform.environment['MINERVA_NO_WEBHOOKS'] == null) {
        webhooks = Webhooks(relay: _relay, dir: '${store.dir}/webhooks', onWebhook: (ev) => notify(Webhooks.describe(ev)))
          ..addListener(notifyListeners);
      }
      providers = [
        CommandTools(vault: vault),
        ComputerTools(vault: vault),
        VaultTools(vault),
        MemoryTools(store),
        HistoryTools(store),
        SkillTools(_skillsDir),
        workers,
        routines,
        if (webhooks != null) WebhookTools(webhooks!),
      ];
      var sessionId = store.get('brain_session');
      if (sessionId == null) {
        sessionId = ClaudeSession.newSessionId();
        store.set('brain_session', sessionId);
      }
      _speaker = await Speaker.start(modelDir: models.supertonic, voice: voice, language: speechLanguage);
      _listener = await Listener.start(vadModel: models.vad, parakeetDir: models.parakeet);
      _mcp = DisplayMcpServer(
        tools: [
          for (final t in DisplayController.toolSpecs) McpTool(t.name, t.description, t.inputSchema),
          _snapshotTool,
          _windowTool,
          _languageTool,
          VaultTools.requestTool,
          for (final p in providers) ...p.tools,
        ],
        // Nothing the brain gets back carries a stored secret.
        handler: (name, args) async => vault.scrubResult(await _handleTool(name, args)),
        onCall: (name) => _setActivity(''),
      );
      await _mcp.start();
      await webhooks?.start();
      final brain = brainModel.resolve(catalog);
      _claude = ClaudeSession(
        model: brain.model,
        effort: brain.effort,
        fast: brain.fast,
        describe: true,
        systemPrompt: buildSystemPrompt([
          languagePromptSection(speechLanguage, strings),
          MemoryTools.promptSection(store),
          SkillTools.promptSection(_skillsDir),
          webhooks?.promptSection() ?? '',
        ]),
        mcpUrl: _mcp.url,
        workDir: '${store.dir}/brain',
        sessionId: sessionId,
      );
      await _claude.start();
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
        ..add(display.userEvents.listen(_onDisplayEvent))
        ..add(display.vaultSubmissions.listen(_onVaultSubmission));
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

  // ---------------------------------------------------------------- language

  /// Changes Minerva's language ([code] one of [languageChoices], or null to follow the OS): the
  /// UI, the voice and the native menus at once, and the brain (told now, and in its prompt from
  /// the next start). Returns the brain's new language section. [tell]: notify the brain (not
  /// needed when it asked for the change itself).
  @override
  Future<String> setLanguage(String? code, {bool tell = true}) async {
    code = validLanguage(code);
    store.set('language', code);
    // The native side first: it refreshes the system languages that null resolves to.
    await window.setLanguage(code);
    languageSetting.value = code;
    _speaker.language = speechLanguage;
    final section = languagePromptSection(speechLanguage, strings);
    if (tell) notify('[settings] The user changed Minerva\'s language.\n$section');
    notifyListeners();
    return section;
  }

  // ---------------------------------------------------------------- voice

  /// Switches the voice the replies are read with, from the next sentence on.
  @override
  void setVoice(int voice) {
    final v = validVoice(voice);
    if (v == null) return;
    this.voice = v;
    store.set('voice', v == defaultVoice ? null : '$v');
    _speaker.voice = v;
    notifyListeners();
  }

  // ---------------------------------------------------------------- models

  /// Switches the conversation's model, effort or speed. The brain restarts on the same
  /// conversation, at once or when the answer in progress ends.
  @override
  void setBrainModel(ModelChoice choice) {
    brainModel = choice;
    choice.save(store, 'brain');
    final r = choice.resolve(catalog);
    _claude.reconfigure(model: r.model, effort: r.effort, fast: r.fast);
    notifyListeners();
  }

  /// Switches the model, effort or speed of workers started from now on.
  @override
  void setWorkerModel(ModelChoice choice) {
    workerModel = choice;
    choice.save(store, 'workers');
    _applyWorkerModel();
    notifyListeners();
  }

  void _applyWorkerModel() {
    final r = workerModel.resolve(catalog);
    workers
      ..model = r.model
      ..effort = r.effort
      ..fast = r.fast;
  }

  /// Claude Code (re)started: keep its model list, and note whether the account can use fast mode.
  void _described(Map<String, dynamic> info) {
    final c = ClaudeCatalog.fromInfo(info);
    if (c.all.isNotEmpty) {
      catalog = c..save(store);
      _applyWorkerModel();
    }
    // At start Claude Code reports fast mode as asked for; whether the account can use it shows
    // after the first request (FastModeState). Only a reason other than "not asked for" counts.
    final reason = info['fast_mode_disabled_reason'] as String?;
    if (info['fast_mode_state'] != 'on' && reason != null && reason != 'sdk_opt_in_required') {
      fastUnavailable = reason;
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
      ..onVault = _onVaultSubmission
      ..onSettings = _onPhoneSettings
      ..onVaultDelete = _onPhoneVaultDelete
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

  /// Sends the settings to the phone (it shows them, and changes them through [_onPhoneSettings]).
  void _pushSettings() {
    final p = phone;
    if (p == null || !p.active || !ready) return;
    final hooks = webhooks;
    p.pushSettings({
      'brain': brainModel.toJson(),
      'workers': workerModel.toJson(),
      'catalog': catalog?.toJson(),
      'fast_unavailable': fastUnavailable,
      'language': languageSetting.value,
      'voice': voice,
      // Names and field names only: credential values never leave the vault.
      'vault': {
        'error': vault.loadError,
        'credentials': [
          for (final c in vault.credentials)
            {'name': c.name, 'description': c.description, 'fields': [for (final f in c.fields) f.name]},
        ],
      },
      if (hooks != null)
        'webhooks': {
          'on': hooks.online && hooks.certOk,
          'status': hooks.status,
          'hooks': [
            for (final h in hooks.hooks) {'name': h.name, 'description': h.description, 'url': hooks.urlOf(h)},
          ],
        },
    });
  }

  /// The user changed settings on the phone: the same as changing them here.
  void _onPhoneSettings(Map<String, dynamic> m) {
    if (!ready) return;
    final brain = ModelChoice.fromJson(m['brain']);
    if (brain != null && brain != brainModel) setBrainModel(brain);
    final workers = ModelChoice.fromJson(m['workers']);
    if (workers != null && workers != workerModel) setWorkerModel(workers);
    if (m.containsKey('language')) {
      final code = m['language'] is String ? m['language'] as String : null;
      if (validLanguage(code) != languageSetting.value) unawaited(setLanguage(code));
    }
    final v = m['voice'];
    if (v is num && v.toInt() != voice) setVoice(v.toInt());
  }

  /// The user deleted a credential on the phone.
  Future<void> _onPhoneVaultDelete(String name) async {
    if (!ready) return;
    try {
      await vault.delete(name);
    } catch (e) {
      debugPrint('vault: could not delete $name from the phone: $e');
    }
  }

  @override
  void notifyListeners() {
    _pushState();
    _pushSettings();
    super.notifyListeners();
  }

  set muted(bool value) {
    if (value == _muted) return;
    _muted = value;
    presence.muted = value;
    if (value) _listener.flush();
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
      case SpeechDropped():
        _heardNothing();
      case Utterance():
        _userSpeaking = false;
        final wasBargeIn = _barged;
        _barged = false;
        if (busy && !wasBargeIn) {
          debugPrint('ignored ${e.seconds.toStringAsFixed(1)}s of audio while speaking (no barge-in)');
          return;
        }
        var text = e.text;
        if (text.isEmpty) {
          // A short word Parakeet could not make out. If it cut off the answer to what the user
          // had just said, that is asked again rather than lost; otherwise back to listening.
          debugPrint('heard nothing intelligible (${e.seconds.toStringAsFixed(1)}s)');
          if (!wasBargeIn || _carry.isEmpty) return _heardNothing();
          text = _carry;
          _carry = '';
        } else if (_carry.isNotEmpty) {
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

  /// A credential typed in a vault form (here or on the phone): its values go to the vault, and
  /// the brain only hears that it was saved.
  Future<void> _onVaultSubmission(VaultSubmission s) async {
    String event;
    try {
      await vault.save(s.name, s.description, [for (final (n, v, secret) in s.fields) VaultField(n, v, secret: secret)]);
      event = '[display] saved credential ${s.name} (fields ${s.fieldNames.join(', ')})';
    } catch (e) {
      // The error never contains a value; scrubbed anyway.
      event = vault.scrub('[display] could not save credential ${s.name}: $e');
    }
    _onDisplayEvent(event);
  }

  /// Speech that ended without a turn: the user is no longer talking, nothing is carried over,
  /// and whatever waited for the silence (notices, the status line) goes on.
  void _heardNothing() {
    _userSpeaking = false;
    _barged = false;
    _carry = '';
    _updatePresence();
    _drainNotices();
    notifyListeners();
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
    final event = text.startsWith('[display]') || text.startsWith('[worker') || text.startsWith('[routine') ||
        text.startsWith('[webhook');
    store.addMessage(event ? 'event' : 'user', text);
    _generation++;
    _pendingTts = 0;
    _sentence.clear();
    _firstAudioAt = null;
    _setActivity(strings.activityThinking);
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
        final l = strings;
        _setActivity(switch (e.name) {
          'WebSearch' || 'web_search' => l.activityWebSearch,
          'WebFetch' || 'web_fetch' => l.activityWebFetch,
          'get_state' => l.activityLookingAtScreen,
          _ => l.activityPreparingDisplay,
        });
      case ToolInput():
        presence.bumpActivity(0.1);
        if (_isDisplayTool(e.name)) {
          if (onPhone) {
            phone!.partial(e.name, e.partialJson);
          } else {
            if (_usingMac && _widgetTools.contains(e.name)) {
              final at = _atPattern.firstMatch(e.partialJson)?.group(1);
              if (at != null && at != widgetAt) {
                widgetAt = at;
                notifyListeners();
              }
            }
            display.streamPartial(e.name, e.partialJson);
          }
        }
      case MessageTaken():
        break;
      case Described():
        _described(e.info);
      case FastModeState():
        if (fastUnavailable != (e.on ? null : e.reason)) {
          fastUnavailable = e.on ? null : e.reason;
          notifyListeners();
        }
      case Compacting():
        // Takes a few seconds once the context is full; say why the answer is late.
        _setActivity(e.active ? strings.activityCompacting : strings.activityThinking);
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
          _say(strings.brainError, lang: appLocale.languageCode);
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

  /// Speaks [text] in the brain's language, or [lang] (for the app's own lines).
  void _say(String text, {String? lang}) {
    if (Speaker.cleanForSpeech(text).isEmpty) return;
    _spokenStatus = '';
    _pendingTts++;
    _speaker.say(_generation, text, lang: lang);
    _updatePresence();
  }

  // ---------------------------------------------------------------- tools

  Future<ToolResult> _handleTool(String name, Map<String, dynamic> args) async {
    for (final p in providers) {
      if (p.handles(name)) {
        _setActivity(_activityFor(name, strings));
        if (ComputerTools.needsScreen(name, args)) await _useMac(true);
        return p.call(name, args);
      }
    }
    if (name == VaultTools.requestTool.name) return _requestCredential(args);
    if (name == _languageTool.name) {
      final code = args['language'] as String?;
      if (code != 'system' && validLanguage(code) == null) {
        return ToolResult.error('error: language must be one of system, ${languageChoices.join(', ')}');
      }
      return ToolResult('ok. ${await setLanguage(code == 'system' ? null : code, tell: false)}');
    }
    if (name == _windowTool.name) {
      final orb = args['mode'] == 'orb';
      if (onPhone) return const ToolResult('ok: the phone is connected, the Mac window stays the orb.');
      if (!window.open) return const ToolResult('ok: the window is closed (the user is not at the Mac).');
      await _useMac(orb);
      return ToolResult(orb ? 'ok: the window is the corner orb.' : 'ok: the window is back.');
    }
    if (_showingTools.contains(name) && !(_usingMac && _widgetTools.contains(name))) await _useMac(false);
    if (_usingMac && _widgetTools.contains(name)) {
      widgetAt = args['at'] is String ? args['at'] as String : 'top-right';
      notifyListeners();
    }
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

  /// vault_request: a form whose submission goes to the vault ([_onVaultSubmission]).
  Future<ToolResult> _requestCredential(Map<String, dynamic> args) async {
    if (vault.loadError != null) return ToolResult.error('error: ${vault.loadError}');
    final form = VaultTools.requestForm(args);
    if (form is String) return ToolResult.error(form);
    final r = await _handleTool('form', form as Map<String, dynamic>);
    if (r.isError) return r;
    final name = form['vault'];
    final fields = [for (final f in form['fields'] as List) (f as Map)['name']].join(', ');
    return ToolResult('ok: asking the user for credential $name on the display (fields $fields). You will '
        'get "[display] saved credential $name" or "[display] credential request $name cancelled"; you '
        'never see the values. Use {{vault:$name.<field>}} once it is saved.');
  }

  /// Shrinks the window to the corner orb while Minerva works in other apps of the Mac (the
  /// Mac keeps listening and speaking), or brings it back. Nothing changes while a phone is
  /// connected (the window is already the orb) or while the window is closed.
  Future<void> _useMac(bool on) async {
    if (on == _usingMac) return;
    if (on && (onPhone || !window.open)) return;
    _usingMac = on;
    if (on) {
      _widgetFrom = display.timeline.fold(0, (m, e) => e.seq > m ? e.seq : m) + 1;
      _widgetClosed = null;
    }
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

  static String _activityFor(String tool, AppLocalizations l) => switch (tool) {
        'remember' || 'search_memories' || 'forget_memory' => l.activityRemembering,
        'search_history' => l.activitySearchingHistory,
        'read_skill' || 'save_skill' || 'delete_skill' => l.activityReadingSkill,
        'start_worker' || 'message_worker' => l.activityStartingWorker,
        'list_workers' || 'worker_status' || 'stop_worker' => l.activityCheckingWorkers,
        'create_routine' || 'list_routines' || 'update_routine' || 'delete_routine' => l.activityScheduling,
        'webhook_create' || 'webhook_list' || 'webhook_delete' => l.activityWebhooks,
        'run_command' => l.activityRunningCommand,
        'read_file' || 'list_dir' => l.activityReadingFiles,
        'write_file' => l.activityWritingFile,
        'screen' => l.activityLookingAtScreen,
        'ui_tree' || 'apps' || 'windows' => l.activityReadingUi,
        _ => l.activityUsingComputer,
      };

  // ---------------------------------------------------------------- output

  void _onSpeech(Speech s) {
    if (s.generation == _statusGeneration) {
      // A status line: dropped once it is stale or the reply has started.
      if (_statusQuiet && _statusSpeech(activity) == s.text) {
        _play(s.samples);
        _updatePresence();
      }
      return;
    }
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
    _statusTimer?.cancel();
    if (text.isNotEmpty) _statusTimer = Timer(statusDelay, _speakStatus);
    notifyListeners();
  }

  void _speakStatus() {
    final text = _statusSpeech(activity);
    if (text.isEmpty || text == _spokenStatus || !_statusQuiet) return;
    _spokenStatus = text;
    _speaker.say(_statusGeneration, text, lang: appLocale.languageCode);
  }

  int get _statusGeneration => -_generation - 1;

  /// Nothing of the reply is queued or playing, and the user is not talking.
  bool get _statusQuiet => ready && _pendingTts == 0 && !_playing && !_userSpeaking;

  /// "Thinking…" → "Thinking." (as [Speaker] cleans it, to match its audio).
  static String _statusSpeech(String status) {
    final s = status.replaceAll('…', '').trim();
    return s.isEmpty ? '' : Speaker.cleanForSpeech('$s.');
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
    _statusTimer?.cancel();
    window.removeListener(_syncAudio);
    window.dispose();
    presence.removeListener(_pushState);
    unawaited(phone?.close());
    webhooks?.dispose();
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
