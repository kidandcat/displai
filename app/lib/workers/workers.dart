import 'dart:async';
import 'dart:convert';

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
    String Function(ModelChoice choice)? describe,
    ModelCatalog? Function(BrainProvider provider)? catalog,
  })  : limits = limits ?? ProviderLimits(),
        resolve = resolve ?? ((c) => c.resolve(null)),
        catalog = catalog ?? ((_) => null),
        describe = describe ?? ((c) => '${c.provider.label} · ${c.model}') {
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

  /// The model a choice runs on, as the workers panel shows it.
  final String Function(ModelChoice choice) describe;

  /// The models a provider's agent last reported (null: not known yet), to check the model the
  /// assistant asks for.
  final ModelCatalog? Function(BrainProvider provider) catalog;

  final _running = <int, _Worker>{};

  int get runningCount => _running.length;

  /// Ids of the running workers, oldest first.
  Iterable<int> get runningIds => _running.keys;

  static const _progressTool = McpTool(
    'report_progress',
    'Record a progress note of one or two sentences: what you did and what comes next (the user '
        'sees it on screen; the assistant reads it if the user asks how you are doing).',
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
- Call report_progress at each milestone with one or two sentences in the user's language: what you did and what comes next.
- Final report: first line is the outcome (done, partly done, or failed, and why). Then the key results, short and concrete (paths, numbers, links). Write it in ${speechLanguages[speechLanguage] ?? 'English'}, the user's language. Never invent results.
''';

  /// Each agent's own read-only file tools.
  static const _fileTools = {
    BrainProvider.claude: 'Read, Glob, Grep',
    BrainProvider.antigravity: 'view_file, grep_search, find_by_name',
    BrainProvider.codex: 'a read-only shell to look at files',
  };

  /// The Claude models the assistant can ask for by name, each the latest of its family.
  static const modelAliases = {
    'fable': 'claude-fable-5-1',
    'opus': 'claude-opus-5-5',
    'sonnet': 'claude-sonnet-5-5',
    'haiku': 'claude-haiku-5-5',
  };

  /// The model id [name] stands for: an alias of [modelAliases] or a full Claude id; null for
  /// anything else.
  static String? modelId(String name) {
    final n = name.trim().toLowerCase();
    return modelAliases[n] ?? (n.startsWith('claude-') ? n : null);
  }

  /// The providers the assistant can ask a worker to run on, by name (Gemini runs on Antigravity).
  static const providerNames = {
    'claude': BrainProvider.claude,
    'antigravity': BrainProvider.antigravity,
    'agy': BrainProvider.antigravity,
    'gemini': BrainProvider.antigravity,
  };

  /// Antigravity's models (without their thinking level) while its catalog is not known yet; once
  /// it is, the catalog's own.
  static const _antigravityModels = [
    'gemini-4-neon',
    'gemini-4-carbon',
    'gemini-4-argon',
    'gemini-4-hydrogen',
    'gemini-3.8-flash',
  ];

  /// The thinking level of an Antigravity model asked for without one ("gemini neon").
  static const antigravityLevel = 'high';

  static final _level = RegExp(r'-(low|medium|high|xhigh|max)$');

  /// [name] on Antigravity: a model id with or without its thinking level (gemini-4-neon-high,
  /// gemini-4-neon) or a short name ("Gemini Neon", "neon xhigh", "flash"; plain "gemini" is its
  /// default model), at [antigravityLevel] when it names none. Null when [catalog] (or, before it
  /// is known, [_antigravityModels]) has no such model.
  static ModelChoice? antigravityModel(String name, {ModelCatalog? catalog}) {
    final n = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9.]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final m = _level.firstMatch(n) ?? RegExp(r'^(low|medium|high|xhigh|max)$').firstMatch(n);
    var base = m == null ? n : n.substring(0, m.start);
    if (_short(base).isEmpty) base = antigravityWorkerModel.model;
    final listed = [for (final x in catalog?.all ?? const <BrainModel>[]) x.value];
    final known = listed.isEmpty ? _antigravityModels : listed;
    final found = known.contains(base) ? base : known.where((v) => _short(v) == _short(base)).firstOrNull;
    if (found == null) return null;
    return ModelChoice(provider: BrainProvider.antigravity, model: found, effort: m?[1] ?? antigravityLevel);
  }

  /// A model id without `gemini-` and its version: `gemini-4-neon` is `neon`.
  static String _short(String id) =>
      id.replaceFirst(RegExp(r'^gemini(-|$)'), '').replaceFirst(RegExp(r'^\d+(\.\d+)?(-|$)'), '');

  static const _providerProperty = {
    'type': 'string',
    'enum': ['claude', 'antigravity'],
    'description': 'Optional, only when the user asks for a provider or a model (e.g. "con Gemini", "con '
        'Antigravity"): claude (Claude Code) or antigravity (Google Antigravity CLI, Gemini models, on '
        'the user\'s subscription). Left out: the provider of model, else the workers\' settings.',
  };

  static const _modelProperty = {
    'type': 'string',
    'description': 'Optional, only when the user explicitly asks for a model (e.g. "con Fable", "con '
        'Gemini Neon"). Claude: fable, opus, sonnet or haiku (the latest of each), or a full id such as '
        'claude-fable-5-1, claude-opus-5-5, claude-sonnet-5-5 or claude-haiku-5-5. Antigravity: a Gemini '
        'id such as gemini-4-neon-high, gemini-4-neon-xhigh, gemini-4-carbon-high, gemini-4-argon-high, '
        'gemini-4-hydrogen-high or gemini-3.8-flash-high (the suffix is the thinking level: low, medium, '
        'high, xhigh where the model has it), or a short name such as "gemini neon" or "gemini flash" '
        '(at high). Otherwise leave it out: the worker runs on the workers\' model in settings (with '
        'provider alone, on that provider\'s).',
  };

  @override
  final List<McpTool> tools = const [
    McpTool(
      'start_worker',
      'Start a background worker for long work (research, coding, many steps, anything over a '
          'minute or two). It is a separate AI session with commands, files, the web and read-only '
          'memories, but no display and no mouse or keyboard. Give it a complete, self-contained '
          'task: goal, context, constraints and what a finished result looks like. Returns its id. '
          'When it finishes you get a "[worker" message with its report. Starting it takes Minerva '
          'back to its idle screen (the view on screen is cleared).',
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
          'provider': _providerProperty,
          'model': _modelProperty,
        },
        'required': ['title', 'task'],
      },
    ),
    McpTool(
      'list_workers',
      'List running workers and the latest finished ones (id, title, status, provider and model, last '
          'progress note).',
      {'type': 'object', 'properties': {}},
    ),
    McpTool(
      'worker_status',
      'Status, provider and model, latest progress note and (when finished) the full report of a worker.',
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
          'finished (it keeps its whole context). With provider and/or model, a finished worker goes '
          'on on that model (on another provider it starts over there from its task, report and this '
          'message).',
      {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
          'text': {'type': 'string'},
          'provider': _providerProperty,
          'model': _modelProperty,
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
    final (asked, error) =
        _asked((args['provider'] as String? ?? '').trim(), (args['model'] as String? ?? '').trim());
    if (error != null) return ToolResult.error(error);
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
        final wid = await start(title, task, cwd: cwd, choice: asked);
        return ToolResult('started worker $wid on ${_model(wid)}${cwd == null ? '' : ' in $cwd'}');
      case 'list_workers':
        return ToolResult(_list());
      case 'worker_status':
        if (id == null) return const ToolResult.error('error: id is required');
        return _status(id);
      case 'message_worker':
        if (id == null) return const ToolResult.error('error: id is required');
        return _message(id, (args['text'] as String? ?? '').trim(), asked: asked);
      case 'stop_worker':
        if (id == null) return const ToolResult.error('error: id is required');
        return stop(id) ? ToolResult('stopped worker $id') : ToolResult.error('error: worker $id is not running');
    }
    return ToolResult.error('error: unknown tool $name');
  }

  /// The choice the assistant asked for with [provider] and [model] (each optional, the model
  /// checked on its provider), else an error for it; (null, null) when it asked for neither.
  (ModelChoice?, String?) _asked(String provider, String model) {
    BrainProvider? p;
    if (provider.isNotEmpty) {
      p = providerNames[provider.toLowerCase()];
      if (p == null) return (null, 'error: unknown provider "$provider". Providers: claude, antigravity');
    }
    if (p == null && model.isEmpty) return (null, null);
    ModelChoice? c;
    if (p == BrainProvider.claude || p == null && modelId(model) != null) {
      final id = model.isEmpty ? null : modelId(model);
      if (model.isNotEmpty && id == null) return (null, 'error: unknown Claude model "$model". $_claudeModels');
      c = _workersChoice(BrainProvider.claude);
      if (id != null) c = c.copyWith(model: id);
    } else if (p == BrainProvider.antigravity || p == null) {
      final ac = catalog(BrainProvider.antigravity);
      c = model.isEmpty
          ? chain.where((c) => c.provider == BrainProvider.antigravity).firstOrNull ??
              antigravityModel('', catalog: ac) ??
              defaultModel(BrainProvider.antigravity, workers: true, catalog: ac)
          : antigravityModel(model, catalog: ac);
      if (c == null) {
        return (
          null,
          p == null
              ? 'error: unknown model "$model". Claude: $_claudeModels. Antigravity: ${_antigravityHint()}'
              : 'error: unknown Antigravity model "$model". ${_antigravityHint()}',
        );
      }
    } else {
      return (null, 'error: provider ${p.name} can\'t be asked for. Providers: claude, antigravity');
    }
    if (unavailable.contains(c.provider)) {
      return (null, 'error: ${c.provider.label} is not available on this Mac (${c.provider.agent} missing or '
          'not signed in)');
    }
    return (c, null);
  }

  static final _claudeModels = 'Models: ${modelAliases.keys.join(', ')}, or a full id such as '
      '${modelAliases.values.join(', ')}';

  /// Antigravity's models, for an error.
  String _antigravityHint() {
    final listed = catalog(BrainProvider.antigravity)?.all ?? const <BrainModel>[];
    final models = listed.isEmpty
        ? _antigravityModels
        : [for (final m in listed) m.efforts.isEmpty ? m.value : '${m.value}-{${m.efforts.join(',')}}'];
    return 'Models: ${models.join(', ')} (a thinking level suffix such as -high where the model has '
        'levels), or a short name such as "gemini neon"';
  }

  /// The workers' choice on [provider] (its model, effort and speed in settings), else that
  /// provider's default.
  ModelChoice _workersChoice(BrainProvider provider) =>
      chain.where((c) => c.provider == provider).firstOrNull ?? defaultModel(provider, workers: true);

  /// Starts a worker on [task], in the folder [cwd] (a project) or else the workers' own, on
  /// [choice] (with the workers' backups on other providers) or else the workers' model.
  Future<int> start(String title, String task, {String? cwd, ModelChoice? choice}) async {
    final pinned = choice;
    final chain = _chainFor(pinned);
    final picked = limits.pick(chain, unavailable: unavailable);
    final sessionId = _newStoredId(picked.provider);
    store.db.execute(
      'INSERT INTO workers(title, task, status, session_id, started, cwd, choice) '
      "VALUES (?, ?, 'running', ?, ?, ?, ?)",
      [title, task, sessionId, Store.now(), cwd, pinned == null ? null : jsonEncode(pinned.toJson())],
    );
    final id = store.db.lastInsertRowId;
    await _launch(id, title, sessionId, task, cwd: cwd, choice: picked, chain: chain, handoff: task);
    return id;
  }

  /// What a worker runs on: [pinned] (the model the assistant asked for) with the workers'
  /// backups on other providers, else the workers' chain.
  List<ModelChoice> _chainFor(ModelChoice? pinned) => pinned == null ? chain : fallbackChain(pinned, chain);

  /// The model worker [id] runs on, as the panel shows it.
  String _model(int id) =>
      store.db.select('SELECT model FROM workers WHERE id = ?', [id]).firstOrNull?['model'] as String? ?? '?';

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

  /// Runs [text] in the worker's session [storedId] on [choice], the first usable of [chain].
  /// [handoff] is what to start from on the next of [chain] if this one is out; [tried]:
  /// providers it was on before.
  Future<void> _launch(int id, String title, String storedId, String text,
      {required String? cwd,
      required ModelChoice choice,
      required List<ModelChoice> chain,
      required String handoff,
      Set<BrainProvider> tried = const {}}) async {
    final (provider, sessionId) = _parseStoredId(storedId);
    final run = resolve(choice);
    store.db.execute('UPDATE workers SET model = ? WHERE id = ?', [describe(choice), id]);
    final w = _Worker(id, title, provider, cwd, chain, handoff, tried);
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
    final to = limits.next(w.chain, w.provider, unavailable: {...unavailable, ...tried});
    if (to == null || _running[w.id] != w) return false;
    _running.remove(w.id);
    unawaited(w.dispose());
    final stored = _newStoredId(to.provider);
    final note = '${w.provider.label} is out (usage limit or sign-in): moved to ${to.provider.label}';
    store.db.execute('UPDATE workers SET session_id = ?, progress = ? WHERE id = ?', [stored, note, w.id]);
    unawaited(_launch(w.id, w.title, stored,
        '[note] This work was on ${w.provider.agent}, which is out; nothing of it carries over. '
        'Do it here from the start.\n\n${w.handoff}',
        cwd: w.cwd, choice: to, chain: w.chain, handoff: w.handoff, tried: tried));
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

  /// Sends [text] to worker [id]; a finished one goes on on [asked] when given, else on the model
  /// it was on.
  Future<ToolResult> _message(int id, String text, {ModelChoice? asked}) async {
    if (text.isEmpty) return const ToolResult.error('error: empty text');
    final running = _running[id];
    if (running != null && asked != null) {
      return ToolResult.error('error: worker $id is running; its model can change once it finished '
          '(send without model, or stop it first)');
    }
    if (running != null) {
      // The agent answers it within the current turn or after it.
      running.sent++;
      running.handoff = '${running.handoff}\n\nFollow-up from the assistant: $text';
      await running.session.send(text);
      return ToolResult('sent to worker $id');
    }
    final rows =
        store.db.select('SELECT title, task, result, session_id, cwd, choice FROM workers WHERE id = ?', [id]);
    if (rows.isEmpty) return ToolResult.error('error: no worker $id');
    final r = rows.first;
    var pinned = r['choice'] == null ? null : ModelChoice.fromJson(jsonDecode(r['choice'] as String));
    if (asked != null) {
      pinned = asked;
      store.db.execute('UPDATE workers SET choice = ? WHERE id = ?', [jsonEncode(pinned.toJson()), id]);
    }
    store.db.execute("UPDATE workers SET status = 'running', finished = NULL WHERE id = ?", [id]);
    final chain = _chainFor(pinned);
    var stored = r['session_id'] as String;
    final (was, _) = _parseStoredId(stored);
    final handoff = [
      'Your task: ${r['task']}',
      if (r['result'] != null) 'Your report then:\n${r['result']}',
      'New message from the assistant: $text',
    ].join('\n\n');
    // Resumed on the provider it was on, with that provider's choice in its chain, else its
    // default model; a model asked for on another provider starts over there from the handoff.
    var choice = chain.where((c) => c.provider == was).firstOrNull ?? defaultModel(was, workers: true);
    var send = text;
    if (asked != null && asked.provider != was) {
      choice = asked;
      stored = _newStoredId(choice.provider);
      store.db.execute('UPDATE workers SET session_id = ? WHERE id = ?', [stored, id]);
      send = '[note] This work was on ${was.agent}; nothing of it carries over. Go on here from what '
          'follows.\n\n$handoff';
    }
    await _launch(id, r['title'] as String, stored, send,
        cwd: r['cwd'] as String?, choice: choice, chain: chain, handoff: handoff);
    return ToolResult('worker $id resumed with the new message on ${_model(id)}');
  }

  /// The workers the panel shows: the running ones, then the ones that finished in the last
  /// [recent], newest first, at most [limit].
  List<WorkerInfo> board({Duration recent = const Duration(minutes: 15), int limit = 6}) {
    final rows = store.db.select(
      'SELECT id, title, status, started, finished, model, cwd, progress, result FROM workers '
      "WHERE status = 'running' OR finished >= ? ORDER BY status = 'running' DESC, id DESC LIMIT ?",
      [Store.now() - recent.inMilliseconds, limit],
    );
    return [
      for (final r in rows)
        WorkerInfo(
          id: r['id'] as int,
          title: r['title'] as String,
          status: r['status'] as String,
          started: DateTime.fromMillisecondsSinceEpoch(r['started'] as int),
          finished: r['finished'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['finished'] as int),
          model: r['model'] as String?,
          project: r['cwd'] == null ? null : projects.label(r['cwd'] as String),
          progress: r['progress'] as String?,
          result: r['result'] as String?,
        ),
    ];
  }

  /// The projects the projects panel shows, the most recently active first (its latest worker's
  /// start or end, else when its folder last changed), at most [limit], each with that worker.
  List<ProjectInfo> projectsBoard({int limit = 6}) {
    final last = <String, WorkerInfo>{};
    final rows = store.db.select(
      'SELECT id, title, status, started, finished, model, cwd, progress, result FROM workers '
      'WHERE id IN (SELECT MAX(id) FROM workers WHERE cwd LIKE ? GROUP BY cwd)',
      ['${projects.dir}/%'],
    );
    for (final r in rows) {
      last[r['cwd'] as String] = WorkerInfo(
        id: r['id'] as int,
        title: r['title'] as String,
        status: r['status'] as String,
        started: DateTime.fromMillisecondsSinceEpoch(r['started'] as int),
        finished: r['finished'] == null ? null : DateTime.fromMillisecondsSinceEpoch(r['finished'] as int),
        model: r['model'] as String?,
        project: projects.label(r['cwd'] as String),
        progress: r['progress'] as String?,
        result: r['result'] as String?,
      );
    }
    final out = [
      for (final p in projects.list())
        ProjectInfo(
          name: p.name,
          summary: p.summary,
          modified: Projects.modified('${projects.dir}/${p.name}'),
          worker: last['${projects.dir}/${p.name}'],
        ),
    ]..sort((a, b) => b.active.compareTo(a.active));
    return out.take(limit).toList();
  }

  String _list() {
    final rows = store.db.select(
      "SELECT id, title, status, model, progress, cwd FROM workers WHERE status = 'running' "
      'OR id IN (SELECT id FROM workers ORDER BY id DESC LIMIT 8) ORDER BY id DESC',
    );
    if (rows.isEmpty) return 'no workers';
    return rows
        .map((r) => '${r['id']} «${r['title']}» ${r['status']}'
            '${r['model'] == null ? '' : ' on ${r['model']}'}'
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
      if (r['model'] != null) 'model: ${r['model']}',
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

/// A worker as the workers panel shows it.
class WorkerInfo {
  const WorkerInfo({
    required this.id,
    required this.title,
    required this.status,
    required this.started,
    this.finished,
    this.model,
    this.project,
    this.progress,
    this.result,
  });

  final int id;
  final String title;

  /// 'running', 'done', 'failed', 'stopped' or 'interrupted' (the app closed while it ran).
  final String status;
  final DateTime started;
  final DateTime? finished;

  /// The model it runs on (null: started before that was kept).
  final String? model;

  /// Its project, or the folder it works in (null: the workers' own).
  final String? project;

  /// Its latest progress note, and its report once finished.
  final String? progress;
  final String? result;

  bool get running => status == 'running';

  /// How long it has been running, or ran.
  Duration elapsed(DateTime now) => (running ? now : finished ?? now).difference(started);

  /// What it is at, for the panel: the latest progress note while it runs; once it finished, the
  /// first line of its report (the outcome), else that note.
  String? get latest {
    if (!running) {
      final outcome = result?.trim().split('\n').first.replaceAll('**', '').replaceFirst(RegExp(r'^#+'), '').trim();
      if (outcome != null && outcome.isNotEmpty) return outcome;
    }
    final p = progress?.trim();
    return p == null || p.isEmpty ? null : p;
  }
}

/// A project as the projects panel shows it.
class ProjectInfo {
  const ProjectInfo({required this.name, required this.summary, required this.modified, this.worker});

  final String name;

  /// The first line of its README.md.
  final String summary;

  /// When its folder last changed.
  final DateTime modified;

  /// Its latest worker (null: none ever ran in it).
  final WorkerInfo? worker;

  /// When it last saw activity: its worker running now, else the latest of the worker's end and
  /// the folder's change.
  DateTime get active {
    final w = worker;
    if (w == null) return modified;
    final at = w.running ? DateTime.now() : w.finished ?? w.started;
    return at.isAfter(modified) ? at : modified;
  }
}

class _Worker {
  _Worker(this.id, this.title, this.provider, this.cwd, this.chain, this.handoff, this.tried);

  final int id;
  final String title;
  final BrainProvider provider;
  final String? cwd;

  /// What it runs on, then its backups.
  final List<ModelChoice> chain;

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
