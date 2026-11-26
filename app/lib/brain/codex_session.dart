import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'brain_session.dart';
import 'fallback.dart';
import 'models.dart';

/// A long-lived `codex app-server` process: OpenAI's Codex CLI as a JSON-RPC server over stdio
/// (the protocol its IDE extension and desktop app use), kept warm between turns, with Minerva's
/// tools from our MCP server.
///
/// It runs on the user's ChatGPT subscription: `codex` signs in with their ChatGPT account (run
/// `codex login` once in a terminal), never with an API key from Minerva. The conversation is a
/// Codex thread: new ones get their id from it ([onSessionId]), and [sessionId] is resumed on the
/// next start (`thread/resume`), so it survives restarts.
///
/// The user's own Codex setup stays out of Minerva's sessions: their MCP servers are turned off
/// for its threads, and so are plugins, apps, memories, hooks, subagents, browser and computer
/// use. The brain has no shell (only the web); workers get a read-only one ([fileTools]), the
/// way the other providers get read-only file tools. Anything that asks for approval is refused.
class CodexSession implements BrainSession {
  CodexSession({
    required this.model,
    required this.systemPrompt,
    required this.mcpUrl,
    required this.workDir,
    this.effort,
    this.fast = false,
    this.sessionId,
    this.onSessionId,
    this.describe = false,
    this.fileTools = false,
    this.replayUserMessages = false,
    this.requireSignIn = true,
  });

  /// Codex model id, reasoning effort (null: the model's default) and fast mode (the `priority`
  /// service tier). Change them with [reconfigure]; each turn carries them.
  String model;
  String? effort;
  bool fast;

  final String systemPrompt;
  final String mcpUrl;
  final String workDir;

  /// Codex thread id; null until it creates one.
  String? sessionId;
  final void Function(String id)? onSessionId;

  /// Emit a [Described] event with the models at every start.
  final bool describe;

  /// A read-only shell (in Codex's sandbox) to look at files, besides the web.
  final bool fileTools;

  /// Emit [MessageTaken] for each sent message as it goes to Codex (a message sent while a turn
  /// runs steers that turn instead of getting its own).
  final bool replayUserMessages;

  /// Fail at start when Codex is not signed in (false only to smoke-test the rest without it).
  final bool requireSignIn;

  /// How Minerva's MCP server came up in Codex (`starting`, `ready`, `failed`…).
  String? mcpStatus;

  static const server = 'minerva';

  final _events = StreamController<BrainEvent>.broadcast();
  @override
  Stream<BrainEvent> get events => _events.stream;

  Process? _proc;
  @override
  bool busy = false;
  Future<void>? _starting;
  bool _ready = false;

  int _nextId = 1;
  final _pending = <int, Completer<Map<String, dynamic>>>{};

  /// The turn in progress (null until Codex answered `turn/start`), and whether it is being
  /// interrupted.
  String? _turnId;
  bool _discard = false;
  bool _interrupting = false;

  /// The message of the turn in progress, and whether it was already re-sent after a crash.
  String? _inFlight;
  bool _retried = false;

  /// The turn's last message (what a worker reports), its last error and the latest reset time
  /// of a rate-limit window Codex reported full.
  String _lastMessage = '';
  Map<String, dynamic>? _lastError;
  DateTime? _resetsAt;
  final _toolIndex = <String, int>{};
  final _log = StringBuffer();

  @override
  String get stderrTail => _log.toString();

  @override
  bool get running => _proc != null;

  @override
  Future<void> start() => _starting ??= _start().whenComplete(() => _starting = null);

  /// Codex settings for Minerva's sessions (over the user's config.toml): none of their own
  /// extras, and the web on.
  static List<String> overrides({required bool shell}) => [
    'notify=[]',
    'web_search="live"',
    'check_for_update_on_startup=false',
    'model_reasoning_summary="none"',
    for (final f in [
      'plugins',
      'apps',
      'memories',
      'hooks',
      'multi_agent',
      'goals',
      'computer_use',
      'browser_use',
      'in_app_browser',
      'image_generation',
      'tool_suggest',
      'skill_mcp_dependency_install',
      if (!shell) ...['shell_tool', 'unified_exec'],
    ])
      'features.$f=false',
  ];

  /// Spawns `codex app-server` and says hello; returns its version (from its user agent).
  Future<String> _spawn() async {
    final env = await loginEnvironment();
    final codex = findExecutable('codex', env['PATH']!);
    if (codex == null) throw StateError(notInstalled);
    await Directory(workDir).create(recursive: true);
    final p = await Process.start(
      codex,
      [
        'app-server',
        for (final o in overrides(shell: fileTools)) ...['-c', o],
      ],
      workingDirectory: workDir,
      environment: env,
      includeParentEnvironment: false,
    );
    _proc = p;
    _ready = false;
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine);
    p.stderr.transform(utf8.decoder).listen(_addLog);
    unawaited(p.exitCode.then((code) => _exited(p, code)));
    final init = await _request('initialize', {
      'clientInfo': {'name': 'minerva', 'title': 'Minerva', 'version': '1'},
      'capabilities': {'experimentalApi': true, 'requestAttestation': false, 'optOutNotificationMethods': _quiet},
    });
    _notify('initialized');
    return versionOf(init['userAgent']);
  }

  /// Notifications Minerva has no use for (diffs, terminal output, reasoning, realtime audio…).
  static const _quiet = [
    'turn/diff/updated',
    'turn/plan/updated',
    'item/plan/delta',
    'item/commandExecution/outputDelta',
    'item/fileChange/outputDelta',
    'item/reasoning/summaryTextDelta',
    'item/reasoning/summaryPartAdded',
    'item/reasoning/textDelta',
    'thread/tokenUsage/updated',
    'remoteControl/status/changed',
  ];

  /// `minerva/0.154.0 (Mac OS …)` → `0.154.0`.
  static String versionOf(Object? userAgent) => RegExp(r'^[^/]+/(\S+)').firstMatch('${userAgent ?? ''}')?[1] ?? '';

  Future<void> _start() async {
    try {
      final version = await _spawn();
      final account = await _request('account/read', {});
      if (requireSignIn && account['account'] == null && account['requiresOpenaiAuth'] == true) {
        throw StateError(notSignedIn);
      }
      // The user's own MCP servers stay off in Minerva's threads (each one by name: Codex has no
      // switch for all of them, and a name it does not know is an error).
      final config = await _request('config/read', {'cwd': workDir});
      final own = ((config['config'] as Map?)?['mcp_servers'] as Map?)?.keys ?? const [];
      final params = {
        'cwd': workDir,
        'approvalPolicy': 'never',
        'sandbox': 'read-only',
        'developerInstructions': '$systemPrompt\n\n${_toolsSection(fileTools)}',
        'config': {
          'mcp_servers': {
            for (final n in own)
              if (n != server) '$n': {'enabled': false},
            server: {
              'url': mcpUrl,
              'default_tools_approval_mode': 'approve',
              'startup_timeout_sec': 30,
              // Commands and workers' tools can run for minutes.
              'tool_timeout_sec': 900,
              // The display tools' schemas are long.
              'tool_input_schema_max_bytes': 1000000,
            },
          },
        },
        'model': model,
      };
      final id = sessionId;
      if (id != null) {
        try {
          await _request('thread/resume', {...params, 'threadId': id, 'excludeTurns': true});
        } on CodexError catch (e) {
          // Gone (deleted, or never had a turn so Codex never saved it): start a new one.
          if (!e.notFound) rethrow;
          _addLog('codex: thread $id not found, starting a new one\n');
          sessionId = null;
        }
      }
      if (sessionId == null) {
        final r = await _request('thread/start', {...params, 'ephemeral': false});
        final created = (r['thread'] as Map)['id'] as String;
        sessionId = created;
        onSessionId?.call(created);
      }
      _ready = true;
      if (describe) {
        final listed = await _request('model/list', {});
        final models = listed['data'];
        if (models is List && models.isNotEmpty) {
          _events.add(
            Described(
              listed,
              catalog: ModelCatalog.codex(version: version, models: models),
            ),
          );
        }
      }
    } on CodexError catch (e) {
      dispose();
      throw StateError('codex: ${e.message}');
    } catch (_) {
      dispose();
      rethrow;
    }
  }

  static const notInstalled = '`codex` not found. Install the Codex CLI and sign in first (codex login).';
  static const notSignedIn = 'Codex is not signed in: run codex login in a terminal and sign in with ChatGPT.';

  /// What Codex is told about its tools, after Minerva's prompt.
  static String _toolsSection(bool shell) =>
      '''
Tools in this session:
- Minerva's tools come from the MCP server "$server" (show, run_command and the rest). Use them for everything Minerva's prompt describes; they run on the user's Mac outside any sandbox.
- Of Codex's own tools only web search${shell ? ' and a read-only shell to look at files (it can\'t change anything; use Minerva\'s run_command and write_file for that)' : ''} are available.
- Minerva's prompt above comes before any coding-agent instructions (AGENTS.md).'''
          .trim();

  void _exited(Process p, int code) {
    if (_proc != p) return;
    _proc = null;
    _ready = false;
    _turnId = null;
    _interrupting = false;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(CodexError(-1, 'codex exited ($code)'));
    }
    _pending.clear();
    if (!busy) return;
    final pending = _inFlight;
    if (pending != null && !_retried && !_discard) {
      // The process died mid-turn (killed, crashed): restart it, resuming the same thread, and
      // send the turn again once before reporting an error.
      _retried = true;
      busy = false;
      unawaited(send(pending));
      return;
    }
    busy = false;
    _inFlight = null;
    _retried = false;
    _events.add(TurnDone(interrupted: _discard, error: _discard ? null : 'codex exited ($code): ${stderrTail.trim()}'));
  }

  /// Taken by the next turn (each `turn/start` carries the model, effort and speed).
  @override
  void reconfigure({required String model, required String? effort, required bool fast}) {
    this.model = model;
    this.effort = effort;
    this.fast = fast;
  }

  @override
  Future<void> send(String text) async {
    try {
      if (_starting != null) await _starting;
      if (_proc == null || !_ready) await start();
    } catch (e) {
      busy = false;
      _events.add(TurnDone(interrupted: false, error: 'codex start failed: $e'));
      return;
    }
    // An interrupted turn closes within a moment; a message sent before it has would steer it.
    for (var i = 0; i < 300 && _interrupting; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final steering = busy;
    busy = true;
    _discard = false;
    _inFlight = text;
    if (!steering) {
      _lastMessage = '';
      _lastError = null;
    }
    try {
      // Sent while a turn runs, it steers that turn; else it starts one.
      final r = await _request('turn/start', {
        'threadId': sessionId,
        'input': [
          {'type': 'text', 'text': text, 'text_elements': <Object>[]},
        ],
        'model': model,
        'effort': ?effort,
        'serviceTier': fast ? 'priority' : null,
      });
      final turn = r['turn'];
      if (turn is Map && turn['id'] is String && busy) _turnId ??= turn['id'] as String;
      if (replayUserMessages) _events.add(MessageTaken());
      if (_interrupting && _turnId != null) _interruptTurn();
    } catch (e) {
      if (_proc == null) return; // it exited: [_exited] retries or reports
      _finish(TurnDone(interrupted: false, error: e is CodexError && e.authRequired ? notSignedIn : '$e'));
    }
  }

  void _finish(TurnDone done) {
    busy = false;
    _turnId = null;
    _interrupting = false;
    _discard = false;
    _inFlight = null;
    _retried = false;
    _toolIndex.clear();
    _events.add(done);
  }

  @override
  void interrupt() {
    if (!busy || _proc == null) return;
    _discard = true;
    _interrupting = true;
    if (_turnId != null) _interruptTurn();
  }

  void _interruptTurn() {
    unawaited(
      _request('turn/interrupt', {'threadId': sessionId, 'turnId': _turnId}).catchError((Object e) {
        _addLog('codex: interrupt failed: $e\n');
        return <String, dynamic>{};
      }),
    );
  }

  @override
  void dispose() {
    final p = _proc;
    _proc = null;
    _ready = false;
    p?.kill();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(CodexError(-1, 'closed'));
    }
    _pending.clear();
  }

  // ---------------------------------------------------------------- JSON-RPC

  Future<Map<String, dynamic>> _request(String method, Map<String, Object?> params) {
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _write({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    return c.future;
  }

  void _notify(String method) => _write({'jsonrpc': '2.0', 'method': method});

  void _write(Map<String, Object?> msg) {
    try {
      _proc?.stdin.writeln(jsonEncode(msg));
    } catch (e) {
      _addLog('codex: write failed: $e\n');
    }
  }

  void _addLog(String s) {
    _log.write(s);
    if (_log.length > 4000) {
      final tail = _log.toString().substring(_log.length - 2000);
      _log
        ..clear()
        ..write(tail);
    }
  }

  void _onLine(String line) {
    Map<String, dynamic> m;
    try {
      m = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final method = m['method'];
    if (method == null) {
      final c = _pending.remove(m['id']);
      if (c == null || c.isCompleted) return;
      final error = m['error'];
      if (error is Map) {
        c.completeError(CodexError((error['code'] as num?)?.toInt() ?? 0, '${error['message'] ?? error}'));
      } else {
        final r = m['result'];
        c.complete(r is Map ? r.cast<String, dynamic>() : <String, dynamic>{});
      }
      return;
    }
    final params = m['params'] is Map ? (m['params'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    if (m.containsKey('id')) {
      _answer(m['id'], method as String, params);
    } else {
      onNotification(method as String, params);
    }
  }

  /// Requests from Codex: anything asking for approval is refused (its own shell and file edits
  /// are not Minerva's way to act), except Minerva's own MCP tools; nothing else is offered.
  void _answer(Object? id, String method, Map<String, dynamic> params) {
    final Object? result = switch (method) {
      'item/commandExecution/requestApproval' || 'item/fileChange/requestApproval' => {'decision': 'decline'},
      'execCommandApproval' || 'applyPatchApproval' => {'decision': 'denied'},
      'mcpServer/elicitation/request' =>
        params['serverName'] == server
            ? {'action': 'accept', 'content': <String, Object?>{}, '_meta': null}
            : {'action': 'decline', 'content': null, '_meta': null},
      _ => null,
    };
    if (result == null) {
      _addLog('codex: refused $method\n');
      _write({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32601, 'message': 'not supported by Minerva: $method'},
      });
      return;
    }
    if (method != 'mcpServer/elicitation/request') _addLog('codex: declined $method\n');
    _write({'jsonrpc': '2.0', 'id': id, 'result': result});
  }

  /// A notification from Codex (public for tests: a turn's events without a process).
  void onNotification(String method, Map<String, dynamic> p) {
    if (method == 'account/rateLimits/updated') return _rateLimits(p['rateLimits']);
    if (method == 'mcpServer/startupStatus/updated' && p['name'] == server) {
      mcpStatus = '${p['status']}';
      if (mcpStatus == 'failed') _addLog('codex: MCP server $server failed: ${p['error'] ?? ''}\n');
      return;
    }
    if (p['threadId'] != null && p['threadId'] != sessionId) return;
    switch (method) {
      case 'turn/started':
        final turn = p['turn'];
        if (busy && _turnId == null && turn is Map && turn['id'] is String) {
          _turnId = turn['id'] as String;
          if (_interrupting) _interruptTurn();
        }
      case 'turn/completed':
        final turn = p['turn'] is Map ? (p['turn'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
        if (!busy || (_turnId != null && turn['id'] != _turnId)) return;
        _turnDone(turn);
      case 'error':
        if (p['error'] is Map && p['willRetry'] != true) _lastError = (p['error'] as Map).cast<String, dynamic>();
      case 'item/agentMessage/delta':
        if (_discard || !busy) return;
        final delta = p['delta'];
        if (delta is String && delta.isNotEmpty) _events.add(TextDelta(delta));
      case 'item/started' || 'item/completed':
        if (_discard || !busy || p['item'] is! Map) return;
        _onItem((p['item'] as Map).cast<String, dynamic>(), started: method == 'item/started');
    }
  }

  void _onItem(Map<String, dynamic> item, {required bool started}) {
    switch (item['type']) {
      case 'agentMessage' when !started:
        final text = item['text'];
        if (text is String && text.trim().isNotEmpty) _lastMessage = text.trim();
      case 'contextCompaction':
        _events.add(Compacting(started));
      case 'mcpToolCall' when started:
        final tool = '${item['tool'] ?? ''}';
        final name = item['server'] == server ? tool : '${item['server']}.$tool';
        final index = _tool(item, name);
        final args = item['arguments'];
        _events.add(ToolInput(index, name, jsonEncode(args is Map ? args : const {})));
      case 'webSearch' when started:
        _tool(item, 'web_search');
      case 'commandExecution' when started:
        _tool(item, 'shell');
    }
  }

  int _tool(Map<String, dynamic> item, String name) {
    final id = '${item['id']}';
    var index = _toolIndex[id];
    if (index == null) {
      index = _toolIndex[id] = _toolIndex.length;
      _events.add(ToolStart(index, name));
    }
    return index;
  }

  void _turnDone(Map<String, dynamic> turn) {
    final status = turn['status'];
    final interrupted = _discard || status == 'interrupted';
    String? error;
    ProviderLimit? limit;
    if (!interrupted && status == 'failed') {
      final e = turn['error'] is Map ? (turn['error'] as Map).cast<String, dynamic>() : _lastError;
      error = '${e?['message'] ?? 'codex turn failed'}';
      limit = limitOf(e, resetsAt: _resetsAt);
      if (limit?.reason == LimitReason.signIn) error = '$notSignedIn ($error)';
    }
    _finish(TurnDone(interrupted: interrupted, error: error, result: _lastMessage, limit: limit));
  }

  /// A turn's error as a provider limit: Codex says which kind ([codexErrorInfo]); the reset
  /// comes from its rate-limit windows, else from the message.
  static ProviderLimit? limitOf(Map<String, dynamic>? error, {DateTime? resetsAt}) {
    if (error == null) return null;
    final info = error['codexErrorInfo'];
    final message = '${error['message'] ?? ''}';
    return switch (info) {
      'usageLimitExceeded' || 'rateLimitExceeded' => ProviderLimit(
        LimitReason.usage,
        resetsAt: resetsAt ?? resetIn(message, now: DateTime.now()),
      ),
      'unauthorized' => const ProviderLimit(LimitReason.signIn),
      _ => limitIn(message),
    };
  }

  /// Codex's rate-limit windows: the latest reset of one that is full.
  void _rateLimits(Object? snapshot) {
    if (snapshot is! Map) return;
    DateTime? reset;
    for (final w in [snapshot['primary'], snapshot['secondary']]) {
      if (w is! Map || (w['usedPercent'] as num? ?? 0) < 100 || w['resetsAt'] is! num) continue;
      final t = DateTime.fromMillisecondsSinceEpoch((w['resetsAt'] as num).toInt() * 1000);
      if (reset == null || t.isAfter(reset)) reset = t;
    }
    _resetsAt = reset;
  }

  /// The models of the installed Codex CLI (its app server's `model/list`), or null when it is
  /// missing or not signed in.
  static Future<ModelCatalog?> listModels() async {
    final s = CodexSession(model: '', systemPrompt: '', mcpUrl: '', workDir: Directory.systemTemp.path);
    try {
      final version = await s._spawn().timeout(const Duration(seconds: 30));
      final account = await s._request('account/read', {}).timeout(const Duration(seconds: 30));
      if (account['account'] == null && account['requiresOpenaiAuth'] == true) return null;
      final listed = await s._request('model/list', {}).timeout(const Duration(seconds: 30));
      final models = listed['data'];
      if (models is! List || models.isEmpty) return null;
      return ModelCatalog.codex(version: version, models: models);
    } catch (_) {
      return null;
    } finally {
      s.dispose();
    }
  }

  /// The account's rate limits (the app server's `account/rateLimits/read`), or null when Codex
  /// is missing, not signed in or can't read them.
  static Future<Map<String, dynamic>?> readRateLimits() async {
    final s = CodexSession(model: '', systemPrompt: '', mcpUrl: '', workDir: Directory.systemTemp.path);
    try {
      await s._spawn().timeout(const Duration(seconds: 30));
      final account = await s._request('account/read', {}).timeout(const Duration(seconds: 30));
      if (account['account'] == null) return null;
      return await s
          ._request('account/rateLimits/read', {'excludeResetCreditDetails': true})
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      return null;
    } finally {
      s.dispose();
    }
  }
}

/// A JSON-RPC error from `codex app-server`.
class CodexError implements Exception {
  CodexError(this.code, this.message);
  final int code;
  final String message;

  bool get authRequired => message.contains('401') || message.toLowerCase().contains('sign in');

  /// No such thread: never saved (it had no turn yet) or deleted.
  bool get notFound => message.startsWith('no rollout found') || message.startsWith('invalid session id');

  @override
  String toString() => 'codex error $code: $message';
}
