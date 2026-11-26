import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/app/workers_panel.dart';
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

  testWidgets('the panel shows each worker and nothing without them', (tester) async {
    Widget app() => MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: Row(children: [const Expanded(child: SizedBox()), WorkersPanel(workers: workers)])),
        );
    await tester.pumpWidget(app());
    expect(find.text('TRABAJOS EN SEGUNDO PLANO'), findsNothing);

    add('Investigar vuelos', 'running',
        ago: const Duration(minutes: 1, seconds: 5), model: 'Codex · gpt-6', progress: 'Comparando precios.');
    await tester.pumpWidget(app(), duration: const Duration(seconds: 1));
    expect(find.text('TRABAJOS EN SEGUNDO PLANO'), findsOneWidget);
    expect(find.text('Investigar vuelos'), findsOneWidget);
    expect(find.textContaining('Trabajando · 1 min'), findsOneWidget);
    expect(find.text('Comparando precios.'), findsOneWidget);
    expect(find.text('Codex · gpt-6'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
