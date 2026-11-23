import 'dart:io';

import 'package:minerva/routines/routines.dart';
import 'package:minerva/store/store.dart';
import 'package:minerva/tools/history_tools.dart';
import 'package:minerva/tools/memory_tools.dart';
import 'package:minerva/tools/skill_tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late Store store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('minerva-store-test');
    store = Store.memory(tmp.path);
  });

  tearDown(() {
    store.close();
    tmp.deleteSync(recursive: true);
  });

  test('history search matches any word, ignoring accents and case', () async {
    store.addMessage('user', 'Recuérdame la cita del dentista el jueves');
    store.addMessage('assistant', 'Vale, te lo recuerdo.');
    store.addMessage('user', 'Pon música de jazz');
    final tools = HistoryTools(store);
    final r = await tools.call('search_history', {'query': 'DENTISTA cita'});
    expect(r.text, contains('«dentista»'));
    expect(r.text, isNot(contains('jazz')));
    final latest = await tools.call('search_history', {'limit': 1});
    expect(latest.text, contains('jazz'));
    final around = await tools.call('search_history', {'around': 2});
    expect(around.text.split('\n'), hasLength(3));
  });

  test('memories: save, update, search, forget, essential budget and prompt', () async {
    final m = MemoryTools(store);
    expect((await m.call('remember', {'text': 'Jairo prefiere el café solo', 'essential': true})).text,
        'saved memory 1');
    await m.call('remember', {'text': 'El coche es un Golf azul'});
    expect((await m.call('search_memories', {'query': 'cafe'})).text, contains('café solo'));
    await m.call('remember', {'id': 1, 'text': 'Jairo prefiere el café con leche'});
    expect((await m.call('search_memories', {'query': 'café'})).text, contains('con leche'));
    expect((await m.call('search_memories', {'query': 'solo'})).text, 'no memories found');
    expect(MemoryTools.promptSection(store), contains('[1] Jairo prefiere el café con leche'));
    expect(MemoryTools.promptSection(store), isNot(contains('Golf')));
    final big = 'x' * MemoryTools.essentialBudget;
    expect((await m.call('remember', {'text': big, 'essential': true})).isError, isTrue);
    expect((await m.call('forget_memory', {'id': 2})).text, 'forgot memory 2');
    expect((await m.call('search_memories', {'query': 'Golf'})).text, 'no memories found');
    expect(MemoryTools(store, readOnly: true).tools.map((t) => t.name), ['search_memories']);
  });

  test('skills: save, list, read, delete', () async {
    final dir = '${tmp.path}/skills';
    final s = SkillTools(dir);
    await s.call('save_skill', {'name': 'Pedir Pizza', 'description': 'Order a pizza.', 'body': '1. Call.'});
    expect(SkillTools.list(dir).single.name, 'pedir-pizza');
    expect(SkillTools.promptSection(dir), contains('- pedir-pizza: Order a pizza.'));
    expect((await s.call('read_skill', {'name': 'pedir pizza'})).text, contains('1. Call.'));
    expect((await s.call('delete_skill', {'name': 'pedir-pizza'})).text, 'deleted skill pedir-pizza');
    expect(SkillTools.list(dir), isEmpty);
  });

  group('routines', () {
    test('next run for each schedule type', () {
      final from = DateTime(2026, 11, 23, 17, 0); // Monday
      expect(Routines.nextRun({'type': 'once', 'at': '2026-11-23T18:00:00.000'}, from), DateTime(2026, 11, 23, 18));
      expect(Routines.nextRun({'type': 'once', 'at': '2026-11-23T16:00:00.000'}, from), isNull);
      expect(Routines.nextRun({'type': 'daily', 'time': '08:30'}, from), DateTime(2026, 11, 24, 8, 30));
      expect(
        Routines.nextRun({'type': 'daily', 'time': '08:30', 'days': [6, 7]}, from),
        DateTime(2026, 11, 28, 8, 30),
      );
      expect(Routines.nextRun({'type': 'interval', 'minutes': 30}, from), DateTime(2026, 11, 23, 17, 30));
    });

    test('a due reminder fires once; a recurring one reschedules; long-missed runs are skipped', () async {
      var now = DateTime(2026, 11, 23, 17, 0);
      final fired = <String>[];
      final r = Routines(store: store, notify: fired.add, clock: () => now);
      final made = await r.call('create_routine', {
        'name': 'Dentista',
        'prompt': 'Recuérdale la cita del dentista.',
        'schedule': {'type': 'once', 'at': '2026-11-23T17:05'},
      });
      expect(made.text, startsWith('created routine 1'));
      await r.call('create_routine', {
        'name': 'Agua',
        'prompt': 'Recuérdale beber agua.',
        'schedule': {'type': 'interval', 'minutes': 60},
      });
      expect((await r.call('create_routine', {
        'name': 'Tarde',
        'prompt': 'x',
        'schedule': {'type': 'once', 'at': '2026-11-23T10:00'},
      })).isError, isTrue);

      r.tick();
      expect(fired, isEmpty);
      now = DateTime(2026, 11, 23, 17, 6);
      r.tick();
      expect(fired.single, contains('Recuérdale la cita del dentista.'));
      r.tick();
      expect(fired, hasLength(1)); // a one-time reminder fires once
      expect((await r.call('list_routines', {})).text, contains('«Dentista» once at 2026-11-23 17:05 (Mon), paused'));

      now = DateTime(2026, 11, 23, 18, 1);
      r.tick();
      expect(fired.last, contains('beber agua'));
      now = DateTime(2026, 11, 24, 9, 0); // app closed overnight: skipped, rescheduled
      r.tick();
      expect(fired, hasLength(2));
      expect((await r.call('list_routines', {})).text, contains('next 2026-11-24 10:00'));

      await r.call('update_routine', {'id': 2, 'enabled': false});
      now = DateTime(2026, 11, 24, 12, 0);
      r.tick();
      expect(fired, hasLength(2));
      expect((await r.call('delete_routine', {'id': 2})).text, 'deleted routine 2');
    });
  });
}
