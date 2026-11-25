import 'dart:async';

import 'package:flutter/foundation.dart';

import '../brain/brain_session.dart';
import '../brain/claude_session.dart';
import '../brain/fallback.dart';
import '../brain/models.dart';
import '../l10n/l10n.dart';
import '../mcp/display_mcp_server.dart';
import '../projects/projects.dart';
import '../store/store.dart';
import '../tools/tool_provider.dart';

/// Background workers: each one is its own headless agent session (Claude Code, Antigravity or
/// Codex) doing a long task (research, coding, many steps) while the voice assistant keeps
/// talking with the user.
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
    required this.projects,
    required this.notify,
    this.scrub,
    ProviderLimits? limits,
    this.unavailable = const {},
    ({String model, String? effort, bool fast}) Function(ModelChoice choice)? resolve,
  })  : limits = limits ?? ProviderLimits(),
        resolve = resolve ?? ((c) => c.resolve(null)) {
    // Workers that were running when the app closed are gone; message_worker resumes them.
    store.db.execute("UPDATE workers SET status = 'interrupted' WHERE status = 'running'");
  }

  final Store store;

  /// Tools served to workers (host tools; no display, no computer use).
  final List<ToolProvider> hostTools;

  /// Folders a worker can start in, with their main doc as context.
  final Projects projects;

  /// Hands a message to the main brain (queued until it is free).
  final void Function(String text) notify;

  /// Applied to every tool result a worker gets (the vault's redaction).
  final ToolResult Function(ToolResult result)? scrub;
  /// The workers' model then its backups, in order: a worker starts on the first whose provider
  /// is not out, and moves to the next when its own hits a usage limit. A worker resumed later
  /// goes on with the provider it was on (its conversation is that provider's).
  List<ModelChoice> chain = [defaultWorkerModel];

  /// Providers out for now (shared with the conversation) and the ones not installed.
  final ProviderLimits limits;
  final Set<BrainProvider> unavailable;

  /// The model, effort and speed a choice runs with (from its provider's catalog).
  final ({String model, String? effort, bool fast}) Function(ModelChoice choice) resolve;

  final _running = <int, _Worker>{};

  int get runningCount => _running.length;

  /// Ids of the running workers, oldest first.
  Iterable<int> get runningIds => _running.keys;

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
  static String _systemPrompt(BrainProvider provider) => '''
You are a background worker of Minerva, a voice assistant on the user's Mac. The assistant gave you a task; do it fully on your own. Nobody reads your messages while you work. Your final message is your report: the assistant reads it and tells the user by voice.

- Use Minerva's tools for commands and files (run_command, read_file, write_file, list_dir), plus ${_fileTools[provider]} and the web. You have no screen and no mouse or keyboard.
- Nobody confirms anything: your tools run at once. Do destructive actions (deleting files or data, sending messages or emails, buying or paying, publishing, overwriting, irreversible commands) only when the task clearly asks for them. Otherwise do not do them: say in your report what you would do, and let the assistant ask the user.
- Credentials: vault_list shows the saved ones; write {{vault:name.field}} where a value goes in run_command or write_file (Minerva fills it in; you never see values). If one is missing, say so in your report.
- Call report_progress at each milestone with a one-line note.
- Final report: first line is the outcome (done, partly done, or failed, and why). Then the key results, short and concrete (paths, numbers, links). Write it in ${speechLanguages[speechLanguage] ?? 'English'}, the user's language. Never invent results.
''';

  /// Each agent's own read-only file tools.
  static const _fileTools = {
    BrainProvider.claude: 'Read, Glob, Grep',
    BrainProvider.antigravity: 'view_file, grep_search, find_by_name',
    BrainProvider.codex: 'a read-only shell to look at files',
  };

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
          'project': {
            'type': 'string',
            'description': 'Optional: a project\'s name or a folder path. The worker starts in that '
                'folder with its README.md as context.',
          },
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
        final project = (args['project'] as String? ?? '').trim();
        final cwd = project.isEmpty ? null : projects.resolve(project);
        if (project.isNotEmpty && cwd == null) {
          return ToolResult.error('error: no project or folder "$project". Projects: '
              '${projects.list().map((p) => p.name).join(', ')}');
        }
        final wid = await start(title, task, cwd: cwd);
        return ToolResult('started worker $wid${cwd == null ? '' : ' in $cwd'}');
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

  /// Starts a worker on [task], in the folder [cwd] (a project) or else the workers' own.
  Future<int> start(String title, String task, {String? cwd}) async {
    final choice = limits.pick(chain, unavailable: unavailable);
    final sessionId = _newStoredId(choice.provider);
    store.db.execute(
      "INSERT INTO workers(title, task, status, session_id, started, cwd) VALUES (?, ?, 'running', ?, ?, ?)",
      [title, task, sessionId, Store.now(), cwd],
    );
    final id = store.db.lastInsertRowId;
    await _launch(id, title, sessionId, task, cwd: cwd, run: resolve(choice), handoff: task);
    return id;
  }

  /// The session_id of a new session: Claude Code takes the id it is given; Antigravity and Codex
  /// pick their own once started.
  static String _newStoredId(BrainProvider provider) =>
      provider == BrainProvider.claude ? ClaudeSession.newSessionId() : _storedId(provider, null);

  /// The workers table's session_id: Claude Code's id alone (as before there was a choice of
  /// provider), else `<provider>:<id>` (the id empty until the agent picked it).
  static String _storedId(BrainProvider provider, String? id) =>
      provider == BrainProvider.claude ? id! : '${provider.name}:${id ?? ''}';

  static (BrainProvider, String?) _parseStoredId(String stored) {
    for (final p in BrainProvider.values) {
      if (p != BrainProvider.claude && stored.startsWith('${p.name}:')) {
        final id = stored.substring(p.name.length + 1);
        return (p, id.isEmpty ? null : id);
      }
    }
    return (BrainProvider.claude, stored);
  }

  /// Runs [text] in the worker's session [storedId]. [handoff] is what to start from on another
  /// provider if this one is out; [tried]: providers it was on before.
  Future<void> _launch(int id, String title, String storedId, String text,
      {required String? cwd,
      required ({String model, String? effort, bool fast}) run,
      required String handoff,
      Set<BrainProvider> tried = const {}}) async {
    final (provider, sessionId) = _parseStoredId(storedId);
    final w = _Worker(id, title, provider, cwd, handoff, tried);
    final mcp = DisplayMcpServer(
      tools: [for (final p in hostTools) ...p.tools, _progressTool],
      handler: (name, args) => _handle(w, name, args),
    );
    await mcp.start();
    final session = BrainSession.create(
      provider: provider,
      model: run.model,
      effort: run.effort,
      fast: run.fast,
      // A project's doc is read again at each launch, so a resumed worker sees its latest version.
      systemPrompt: [_systemPrompt(provider), if (cwd != null) projects.workerSection(cwd)].join('\n'),
      mcpUrl: mcp.url,
      workDir: cwd ?? '${store.dir}/workers',
      sessionId: sessionId,
      onSessionId: (sid) =>
          store.db.execute('UPDATE workers SET session_id = ? WHERE id = ?', [_storedId(provider, sid), id]),
      fileTools: true,
      autocompact: '200k',
      replayUserMessages: true,
    );
    w
      ..mcp = mcp
      ..session = session
      ..sub = session.events.listen((e) {
        // A follow-up sent mid-run is either folded into the running turn or gets its own:
        // finish on the first turn end after the agent took every message sent.
        if (e is MessageTaken) w.taken++;
        if (e is TurnDone && (w.taken >= w.sent || e.error != null || e.interrupted)) _ended(w, e);
      });
    _running[id] = w;
    notifyListeners();
    try {
      await session.start();
      w.sent++;
      await session.send(text);
    } catch (e) {
      _ended(w, TurnDone(interrupted: false, error: '$e'));
    }
  }

  void _ended(_Worker w, TurnDone e) {
    if (!w.stopped && _fallBack(w, e)) return;
    _finished(w, e);
  }

  /// The worker's turn ended: its provider answered (any limit is over), or it is out (usage
  /// limit, signed out) and the worker starts over on the next of [chain] it has not been on.
  /// True when it did.
  bool _fallBack(_Worker w, TurnDone e) {
    final limit = e.limit;
    if (e.interrupted) return false;
    if (limit == null) {
      if (e.error == null) limits.clear(w.provider);
      return false;
    }
    limits.hit(w.provider, limit);
    final tried = {...w.tried, w.provider};
    final to = limits.next(chain, w.provider, unavailable: {...unavailable, ...tried});
    if (to == null || _running[w.id] != w) return false;
    _running.remove(w.id);
    unawaited(w.dispose());
    final stored = _newStoredId(to.provider);
    final note = '${w.provider.label} is out (usage limit or sign-in): moved to ${to.provider.label}';
    store.db.execute('UPDATE workers SET session_id = ?, progress = ? WHERE id = ?', [stored, note, w.id]);
    unawaited(_launch(w.id, w.title, stored,
        '[note] This work was on ${w.provider.agent}, which is out; nothing of it carries over. '
        'Do it here from the start.\n\n${w.handoff}',
        cwd: w.cwd, run: resolve(to), handoff: w.handoff, tried: tried));
    return true;
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
      // The agent answers it within the current turn or after it.
      running.sent++;
      running.handoff = '${running.handoff}\n\nFollow-up from the assistant: $text';
      await running.session.send(text);
      return ToolResult('sent to worker $id');
    }
    final rows = store.db.select('SELECT title, task, result, session_id, cwd FROM workers WHERE id = ?', [id]);
    if (rows.isEmpty) return ToolResult.error('error: no worker $id');
    store.db.execute("UPDATE workers SET status = 'running', finished = NULL WHERE id = ?", [id]);
    // Resumed on the provider it was on, with that provider's choice in the chain, else its
    // default model.
    final r = rows.first;
    final stored = r['session_id'] as String;
    final (was, _) = _parseStoredId(stored);
    final choice = chain.where((c) => c.provider == was).firstOrNull ?? defaultModel(was, workers: true);
    final handoff = [
      'Your task: ${r['task']}',
      if (r['result'] != null) 'Your report then:\n${r['result']}',
      'New message from the assistant: $text',
    ].join('\n\n');
    await _launch(id, r['title'] as String, stored, text,
        cwd: r['cwd'] as String?, run: resolve(choice), handoff: handoff);
    return ToolResult('worker $id resumed with the new message');
  }

  String _list() {
    final rows = store.db.select(
      "SELECT id, title, status, progress, cwd FROM workers WHERE status = 'running' "
      'OR id IN (SELECT id FROM workers ORDER BY id DESC LIMIT 8) ORDER BY id DESC',
    );
    if (rows.isEmpty) return 'no workers';
    return rows
        .map((r) => '${r['id']} «${r['title']}» ${r['status']}'
            '${r['cwd'] == null ? '' : ' (in ${r['cwd']})'}'
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
      if (r['cwd'] != null) 'folder: ${r['cwd']}',
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
  _Worker(this.id, this.title, this.provider, this.cwd, this.handoff, this.tried);

  final int id;
  final String title;
  final BrainProvider provider;
  final String? cwd;

  /// What it starts from on another provider (the task and what came after), and the providers
  /// it was on before this one.
  String handoff;
  final Set<BrainProvider> tried;

  late final DisplayMcpServer mcp;
  late final BrainSession session;
  late final StreamSubscription<BrainEvent> sub;
  bool stopped = false;

  /// Messages sent to the session, and how many of them the agent has taken in.
  int sent = 0;
  int taken = 0;

  Future<void> dispose() async {
    await sub.cancel();
    session.dispose();
    await mcp.stop();
  }
}
