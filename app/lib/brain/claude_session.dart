import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Events from a Claude Code turn, as the app needs them.
sealed class BrainEvent {}

class TextDelta extends BrainEvent {
  TextDelta(this.text);
  final String text;
}

/// A tool call started streaming (name without the `mcp__minerva__` prefix for display tools).
class ToolStart extends BrainEvent {
  ToolStart(this.index, this.name);
  final int index;
  final String name;
}

/// Accumulated (partial) JSON arguments of the tool call at [index].
class ToolInput extends BrainEvent {
  ToolInput(this.index, this.name, this.partialJson);
  final int index;
  final String name;
  final String partialJson;
}

/// Claude Code is compacting the conversation (true) or finished doing so (false).
class Compacting extends BrainEvent {
  Compacting(this.active);
  final bool active;
}

/// Claude Code took a message sent with [ClaudeSession.send] into the conversation, either as
/// a new turn or attached to the turn in progress (only with [ClaudeSession.replayUserMessages]).
class MessageTaken extends BrainEvent {}

class TurnDone extends BrainEvent {
  TurnDone({required this.interrupted, this.error, this.result = ''});
  final bool interrupted;
  final String? error;

  /// The turn's final text (what a worker reports back).
  final String result;
}

/// A long-lived headless Claude Code process (stream-json in/out), kept warm between turns.
///
/// The conversation is saved by Claude Code under [sessionId] and resumed on the next start, so
/// it survives restarts; Claude Code compacts it on its own when it reaches [autocompact] tokens.
class ClaudeSession {
  ClaudeSession({
    required this.model,
    required this.systemPrompt,
    required this.mcpUrl,
    required this.workDir,
    required this.sessionId,
    this.effort = 'low',
    this.builtinTools = const ['WebSearch', 'WebFetch'],
    this.autocompact = '100k',
    this.replayUserMessages = false,
  });

  final String model;
  final String systemPrompt;
  final String mcpUrl;
  final String workDir;
  final String effort;

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
  Stream<BrainEvent> get events => _events.stream;

  Process? _proc;
  bool busy = false;
  bool _discard = false;

  /// The message of the turn in progress, and whether it was already re-sent after a crash.
  String? _inFlight;
  bool _retried = false;
  final _toolNames = <int, String>{};
  final _toolJson = <int, StringBuffer>{};
  final _log = StringBuffer();

  /// Last stderr lines, for diagnostics.
  String get stderrTail => _log.toString();

  Future<void> start() async {
    final env = await _cleanEnvironment();
    final claude = await _which('claude', env['PATH']!);
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
      '--effort', effort,
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
  }

  bool get running => _proc != null;

  Future<void> send(String text) async {
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

  void interrupt() {
    if (!busy || _proc == null) return;
    _discard = true;
    _write({
      'type': 'control_request',
      'request_id': 'int-${DateTime.now().microsecondsSinceEpoch}',
      'request': {'subtype': 'interrupt'},
    });
  }

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
      case 'result':
        busy = false;
        _inFlight = null;
        _retried = false;
        _toolNames.clear();
        _toolJson.clear();
        final interrupted = _discard || ev['subtype'] == 'error_during_execution';
        _discard = false;
        final isError = ev['is_error'] == true && !interrupted;
        _events.add(TurnDone(
          interrupted: interrupted,
          error: isError ? '${ev['result'] ?? ev['subtype']}' : null,
          result: ev['result'] is String ? ev['result'] as String : '',
        ));
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

  /// The user's login-shell environment (so PATH finds `claude` from a GUI app), without
  /// variables inherited from a parent Claude Code session (effort, session ids, sockets).
  static Future<Map<String, String>> _cleanEnvironment() async {
    final shell = Platform.environment['SHELL'] ?? '/bin/zsh';
    final r = await Process.run(shell, ['-lc', 'env -0'], stdoutEncoding: utf8);
    final env = <String, String>{};
    for (final entry in (r.stdout as String).split('\x00')) {
      final i = entry.indexOf('=');
      if (i <= 0) continue;
      env[entry.substring(0, i)] = entry.substring(i + 1);
    }
    if (env.isEmpty) env.addAll(Platform.environment);
    env.removeWhere((k, _) => k.startsWith('CLAUDE') || k == 'CLAUDECODE' || k.startsWith('OPENBOT'));
    env['PATH'] ??= '/usr/bin:/bin:/usr/sbin:/sbin';
    return env;
  }

  static Future<String> _which(String cmd, String path) async {
    for (final dir in path.split(':')) {
      final f = File('$dir/$cmd');
      if (f.existsSync()) return f.path;
    }
    for (final dir in ['${Platform.environment['HOME']}/.local/bin', '/opt/homebrew/bin', '/usr/local/bin']) {
      final f = File('$dir/$cmd');
      if (f.existsSync()) return f.path;
    }
    throw StateError('`$cmd` not found. Install Claude Code and sign in first.');
  }
}
