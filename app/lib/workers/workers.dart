import 'dart:async';

import 'package:flutter/foundation.dart';

import '../brain/claude_session.dart';
import '../l10n/l10n.dart';
import '../mcp/display_mcp_server.dart';
import '../store/store.dart';
import '../tools/tool_provider.dart';

/// Background workers: each one is its own headless Claude Code session doing a long task
/// (research, coding, many steps) while the voice assistant keeps talking with the user.
///
/// A worker gets Minerva's host tools (commands and files, read-only memories, history and
/// skills) from its own MCP endpoint, but no display and no mouse or keyboard: it must not fight
/// the user for the screen. Nothing asks the user for confirmation: the worker prompt keeps
/// destructive actions to tasks that clearly ask for them. When it finishes, its report is
/// handed to the main brain through [notify].
class Workers extends ToolProvider with ChangeNotifier {
  Workers({
    required this.store,
    required this.hostTools,
    required this.notify,
    this.scrub,
    this.model = 'opus',
    this.effort = 'medium',
  }) {
    // Workers that were running when the app closed are gone; message_worker resumes them.
    store.db.execute("UPDATE workers SET status = 'interrupted' WHERE status = 'running'");
  }

  final Store store;

  /// Tools served to workers (host tools; no display, no computer use).
  final List<ToolProvider> hostTools;

  /// Hands a message to the main brain (queued until it is free).
  final void Function(String text) notify;

  /// Applied to every tool result a worker gets (the vault's redaction).
  final ToolResult Function(ToolResult result)? scrub;
  final String model;
  final String effort;

  final _running = <int, _Worker>{};

  int get runningCount => _running.length;

  static const _builtins = ['Read', 'Glob', 'Grep', 'WebSearch', 'WebFetch'];

  static const _progressTool = McpTool(
    'report_progress',
    'Record a one-line progress note (the assistant can read it if the user asks how you are doing).',
    {
      'type': 'object',
      'properties': {
        'note': {'type': 'string'},
      },
      'required': ['note'],
    },
  );

  /// The user's language is the OS one the voice speaks (see `speechLanguage` in l10n.dart).
  static String get _systemPrompt => '''
You are a background worker of Minerva, a voice assistant on the user's Mac. The assistant gave you a task; do it fully on your own. Nobody reads your messages while you work. Your final message is your report: the assistant reads it and tells the user by voice.

- Use Minerva's tools for commands and files (run_command, read_file, write_file, list_dir), plus Read, Glob, Grep and the web. You have no screen and no mouse or keyboard.
- Nobody confirms anything: your tools run at once. Do destructive actions (deleting files or data, sending messages or emails, buying or paying, publishing, overwriting, irreversible commands) only when the task clearly asks for them. Otherwise do not do them: say in your report what you would do, and let the assistant ask the user.
- Credentials: vault_list shows the saved ones; write {{vault:name.field}} where a value goes in run_command or write_file (Minerva fills it in; you never see values). If one is missing, say so in your report.
- Call report_progress at each milestone with a one-line note.
- Final report: first line is the outcome (done, partly done, or failed, and why). Then the key results, short and concrete (paths, numbers, links). Write it in ${speechLanguages[speechLanguage] ?? 'English'}, the user's language. Never invent results.
''';

  @override
  final List<McpTool> tools = const [
    McpTool(
      'start_worker',
      'Start a background worker for long work (research, coding, many steps, anything over a '
          'minute or two). It is a separate AI session with commands, files, the web and read-only '
          'memories, but no display and no mouse or keyboard. Give it a complete, self-contained '
          'task: goal, context, constraints and what a finished result looks like. Returns its id. '
          'When it finishes you get a "[worker" message with its report.',
      {
        'type': 'object',
        'properties': {
          'title': {'type': 'string', 'description': 'A few words, in the user\'s language, for the user.'},
          'task': {'type': 'string'},
        },
        'required': ['title', 'task'],
      },
    ),
    McpTool(
      'list_workers',
      'List running workers and the latest finished ones (id, title, status, last progress note).',
      {'type': 'object', 'properties': {}},
    ),
    McpTool(
      'worker_status',
      'Status, latest progress note and (when finished) the full report of a worker.',
      {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
        },
        'required': ['id'],
      },
    ),
    McpTool(
      'message_worker',
      'Send a follow-up to a worker: new instructions while it runs, or more work after it '
          'finished (it keeps its whole context).',
      {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
          'text': {'type': 'string'},
        },
        'required': ['id', 'text'],
      },
    ),
    McpTool(
      'stop_worker',
      'Stop a running worker.',
      {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
        },
        'required': ['id'],
      },
    ),
  ];

  @override
  Future<ToolResult> call(String name, Map<String, dynamic> args) async {
    final id = (args['id'] as num?)?.toInt();
    switch (name) {
      case 'start_worker':
        final title = (args['title'] as String? ?? '').trim();
        final task = (args['task'] as String? ?? '').trim();
        if (title.isEmpty || task.isEmpty) return const ToolResult.error('error: title and task are required');
        final wid = await start(title, task);
        return ToolResult('started worker $wid');
      case 'list_workers':
        return ToolResult(_list());
      case 'worker_status':
        if (id == null) return const ToolResult.error('error: id is required');
        return _status(id);
      case 'message_worker':
        if (id == null) return const ToolResult.error('error: id is required');
        return _message(id, (args['text'] as String? ?? '').trim());
      case 'stop_worker':
        if (id == null) return const ToolResult.error('error: id is required');
        return stop(id) ? ToolResult('stopped worker $id') : ToolResult.error('error: worker $id is not running');
    }
    return ToolResult.error('error: unknown tool $name');
  }

  Future<int> start(String title, String task) async {
    final sessionId = ClaudeSession.newSessionId();
    store.db.execute(
      "INSERT INTO workers(title, task, status, session_id, started) VALUES (?, ?, 'running', ?, ?)",
      [title, task, sessionId, Store.now()],
    );
    final id = store.db.lastInsertRowId;
    await _launch(id, title, sessionId, task);
    return id;
  }

  Future<void> _launch(int id, String title, String sessionId, String text) async {
    final w = _Worker(id, title);
    final mcp = DisplayMcpServer(
      tools: [for (final p in hostTools) ...p.tools, _progressTool],
      handler: (name, args) => _handle(w, name, args),
    );
    await mcp.start();
    final session = ClaudeSession(
      model: model,
      effort: effort,
      systemPrompt: _systemPrompt,
      mcpUrl: mcp.url,
      workDir: '${store.dir}/workers',
      sessionId: sessionId,
      builtinTools: _builtins,
      autocompact: '200k',
      replayUserMessages: true,
    );
    w
      ..mcp = mcp
      ..session = session
      ..sub = session.events.listen((e) {
        // A follow-up sent mid-run is either folded into the running turn or gets its own:
        // finish on the first turn end after Claude Code took every message sent.
        if (e is MessageTaken) w.taken++;
        if (e is TurnDone && (w.taken >= w.sent || e.error != null || e.interrupted)) _finished(w, e);
      });
    _running[id] = w;
    notifyListeners();
    try {
      await session.start();
      w.sent++;
      await session.send(text);
    } catch (e) {
      _finished(w, TurnDone(interrupted: false, error: '$e'));
    }
  }

  Future<ToolResult> _handle(_Worker w, String name, Map<String, dynamic> args) async {
    if (name == _progressTool.name) {
      final note = (args['note'] as String? ?? '').trim();
      store.db.execute('UPDATE workers SET progress = ? WHERE id = ?', [note, w.id]);
      notifyListeners();
      return const ToolResult('ok');
    }
    for (final p in hostTools) {
      if (p.handles(name)) {
        final r = await p.call(name, args);
        return scrub?.call(r) ?? r;
      }
    }
    return ToolResult.error('error: unknown tool $name');
  }

  void _finished(_Worker w, TurnDone e) {
    if (_running.remove(w.id) == null) return;
    unawaited(w.dispose());
    final status = w.stopped || e.interrupted ? 'stopped' : (e.error != null ? 'failed' : 'done');
    final result = e.error ?? e.result;
    store.db.execute('UPDATE workers SET status = ?, finished = ?, result = ? WHERE id = ?',
        [status, Store.now(), result, w.id]);
    notifyListeners();
    if (status == 'stopped') return;
    notify('[worker ${w.id} «${w.title}» ${status == 'done' ? 'finished' : 'failed'}]\n$result\n'
        '(Tell the user briefly; show it on the display if it helps.)');
  }

  bool stop(int id) {
    final w = _running[id];
    if (w == null) return false;
    w.stopped = true;
    _finished(w, TurnDone(interrupted: true));
    return true;
  }

  Future<ToolResult> _message(int id, String text) async {
    if (text.isEmpty) return const ToolResult.error('error: empty text');
    final running = _running[id];
    if (running != null) {
      // Claude Code queues it and answers it after the current turn.
      running.sent++;
      await running.session.send(text);
      return ToolResult('sent to worker $id');
    }
    final rows = store.db.select('SELECT title, session_id FROM workers WHERE id = ?', [id]);
    if (rows.isEmpty) return ToolResult.error('error: no worker $id');
    store.db.execute("UPDATE workers SET status = 'running', finished = NULL WHERE id = ?", [id]);
    await _launch(id, rows.first['title'] as String, rows.first['session_id'] as String, text);
    return ToolResult('worker $id resumed with the new message');
  }

  String _list() {
    final rows = store.db.select(
      "SELECT id, title, status, progress FROM workers WHERE status = 'running' "
      'OR id IN (SELECT id FROM workers ORDER BY id DESC LIMIT 8) ORDER BY id DESC',
    );
    if (rows.isEmpty) return 'no workers';
    return rows
        .map((r) => '${r['id']} «${r['title']}» ${r['status']}'
            '${r['progress'] == null ? '' : ' — ${r['progress']}'}')
        .join('\n');
  }

  ToolResult _status(int id) {
    final rows = store.db.select('SELECT * FROM workers WHERE id = ?', [id]);
    if (rows.isEmpty) return ToolResult.error('error: no worker $id');
    final r = rows.first;
    final started = DateTime.fromMillisecondsSinceEpoch(r['started'] as int);
    final mins = DateTime.now().difference(started).inMinutes;
    return ToolResult([
      'worker $id «${r['title']}»: ${r['status']} (started $mins min ago)',
      if (r['progress'] != null) 'progress: ${r['progress']}',
      if (r['result'] != null) 'report:\n${r['result']}',
    ].join('\n'));
  }

  @override
  void dispose() {
    for (final w in _running.values) {
      unawaited(w.dispose());
    }
    _running.clear();
    super.dispose();
  }
}

class _Worker {
  _Worker(this.id, this.title);

  final int id;
  final String title;
  late final DisplayMcpServer mcp;
  late final ClaudeSession session;
  late final StreamSubscription<BrainEvent> sub;
  bool stopped = false;

  /// Messages sent to the session, and how many of them Claude Code has taken in.
  int sent = 0;
  int taken = 0;

  Future<void> dispose() async {
    await sub.cancel();
    session.dispose();
    await mcp.stop();
  }
}
