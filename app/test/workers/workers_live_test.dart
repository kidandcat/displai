// ignore_for_file: avoid_print
// Live workers on the signed-in agents (Antigravity's `agy`, Claude Code): progress notes, the
// final report, a follow-up resuming the same conversation, and stop. Skipped unless
// MINERVA_LIVE_WORKERS is set: flutter test test/workers/workers_live_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/brain/fallback.dart';
import 'package:minerva/projects/projects.dart';
import 'package:minerva/store/store.dart';
import 'package:minerva/workers/workers.dart';

void main() {
  final skip = Platform.environment['MINERVA_LIVE_WORKERS'] == null ? 'set MINERVA_LIVE_WORKERS' : null;

  for (final (provider, model) in [('antigravity', 'gemini flash low'), ('claude', 'haiku')]) {
    test('a $provider worker reports, resumes its conversation and stops', () async {
      final tmp = Directory.systemTemp.createTempSync('minerva-live-workers');
      final store = Store.memory(tmp.path);
      final cwd = Directory('${tmp.path}/projects/Faro')..createSync(recursive: true);
      File('${cwd.path}/README.md').writeAsStringSync('Faro: a test project.\n');
      File('${cwd.path}/marker-7f3k.txt').writeAsStringSync('hello\n');
      final notes = StreamController<String>.broadcast();
      final workers = Workers(
        store: store,
        hostTools: const [],
        projects: Projects('${tmp.path}/projects', home: tmp.path),
        notify: notes.add,
        limits: ProviderLimits(),
        describe: (c) => '${c.provider.label} · ${c.resolve(null).model}',
      );
      addTearDown(() {
        workers.dispose();
        store.close();
        tmp.deleteSync(recursive: true);
      });

      var report = notes.stream.first;
      var r = await workers.call('start_worker', {
        'title': 'live test',
        'task': 'Call report_progress once with the note "looking". Then list the files of your working '
            'directory and reply with only the name of the file that starts with "marker-".',
        'project': 'Faro',
        'provider': provider,
        'model': model,
      });
      print(r.text);
      expect(r.isError, isFalse);
      var text = await report.timeout(const Duration(minutes: 4));
      print(text);
      expect(text, contains('[worker 1 «live test» finished]'));
      expect(text, contains('marker-7f3k.txt'));
      final row = store.db.select('SELECT * FROM workers WHERE id = 1').first;
      expect(row['progress'], isNotNull);
      expect(row['cwd'], cwd.path);
      final list = (await workers.call('list_workers', {})).text;
      print(list);
      expect(list, contains(provider == 'claude' ? 'Claude · claude-haiku-5-5' : 'Antigravity · gemini-3.8-flash-low'));

      report = notes.stream.first;
      r = await workers.call('message_worker', {
        'id': 1,
        'text': 'Without using any tool: what file name did you report before? Reply with it reversed, '
            'character by character.',
      });
      print(r.text);
      expect(r.isError, isFalse);
      text = await report.timeout(const Duration(minutes: 3));
      print(text);
      expect(text, contains('txt.k3f7-rekram'));
      final stored = store.db.select('SELECT session_id FROM workers WHERE id = 1').first['session_id'];
      expect(stored, row['session_id']);

      r = await workers.call('start_worker', {
        'title': 'to stop',
        'task': 'Count slowly from 1 to 50, calling report_progress at each number.',
        'provider': provider,
        'model': model,
      });
      expect(r.isError, isFalse);
      await Future<void>.delayed(const Duration(seconds: 3));
      r = await workers.call('stop_worker', {'id': 2});
      expect(r.text, 'stopped worker 2');
      expect(store.db.select('SELECT status FROM workers WHERE id = 2').first['status'], 'stopped');
      expect(workers.runningCount, 0);

      // On the other provider, a finished worker starts over there from its task and report.
      final (other, otherModel, shown) = provider == 'claude'
          ? ('antigravity', 'gemini flash low', 'Antigravity · gemini-3.8-flash-low')
          : ('claude', 'haiku', 'Claude · claude-haiku-5-5');
      report = notes.stream.first;
      r = await workers.call('message_worker',
          {'id': 1, 'text': 'Reply with only the marker file name in upper case.', 'provider': other, 'model': otherModel});
      print(r.text);
      expect(r.text, contains(shown));
      text = await report.timeout(const Duration(minutes: 3));
      print(text);
      expect(text, contains('MARKER-7F3K.TXT'));
      expect(store.db.select('SELECT session_id FROM workers WHERE id = 1').first['session_id'], isNot(stored));
    }, timeout: const Timeout(Duration(minutes: 10)), skip: skip);
  }
}
