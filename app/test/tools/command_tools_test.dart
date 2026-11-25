import 'dart:convert';
import 'dart:io';

import 'package:minerva/tools/command_tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late CommandTools tools;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('minerva-commands-test');
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

  test('read_file shows an image as PNG', () async {
    // A JPEG, made by sips from a 1x1 PNG.
    final png = File('${tmp.path}/dot.png')
      ..writeAsBytesSync(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=='));
    Process.runSync('/usr/bin/sips', ['-s', 'format', 'jpeg', png.path, '--out', '${tmp.path}/dot.jpg']);
    final r = await tools.call('read_file', {'path': 'dot.jpg'});
    expect(r.isError, isFalse, reason: r.text);
    expect(r.png!.sublist(1, 4), 'PNG'.codeUnits);
  });

  test('no tool has a risky flag', () {
    for (final t in tools.tools) {
      expect((t.inputSchema['properties'] as Map).containsKey('risky'), isFalse, reason: t.name);
    }
  });
}
