import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'brain_session.dart';
import 'models.dart';

/// A long-lived `agy acp` process: Google Antigravity's CLI as an Agent Client Protocol server
/// (JSON-RPC over stdio), kept warm between turns, with Minerva's tools from our MCP server.
///
/// It runs on the user's Antigravity subscription: `agy` signs in with their Google account (run
/// `agy` once in a terminal), never with an API key. The conversation is Antigravity's own: new
/// ones get their id from it ([onSessionId]), and [sessionId] is resumed on the next start
/// (`session/resume`, without replaying the history), so it survives restarts.
///
/// Antigravity has its own tools (shell, file edits, browser, subagents…) that can't be turned
/// off per session: they ask for permission, and only [builtinTools] and Minerva's MCP tools get
/// it. The rest are refused, so commands go through Minerva's (with the vault's placeholders).
class AntigravitySession implements BrainSession {
  AntigravitySession({
    required this.model,
    required this.systemPrompt,
    required this.mcpUrl,
    required this.workDir,
    this.sessionId,
    this.onSessionId,
    this.describe = false,
    this.builtinTools = webTools,
    this.replayUserMessages = false,
  });

  /// Antigravity model id, thinking level included (`gemini-4-neon-low`; see
  /// [ModelChoice.resolve]). Change it with [reconfigure].
  String model;

  final String systemPrompt;
  final String mcpUrl;
  final String workDir;

  /// Antigravity conversation id; null until it creates one.
  String? sessionId;
  final void Function(String id)? onSessionId;

  /// Emit a [Described] event with the models at every start.
  final bool describe;

  /// Antigravity's own tools that may run, besides Minerva's MCP tools.
  final Set<String> builtinTools;

  /// Emit [MessageTaken] for each sent message as it goes to Antigravity (a message sent while a
  /// turn runs steers that turn instead of getting its own).
  final bool replayUserMessages;

  static const webTools = {'search_web', 'read_url_content'};
  static const fileTools = {...webTools, 'view_file', 'list_dir', 'grep_search', 'find_by_name'};

  static const server = 'minerva';
  static const _prefix = 'mcp_${server}_';

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

  /// The prompt request whose answer ends the turn in progress (the latest one sent), and the
  /// one being cancelled.
  int? _turn;
  int? _cancelling;
  bool _discard = false;
  bool _modelPending = false;

  /// The message of the turn in progress, and whether it was already re-sent after a crash.
  String? _inFlight;
  bool _retried = false;

  /// The turn's text since its last tool call (its final message: what a worker reports).
  final _reply = StringBuffer();
  final _toolIndex = <String, int>{};
  final _toolJson = <String, String>{};
  final _log = StringBuffer();

  @override
  String get stderrTail => _log.toString();

  @override
  bool get running => _proc != null;

  @override
  Future<void> start() => _starting ??= _start().whenComplete(() => _starting = null);

  Future<void> _start() async {
    final env = await loginEnvironment();
    final agy = findExecutable('agy', env['PATH']!);
    if (agy == null) throw StateError(notInstalled);
    // The CLI updates itself on its own schedule, not in the middle of a conversation.
    env['AGY_CLI_DISABLE_AUTO_UPDATE'] = 'true';
    await Directory(workDir).create(recursive: true);
    final p = await Process.start(agy, ['acp'], workingDirectory: workDir, environment: env,
        includeParentEnvironment: false);
    _proc = p;
    _ready = false;
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine);
    p.stderr.transform(utf8.decoder).listen(_addLog);
    unawaited(p.exitCode.then((code) => _exited(p, code)));
    try {
      final init = await _request('initialize', {
        'protocolVersion': 1,
        'clientCapabilities': {
          'fs': {'readTextFile': false, 'writeTextFile': false},
          'terminal': false,
        },
        'clientInfo': {'name': 'minerva', 'version': '1'},
      });
      final params = {
        'cwd': workDir,
        'mcpServers': [
          {'type': 'http', 'name': server, 'url': mcpUrl, 'headers': <Object>[]},
        ],
        '_meta': {
          'antigravity': {
            'systemPrompt': {'append': '$systemPrompt\n\n${_toolsSection(builtinTools)}'},
          },
        },
      };
      Map<String, dynamic>? session;
      final id = sessionId;
      if (id != null) {
        try {
          session = await _request('session/resume', {...params, 'sessionId': id});
        } on AcpError catch (e) {
          // Gone (deleted by the user, or another Antigravity install): start a new one.
          if (!e.notFound) rethrow;
          _addLog('antigravity: session $id not found, starting a new one\n');
          sessionId = null;
        }
      }
      if (sessionId == null) {
        session = await _request('session/new', params);
        final created = session['sessionId'] as String;
        sessionId = created;
        onSessionId?.call(created);
      }
      _ready = true;
      if (describe) {
        final listed = session!['models'];
        final models = listed is Map ? listed['availableModels'] : null;
        if (models is List && models.isNotEmpty) {
          final version = ((init['agentInfo'] as Map?)?['version'] as String?) ?? '';
          _events.add(Described(session, catalog: ModelCatalog.antigravity(version: version, models: _pairs(models))));
        }
      }
      await _applyModel();
    } on AcpError catch (e) {
      dispose();
      throw StateError(e.authRequired ? notSignedIn : 'antigravity: ${e.message}');
    } catch (_) {
      dispose();
      rethrow;
    }
  }

  static const notInstalled = '`agy` not found. Install the Antigravity CLI and sign in first (run agy once).';
  static const notSignedIn = 'Antigravity is not signed in: run agy in a terminal and log in with Google.';

  /// What Antigravity is told about its tools, after Minerva's prompt.
  static String _toolsSection(Set<String> builtins) => '''
Tools in this session:
- Minerva's tools are the ones named mcp_${server}_<name>: mcp_${server}_show is show, mcp_${server}_run_command is run_command, and so on. Use them for everything Minerva's prompt describes.
- Of Antigravity's own tools only ${builtins.join(', ')} are allowed; any other is refused. Never use Antigravity's shell, file editing, browser, subagent or scheduling tools: Minerva's tools do that.'''
      .trim();

  void _exited(Process p, int code) {
    if (_proc != p) return;
    _proc = null;
    _ready = false;
    final turn = _turn;
    _turn = null;
    _cancelling = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(AcpError(-1, 'agy exited ($code)'));
    }
    _pending.clear();
    if (!busy || turn == null) return;
    final pending = _inFlight;
    if (pending != null && !_retried && !_discard) {
      // The process died mid-turn (killed, crashed): restart it, resuming the same conversation,
      // and send the turn again once before reporting an error.
      _retried = true;
      busy = false;
      unawaited(send(pending));
      return;
    }
    busy = false;
    _inFlight = null;
    _retried = false;
    _events.add(TurnDone(interrupted: _discard, error: _discard ? null : 'agy exited ($code): ${stderrTail.trim()}'));
  }

  @override
  void reconfigure({required String model, required String? effort, required bool fast}) {
    if (model == this.model) return;
    this.model = model;
    if (!_ready) return; // applied when the session starts
    if (busy) {
      _modelPending = true;
    } else {
      unawaited(_applyModel());
    }
  }

  Future<void> _applyModel() async {
    _modelPending = false;
    try {
      await _request('session/set_model', {'sessionId': sessionId, 'modelId': model});
    } catch (e) {
      // An unknown model (no longer offered): the session keeps the one it had.
      _addLog('antigravity: could not switch to $model: $e\n');
    }
  }

  @override
  Future<void> send(String text) async {
    try {
      if (_starting != null) await _starting;
      if (_proc == null || !_ready) await start();
    } catch (e) {
      busy = false;
      _events.add(TurnDone(interrupted: false, error: 'antigravity start failed: $e'));
      return;
    }
    // A cancelled turn closes within a few ms; Antigravity refuses a prompt until it has.
    for (var i = 0; i < 300 && _cancelling != null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    busy = true;
    _discard = false;
    _inFlight = text;
    final id = _nextId++;
    // A prompt sent while a turn runs steers it: the earlier prompt is answered at once and this
    // one ends the turn.
    _turn = id;
    if (replayUserMessages) _events.add(MessageTaken());
    unawaited(_call(id, 'session/prompt', {
      'sessionId': sessionId,
      'prompt': [
        {'type': 'text', 'text': text},
      ],
    }).then((r) => _promptDone(id, r, null), onError: (Object e) => _promptDone(id, null, e)));
  }

  void _promptDone(int id, Map<String, dynamic>? result, Object? error) {
    if (_cancelling == id) _cancelling = null;
    if (id != _turn) return; // steered into a later prompt, or the process died
    _turn = null;
    busy = false;
    _inFlight = null;
    _retried = false;
    final stop = result?['stopReason'];
    final interrupted = _discard || stop == 'cancelled';
    _discard = false;
    final text = _reply.toString().trim();
    _reply.clear();
    _toolIndex.clear();
    _toolJson.clear();
    String? err;
    if (!interrupted) {
      if (error != null) {
        err = error is AcpError && error.authRequired ? notSignedIn : '$error';
      } else if (stop == 'refusal') {
        err = 'antigravity refused the request';
      }
    }
    _events.add(TurnDone(interrupted: interrupted, error: err, result: text));
    if (_modelPending) unawaited(_applyModel());
  }

  @override
  void interrupt() {
    if (!busy || _proc == null) return;
    _discard = true;
    _cancelling = _turn;
    _notify('session/cancel', {'sessionId': sessionId});
  }

  @override
  void dispose() {
    final p = _proc;
    _proc = null;
    _ready = false;
    p?.kill();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(AcpError(-1, 'closed'));
    }
    _pending.clear();
  }

  // ---------------------------------------------------------------- JSON-RPC

  Future<Map<String, dynamic>> _request(String method, Map<String, Object?> params) =>
      _call(_nextId++, method, params);

  Future<Map<String, dynamic>> _call(int id, String method, Map<String, Object?> params) {
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _write({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    return c.future;
  }

  void _notify(String method, Map<String, Object?> params) =>
      _write({'jsonrpc': '2.0', 'method': method, 'params': params});

  void _write(Map<String, Object?> msg) {
    try {
      _proc?.stdin.writeln(jsonEncode(msg));
    } catch (e) {
      _addLog('antigravity: write failed: $e\n');
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
        c.completeError(AcpError((error['code'] as num?)?.toInt() ?? 0, '${error['message'] ?? error}'));
      } else {
        final r = m['result'];
        c.complete(r is Map ? r.cast<String, dynamic>() : <String, dynamic>{});
      }
      return;
    }
    final params = m['params'] is Map ? (m['params'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    if (m.containsKey('id')) {
      _answer(m['id'], method as String, params);
    } else if (method == 'session/update' && params['sessionId'] == sessionId && params['update'] is Map) {
      _onUpdate((params['update'] as Map).cast<String, dynamic>());
    }
  }

  /// Requests from Antigravity: tool permissions (Minerva's tools and [builtinTools] get it, the
  /// rest are refused); nothing else is offered (files and terminals are not the client's here).
  void _answer(Object? id, String method, Map<String, dynamic> params) {
    if (method != 'session/request_permission') {
      _write({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32601, 'message': 'not supported by Minerva: $method'},
      });
      return;
    }
    final call = params['toolCall'] is Map ? params['toolCall'] as Map : const {};
    final name = '${call['name'] ?? ''}';
    final allow = name.startsWith(_prefix) || builtinTools.contains(name);
    final options = [for (final o in params['options'] as List? ?? const []) if (o is Map) o];
    // Once: "always" would be saved in the user's own Antigravity settings.
    final kinds = allow ? ['allow_once', 'allow_always'] : ['reject_once', 'reject_always'];
    Map? pick;
    for (final k in kinds) {
      pick ??= options.where((o) => o['kind'] == k).firstOrNull;
    }
    if (!allow) _addLog('antigravity: refused its own tool $name\n');
    _write({
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'outcome': pick == null ? {'outcome': 'cancelled'} : {'outcome': 'selected', 'optionId': pick['optionId']},
      },
    });
  }

  void _onUpdate(Map<String, dynamic> u) {
    if (_discard || _turn == null) return;
    switch (u['sessionUpdate']) {
      case 'agent_message_chunk':
        final content = u['content'];
        if (content is Map && content['type'] == 'text' && content['text'] is String) {
          final text = content['text'] as String;
          _reply.write(text);
          _events.add(TextDelta(text));
        }
      case 'tool_call' || 'tool_call_update':
        final callId = '${u['toolCallId']}';
        final name = _shortName('${u['name'] ?? u['title'] ?? ''}');
        var index = _toolIndex[callId];
        if (index == null) {
          index = _toolIndex[callId] = _toolIndex.length;
          _reply.clear();
          _events.add(ToolStart(index, name));
        }
        final input = u['rawInput'];
        if (input is Map) {
          // Antigravity adds a one-line summary of the call for its own UI.
          final json = jsonEncode(Map.of(input)..remove('toolSummary'));
          if (_toolJson[callId] != json) {
            _toolJson[callId] = json;
            _events.add(ToolInput(index, name, json));
          }
        }
    }
  }

  static String _shortName(String name) => name.startsWith(_prefix) ? name.substring(_prefix.length) : name;

  static List<(String, String)> _pairs(List models) => [
        for (final m in models)
          if (m is Map && m['modelId'] is String) (m['modelId'] as String, '${m['name'] ?? m['modelId']}'),
      ];

  /// The models of the installed Antigravity CLI (`agy models`), or null when it is missing, not
  /// signed in or offline.
  static Future<ModelCatalog?> listModels() async {
    try {
      final env = await loginEnvironment();
      final agy = findExecutable('agy', env['PATH']!);
      if (agy == null) return null;
      env['AGY_CLI_DISABLE_AUTO_UPDATE'] = 'true';
      Future<ProcessResult> run(List<String> args) => Process.run(agy, args,
              environment: env, includeParentEnvironment: false, workingDirectory: Directory.systemTemp.path)
          .timeout(const Duration(seconds: 60));
      final listed = await run(['models']);
      if (listed.exitCode != 0) return null;
      final models = <(String, String)>[
        for (final line in (listed.stdout as String).split('\n'))
          if (line.contains('\t')) (line.split('\t').first.trim(), line.split('\t').skip(1).join('\t').trim()),
      ];
      if (models.isEmpty) return null;
      final version = await run(['--version']);
      return ModelCatalog.antigravity(version: (version.stdout as String).trim(), models: models);
    } catch (_) {
      return null;
    }
  }
}

/// A JSON-RPC error from `agy acp`.
class AcpError implements Exception {
  AcpError(this.code, this.message);
  final int code;
  final String message;

  /// ACP's "authentication required".
  bool get authRequired => code == -32000;

  /// No such session (older versions answered -32603 "Failed to read session").
  bool get notFound => code == -32002 || message.contains('not found') || message.startsWith('Failed to read session');

  @override
  String toString() => 'antigravity error $code: $message';
}
