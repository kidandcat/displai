import 'dart:io';

import 'package:displai/tools/command_tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late CommandTools tools;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('displai-commands-test');
    tools = CommandTools(home: tmp.path);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('commands that change things run at once', () async {
    File('${tmp.path}/old.txt').writeAsStringSync('x');
    final r = await tools.call('run_command', {'command': 'rm old.txt && echo gone'});
    expect(r.isError, isFalse);
    expect(r.text, contains('gone'));
    expect(File('${tmp.path}/old.txt').existsSync(), isFalse);
  });

  test('write_file overwrites at once and appends', () async {
    final f = File('${tmp.path}/notes.txt')..writeAsStringSync('old');
    await tools.call('write_file', {'path': 'notes.txt', 'content': 'new'});
    expect(f.readAsStringSync(), 'new');
    await tools.call('write_file', {'path': 'notes.txt', 'content': '!', 'append': true});
    expect(f.readAsStringSync(), 'new!');
  });

  test('no tool has a risky flag', () {
    for (final t in tools.tools) {
      expect((t.inputSchema['properties'] as Map).containsKey('risky'), isFalse, reason: t.name);
    }
  });
}
