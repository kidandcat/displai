import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'brain_session.dart';
import 'fallback.dart';
import 'models.dart';

/// A long-lived headless Claude Code process (stream-json in/out), kept warm between turns.
///
/// The conversation is saved by Claude Code under [sessionId] and resumed on the next start, so
/// it survives restarts; Claude Code compacts it on its own when it reaches [autocompact] tokens.
class ClaudeSession implements BrainSession {
  ClaudeSession({
    required this.model,
    required this.systemPrompt,
    required this.mcpUrl,
    required this.workDir,
    required this.sessionId,
    this.effort = 'low',
    this.fast = false,
    this.describe = false,
    this.builtinTools = const ['WebSearch', 'WebFetch'],
    this.autocompact = '100k',
    this.replayUserMessages = false,
  });

  /// Claude Code model (an alias such as `opus` or a full id), effort level (null: the
  /// model has none) and fast mode. Change them with [reconfigure].
  String model;
  String? effort;
  bool fast;

  final String systemPrompt;
  final String mcpUrl;
  final String workDir;

  /// Ask Claude Code, at every start, for its version and models (a [Described] event).
  final bool describe;

  /// Claude Code session id (a UUID). Resumed when Claude Code already has it on disk.
  final String sessionId;

  /// Claude Code built-in tools to allow, besides Minerva's MCP tools.
  final List<String> builtinTools;

  /// Context size that triggers Claude Code's auto-compaction (kept low: a smaller context
  /// answers faster, and voice latency matters more than recall; search_history covers the rest).
  final String autocompact;

  /// Emit [MessageTaken] for each sent message as Claude Code consumes it. A message sent while
  /// a turn runs may be folded into that turn instead of getting its own, so counting turns
  /// does not tell when all sent messages were answered.
  final bool replayUserMessages;

  static const displayServer = 'minerva';
  static const _prefix = 'mcp__${displayServer}__';

  final _events = StreamController<BrainEvent>.broadcast();
  @override
  Stream<BrainEvent> get events => _events.stream;

  Process? _proc;
  @override
  bool busy = false;
  bool _discard = false;
  Future<void>? _starting;

  /// [reconfigure] waits for the turn in progress to end.
  bool _restartPending = false;

  /// The message of the turn in progress, and whether it was already re-sent after a crash.
  String? _inFlight;
  bool _retried = false;

  /// The reset of a usage limit Claude Code said this turn hit (`DateTime(0)`: it did not say when).
  DateTime? _limitResets;
  final _toolNames = <int, String>{};
  final _toolJson = <int, StringBuffer>{};
  final _log = StringBuffer();

  @override
  String get stderrTail => _log.toString();

  /// Starts Claude Code, resuming [sessionId] if it exists. Concurrent calls share one start.
  @override
  Future<void> start() => _starting ??= _start().whenComplete(() => _starting = null);

  Future<void> _start() async {
    final env = await loginEnvironment();
    final claude = findExecutable('claude', env['PATH']!);
    if (claude == null) throw StateError('`claude` not found. Install Claude Code and sign in first.');
    await Directory(workDir).create(recursive: true);
    final mcpConfig = jsonEncode({
      'mcpServers': {
        displayServer: {'type': 'http', 'url': mcpUrl},
      },
    });
    final resume = sessionExists(sessionId);
    final args = [
      '-p',
      '--input-format', 'stream-json',
      '--output-format', 'stream-json',
      '--include-partial-messages',
      '--verbose',
      if (replayUserMessages) '--replay-user-messages',
      '--append-system-prompt', systemPrompt,
      '--mcp-config', mcpConfig,
      '--strict-mcp-config',
      // Built-in tools: only the ones given. Minerva's tools come from our MCP server.
      '--tools', builtinTools.join(','),
      '--allowedTools', ['mcp__$displayServer', ...builtinTools].join(','),
      '--setting-sources', '',
      if (resume) ...['--resume', sessionId] else ...['--session-id', sessionId],
      '--autocompact', autocompact,
      if (effort != null) ...['--effort', effort!],
      // Fast mode is opt-in for headless sessions; the account may still refuse it (see
      // [Described]).
      if (fast) ...['--settings', jsonEncode({'fastMode': true})],
      '--model', model,
    ];
    final p = await Process.start(claude, args, workingDirectory: workDir, environment: env,
        includeParentEnvironment: false);
    _proc = p;
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine);
    p.stderr.transform(utf8.decoder).listen((s) {
      _log.write(s);
      if (_log.length > 4000) {
        final tail = _log.toString().substring(_log.length - 2000);
        _log
          ..clear()
          ..write(tail);
      }
    });
    unawaited(p.exitCode.then((code) {
      if (_proc != p) return;
      _proc = null;
      if (!busy) return;
      final pending = _inFlight;
      if (pending != null && !_retried && !_discard) {
        // The process died mid-turn (killed, crashed): restart it, resuming the same
        // conversation, and send the turn again once before reporting an error.
        _retried = true;
        busy = false;
        unawaited(send(pending).catchError((Object e) {
          busy = false;
          _events.add(TurnDone(interrupted: false, error: 'claude restart failed: $e'));
        }));
        return;
      }
      busy = false;
      _inFlight = null;
      _retried = false;
      _events.add(TurnDone(interrupted: _discard, error: _discard ? null : 'claude exited ($code): ${stderrTail.trim()}'));
    }));
    if (describe) {
      _write({
        'type': 'control_request',
        'request_id': 'describe',
        'request': {'subtype': 'initialize'},
      });
    }
  }

  /// Switches the model, effort or fast mode. A running process is restarted on the same
  /// conversation ([sessionId] is resumed), at once when idle, else when the turn ends.
  @override
  void reconfigure({required String model, required String? effort, required bool fast}) {
    if (model == this.model && effort == this.effort && fast == this.fast) return;
    this.model = model;
    this.effort = effort;
    this.fast = fast;
    if (_proc == null && _starting == null) return;
    if (busy) {
      _restartPending = true;
    } else {
      _restart();
    }
  }

  void _restart() {
    _restartPending = false;
    final p = _proc;
    _proc = null; // its exit is then not taken for a crash
    p?.kill();
    unawaited(start().catchError((Object e) => _log.write('claude restart failed: $e\n')));
  }

  @override
  bool get running => _proc != null;

  @override
  Future<void> send(String text) async {
    if (_starting != null) await _starting;
    if (_proc == null) await start();
    // An interrupted turn closes within a few ms; wait for it so turns don't overlap.
    for (var i = 0; i < 100 && busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    busy = true;
    _discard = false;
    _inFlight = text;
    _write({
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    });
  }

  @override
  void interrupt() {
    if (!busy || _proc == null) return;
    _discard = true;
    _write({
      'type': 'control_request',
      'request_id': 'int-${DateTime.now().microsecondsSinceEpoch}',
      'request': {'subtype': 'interrupt'},
    });
  }

  @override
  void dispose() {
    _proc?.kill();
    _proc = null;
  }

  void _write(Map<String, Object?> msg) => _proc?.stdin.writeln(jsonEncode(msg));

  void _onLine(String line) {
    Map<String, dynamic> ev;
    try {
      ev = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (ev['type']) {
      case 'system' when ev['subtype'] == 'status':
        _events.add(Compacting(ev['status'] == 'compacting'));
      case 'user' when replayUserMessages && _hasText(ev):
        _events.add(MessageTaken());
      case 'stream_event':
        if (_discard) return;
        final e = ev['event'] as Map<String, dynamic>;
        final index = (e['index'] as int?) ?? 0;
        switch (e['type']) {
          case 'content_block_start':
            final block = e['content_block'] as Map<String, dynamic>;
            if (block['type'] == 'tool_use' || block['type'] == 'server_tool_use') {
              final name = _shortName(block['name'] as String);
              _toolNames[index] = name;
              _toolJson[index] = StringBuffer();
              _events.add(ToolStart(index, name));
            }
          case 'content_block_delta':
            final d = e['delta'] as Map<String, dynamic>;
            if (d['type'] == 'text_delta') {
              _events.add(TextDelta(d['text'] as String));
            } else if (d['type'] == 'input_json_delta' && _toolJson.containsKey(index)) {
              _toolJson[index]!.write(d['partial_json'] as String);
              _events.add(ToolInput(index, _toolNames[index]!, _toolJson[index].toString()));
            }
        }
      case 'rate_limit_event':
        // Claude Code says how the account's limits stand; "rejected" means this turn hit one.
        final info = ev['rate_limit_info'];
        if (info is! Map) return;
        final resets = info['resetsAt'];
        _limitResets = info['status'] == 'rejected'
            ? (resets is num ? DateTime.fromMillisecondsSinceEpoch(resets.toInt() * 1000) : DateTime(0))
            : null;
      case 'result':
        busy = false;
        _inFlight = null;
        _retried = false;
        _toolNames.clear();
        _toolJson.clear();
        final interrupted = _discard || ev['subtype'] == 'error_during_execution';
        _discard = false;
        final isError = ev['is_error'] == true && !interrupted;
        final resets = _limitResets;
        _limitResets = null;
        _events.add(TurnDone(
          interrupted: interrupted,
          error: isError ? '${ev['result'] ?? ev['subtype']}' : null,
          result: ev['result'] is String ? ev['result'] as String : '',
          limit: isError && resets != null
              ? ProviderLimit(LimitReason.usage, resetsAt: resets.year == 0 ? null : resets)
              : null,
        ));
        if (fast && ev['fast_mode_state'] is String) {
          _events.add(FastModeState(
              on: ev['fast_mode_state'] == 'on', reason: ev['fast_mode_disabled_reason'] as String?));
        }
        if (_restartPending) _restart();
      case 'control_response':
        final r = ev['response'];
        if (r is Map && r['request_id'] == 'describe' && r['subtype'] == 'success' && r['response'] is Map) {
          final info = (r['response'] as Map).cast<String, dynamic>();
          _events.add(Described(info, catalog: ModelCatalog.fromInfo(info)));
        }
    }
  }

  /// Whether Claude Code has a saved transcript for [id] (any project directory).
  static bool sessionExists(String id) {
    final root = Directory('${Platform.environment['HOME']}/.claude/projects');
    if (!root.existsSync()) return false;
    for (final d in root.listSync().whereType<Directory>()) {
      if (File('${d.path}/$id.jsonl').existsSync()) return true;
    }
    return false;
  }

  /// A random UUID v4 for a new session.
  static String newSessionId() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  static bool _hasText(Map<String, dynamic> ev) {
    final content = (ev['message'] as Map<String, dynamic>?)?['content'];
    if (content is String) return true;
    return content is List && content.any((b) => b is Map && b['type'] == 'text');
  }

  static String _shortName(String name) => name.startsWith(_prefix) ? name.substring(_prefix.length) : name;
}
