import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/app/projects_panel.dart';
import 'package:minerva/app/workers_panel.dart';
import 'package:minerva/brain/models.dart';
import 'package:minerva/l10n/l10n.dart';
import 'package:minerva/projects/projects.dart';
import 'package:minerva/store/store.dart';
import 'package:minerva/workers/workers.dart';

void main() {
  late Directory tmp;
  late Store store;
  late Workers workers;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('minerva-workers-test');
    store = Store.memory(tmp.path);
    workers = Workers(
      store: store,
      hostTools: const [],
      projects: Projects('${tmp.path}/projects', home: tmp.path),
      notify: (_) {},
    );
  });

  tearDown(() {
    workers.dispose();
    store.close();
    tmp.deleteSync(recursive: true);
  });

  void add(String title, String status,
      {required Duration ago, Duration? finishedAgo, String? model, String? cwd, String? progress, String? result}) {
    final now = Store.now();
    store.db.execute(
      'INSERT INTO workers(title, task, status, session_id, started, finished, model, cwd, progress, result) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        title, 'task', status, 's', now - ago.inMilliseconds,
        finishedAgo == null ? null : now - finishedAgo.inMilliseconds, model, cwd, progress, result,
      ],
    );
  }

  test('the board has the running workers first, then the recently finished', () {
    add('old', 'done', ago: const Duration(hours: 2), finishedAgo: const Duration(hours: 1));
    add('recent', 'done',
        ago: const Duration(minutes: 9),
        finishedAgo: const Duration(minutes: 2),
        progress: 'Writing the report.',
        result: '**Hecho**: tres fallos corregidos.\nDetalles…');
    add('busy', 'running',
        ago: const Duration(minutes: 4),
        model: 'Claude · Opus 5.5',
        cwd: '${tmp.path}/projects/Casa',
        progress: 'Read the plans. Now comparing quotes.');
    add('interrupted', 'interrupted', ago: const Duration(minutes: 3));

    final board = workers.board();
    expect(board.map((w) => w.title), ['busy', 'recent']);
    final busy = board.first;
    expect(busy.running, isTrue);
    expect(busy.model, 'Claude · Opus 5.5');
    expect(busy.project, 'Casa');
    expect(busy.latest, 'Read the plans. Now comparing quotes.');
    expect(busy.elapsed(DateTime.now()).inMinutes, 4);
    final recent = board.last;
    expect(recent.latest, 'Hecho: tres fallos corregidos.');
    expect(recent.elapsed(DateTime.now()).inMinutes, 7);
  });

  test('models asked for by name map to the latest ids; others are refused', () async {
    expect(Workers.modelId('Fable'), 'claude-fable-5-1');
    expect(Workers.modelId('opus'), 'claude-opus-5-5');
    expect(Workers.modelId('sonnet'), 'claude-sonnet-5-5');
    expect(Workers.modelId('haiku'), 'claude-haiku-5-5');
    expect(Workers.modelId('claude-haiku-5-5'), 'claude-haiku-5-5');
    expect(Workers.modelId('gpt-6'), isNull);
    final r = await workers.call('start_worker', {'title': 't', 'task': 'do it', 'model': 'gpt-6'});
    expect(r.isError, isTrue);
    expect(r.text, contains('unknown model'));
    expect(store.db.select('SELECT id FROM workers'), isEmpty);
  });

  test('Antigravity models asked for by id or short name; others are refused', () async {
    String? id(String name, {ModelCatalog? catalog}) {
      final c = Workers.antigravityModel(name, catalog: catalog);
      return c == null ? null : '${c.provider.name}:${c.model}-${c.effort}';
    }

    expect(id('gemini neon'), 'antigravity:gemini-4-neon-high');
    expect(id('Gemini Neon XHigh'), 'antigravity:gemini-4-neon-xhigh');
    expect(id('gemini-4-neon-xhigh'), 'antigravity:gemini-4-neon-xhigh');
    expect(id('gemini-4-carbon'), 'antigravity:gemini-4-carbon-high');
    expect(id('gemini'), 'antigravity:gemini-4-neon-high');
    expect(id('neon low'), 'antigravity:gemini-4-neon-low');
    expect(id('Gemini 3.8 Flash (Medium)'), 'antigravity:gemini-3.8-flash-medium');
    expect(id('gemini flash'), 'antigravity:gemini-3.8-flash-high');
    expect(id('gpt-6'), isNull);
    expect(id('opus'), isNull);
    final catalog = ModelCatalog.antigravity(version: '1', models: [
      ('gemini-5-ion-high', 'Gemini 5 Ion (High)'),
      ('gemini-5-ion-low', 'Gemini 5 Ion (Low)'),
      ('gemini-pro-orchestrator', 'Orchestrator'),
    ]);
    expect(id('gemini ion', catalog: catalog), 'antigravity:gemini-5-ion-high');
    expect(id('gemini-pro-orchestrator', catalog: catalog), 'antigravity:gemini-pro-orchestrator-high');
    expect(id('gemini neon', catalog: catalog), isNull);
    expect(id('gemini', catalog: catalog), isNull);

    var r = await workers.call('start_worker', {'title': 't', 'task': 'do it', 'provider': 'antigravity', 'model': 'opus'});
    expect(r.text, contains('unknown Antigravity model'));
    r = await workers.call('start_worker', {'title': 't', 'task': 'do it', 'provider': 'claude', 'model': 'gemini neon'});
    expect(r.text, contains('unknown Claude model'));
    r = await workers.call('start_worker', {'title': 't', 'task': 'do it', 'provider': 'openai'});
    expect(r.text, contains('unknown provider'));
    r = await workers.call('message_worker', {'id': 9, 'text': 'more', 'model': 'gemini zzz'});
    expect(r.text, contains('unknown model'));
    expect(r.isError, isTrue);
    expect(store.db.select('SELECT id FROM workers'), isEmpty);

    final offline = Workers(
      store: store,
      hostTools: const [],
      projects: Projects('${tmp.path}/projects', home: tmp.path),
      notify: (_) {},
      unavailable: {BrainProvider.antigravity},
    );
    r = await offline.call('start_worker', {'title': 't', 'task': 'do it', 'model': 'gemini neon'});
    expect(r.isError, isTrue);
    expect(r.text, contains('Antigravity is not available'));
    offline.dispose();
  });

  test('list_workers and worker_status show the model', () async {
    add('busy', 'running', ago: const Duration(minutes: 4), model: 'Claude · Fable 5.1', progress: 'Reading.');
    add('old', 'done', ago: const Duration(hours: 2), finishedAgo: const Duration(hours: 1));
    final list = (await workers.call('list_workers', {})).text;
    expect(list, contains('1 «busy» running on Claude · Fable 5.1 — Reading.'));
    expect(list, contains('2 «old» done'));
    expect(list, isNot(contains('2 «old» done on')));
    final status = (await workers.call('worker_status', {'id': 1})).text;
    expect(status, contains('model: Claude · Fable 5.1'));
  });

  testWidgets('the panel shows each worker and nothing without them', (tester) async {
    Widget app() => MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: Row(children: [const Expanded(child: SizedBox()), WorkersPanel(workers: workers)])),
        );
    await tester.pumpWidget(app());
    expect(find.byType(Container), findsNothing);

    add('Investigar vuelos', 'running',
        ago: const Duration(minutes: 1, seconds: 5), model: 'Codex · gpt-6', progress: 'Comparando precios.');
    await tester.pumpWidget(app(), duration: const Duration(seconds: 1));
    expect(find.text('Investigar vuelos'), findsOneWidget);
    expect(find.textContaining('Trabajando · 1 min'), findsOneWidget);
    expect(find.text('Comparando precios.'), findsOneWidget);
    expect(find.text('Codex · gpt-6'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  void write(String path, String text) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(text);

  /// Sets when [path] last changed (a folder's time can't be set from dart:io).
  void touch(String path, DateTime at) {
    final f = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    Process.runSync('touch', ['-t', '${f.year}${two(f.month)}${two(f.day)}${two(f.hour)}${two(f.minute)}', path]);
  }

  test('the projects board has the most recently active first, each with its latest worker', () {
    final dir = '${tmp.path}/projects';
    write('$dir/Casa/README.md', '# Casa\n\nObra del baño.\n');
    write('$dir/blog/README.md', 'Mi blog.\n');
    write('$dir/viaje/README.md', 'Viaje a Japón.\n');
    Directory('$dir/vacio').createSync();
    for (final p in ['Casa', 'blog', 'viaje']) {
      touch('$dir/$p/README.md', DateTime.now().subtract(const Duration(days: 3)));
      touch('$dir/$p', DateTime.now().subtract(const Duration(days: 3)));
    }
    touch('$dir/blog/README.md', DateTime.now().subtract(const Duration(days: 1)));
    add('presupuesto viejo', 'done',
        ago: const Duration(hours: 5), finishedAgo: const Duration(hours: 4), cwd: '$dir/Casa');
    add('comparar presupuestos', 'running',
        ago: const Duration(minutes: 4), cwd: '$dir/Casa', progress: 'Leyendo los planos.');
    add('fuera', 'done',
        ago: const Duration(minutes: 2), finishedAgo: const Duration(minutes: 1), cwd: '${tmp.path}/code');

    final board = workers.projectsBoard();
    expect(board.map((p) => p.name), ['Casa', 'blog', 'viaje']);
    expect(board.first.worker?.title, 'comparar presupuestos');
    expect(board.first.worker?.latest, 'Leyendo los planos.');
    expect(board[1].worker, isNull);
    expect(board[1].summary, 'Mi blog.');
    expect(workers.projectsBoard(limit: 2), hasLength(2));
  });

  testWidgets('the projects panel shows each project and how it is going', (tester) async {
    final dir = '${tmp.path}/projects';
    write('$dir/Casa/README.md', 'Obra del baño.\n');
    write('$dir/blog/README.md', 'Mi blog.\n');
    add('Revisar facturas', 'done',
        ago: const Duration(minutes: 30),
        finishedAgo: const Duration(minutes: 5),
        cwd: '$dir/Casa',
        result: 'Hecho: dos facturas pendientes.');
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Row(children: [ProjectsPanel(workers: workers), const Expanded(child: SizedBox())])),
    ));
    expect(find.text('Casa'), findsOneWidget);
    expect(find.text('Terminado · hace 5 min'), findsOneWidget);
    expect(find.text('Revisar facturas'), findsOneWidget);
    expect(find.text('Hecho: dos facturas pendientes.'), findsOneWidget);
    expect(find.text('blog'), findsOneWidget);
    expect(find.text('Mi blog.'), findsOneWidget);
    expect(find.text('Modificado ahora mismo'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
