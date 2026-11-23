import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Events from a Claude Code turn, as the app needs them.
sealed class BrainEvent {}

class TextDelta extends BrainEvent {
  TextDelta(this.text);
  final String text;
}

/// A tool call started streaming (name without the `mcp__displai__` prefix for display tools).
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

class TurnDone extends BrainEvent {
  TurnDone({required this.interrupted, this.error});
  final bool interrupted;
  final String? error;
}

/// A long-lived headless Claude Code process (stream-json in/out), kept warm between turns.
class ClaudeSession {
  ClaudeSession({
    required this.model,
    required this.systemPrompt,
    required this.mcpUrl,
    required this.workDir,
    this.effort = 'low',
  });

  final String model;
  final String systemPrompt;
  final String mcpUrl;
  final String workDir;
  final String effort;

  static const displayServer = 'displai';
  static const _prefix = 'mcp__${displayServer}__';

  final _events = StreamController<BrainEvent>.broadcast();
  Stream<BrainEvent> get events => _events.stream;

  Process? _proc;
  bool busy = false;
  bool _discard = false;
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
    final args = [
      '-p',
      '--input-format', 'stream-json',
      '--output-format', 'stream-json',
      '--include-partial-messages',
      '--verbose',
      '--append-system-prompt', systemPrompt,
      '--mcp-config', mcpConfig,
      '--strict-mcp-config',
      // Built-in tools: only web access. Display tools come from our MCP server.
      '--tools', 'WebSearch,WebFetch',
      '--allowedTools', 'mcp__$displayServer,WebSearch,WebFetch',
      '--setting-sources', '',
      '--no-session-persistence',
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
      if (busy) {
        busy = false;
        _events.add(TurnDone(interrupted: false, error: 'claude exited ($code): ${stderrTail.trim()}'));
      }
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
        _toolNames.clear();
        _toolJson.clear();
        final interrupted = _discard || ev['subtype'] == 'error_during_execution';
        _discard = false;
        final isError = ev['is_error'] == true && !interrupted;
        _events.add(TurnDone(interrupted: interrupted, error: isError ? '${ev['result'] ?? ev['subtype']}' : null));
    }
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
