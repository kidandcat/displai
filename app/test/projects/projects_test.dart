import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/projects/projects.dart';
import 'package:minerva/store/store.dart';

void main() {
  late Directory tmp;
  late Projects projects;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('minerva-projects-test');
    projects = Projects('${tmp.path}/projects', home: tmp.path);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  void write(String path, String text) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(text);

  test('lists folders with a main doc, with its first line of text', () {
    expect(projects.list(), isEmpty);
    expect(projects.promptSection(), contains('${tmp.path}/projects/<name>/README.md'));
    write('${tmp.path}/projects/Casa/README.md', '# Reforma de la casa\n\nObra del baño y la cocina.\n');
    write('${tmp.path}/projects/blog/AGENTS.md', '# Blog\n');
    Directory('${tmp.path}/projects/empty').createSync();
    expect(projects.list().map((p) => (p.name, p.summary)), [
      ('blog', 'Blog'),
      ('Casa', 'Obra del baño y la cocina.'),
    ]);
    expect(projects.promptSection(), contains('- Casa: Obra del baño y la cocina.'));
  });

  test('resolves names in any case and folder paths', () {
    write('${tmp.path}/projects/Casa/README.md', 'Obra.');
    Directory('${tmp.path}/code/app').createSync(recursive: true);
    expect(projects.resolve('casa'), '${tmp.path}/projects/Casa');
    expect(projects.resolve('~/code/app/'), '${tmp.path}/code/app');
    expect(projects.resolve('${tmp.path}/code'), '${tmp.path}/code');
    expect(projects.resolve('nope'), isNull);
    expect(projects.resolve('~/nope'), isNull);
  });

  test('a worker gets the folder and its main doc', () {
    write('${tmp.path}/projects/Casa/README.md', 'Presupuesto: 12000 euros.');
    final s = projects.workerSection('${tmp.path}/projects/Casa');
    expect(s, contains('working folder is ${tmp.path}/projects/Casa'));
    expect(s, contains('Presupuesto: 12000 euros.'));
    expect(s, contains('up to date'));
    // A folder outside the projects dir is not asked to keep docs.
    Directory('${tmp.path}/code').createSync();
    expect(projects.workerSection('${tmp.path}/code'), isNot(contains('up to date')));
  });

  test('workers keep their folder', () {
    final store = Store.memory(tmp.path);
    store.db.execute(
        "INSERT INTO workers(title, task, status, session_id, started, cwd) VALUES ('t', 'x', 'done', 's', 0, '/a')");
    expect(store.db.select('SELECT cwd FROM workers').single['cwd'], '/a');
    store.close();
  });
}
