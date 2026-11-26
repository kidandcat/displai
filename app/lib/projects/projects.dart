import 'dart:io';

/// Projects: plain folders under `<data>/projects`, each with a README.md that says what it is
/// (its notes and files sit next to it). The brain reads and writes them with the file tools;
/// only the index goes in its system prompt, and a worker started on a project runs inside the
/// folder with its main doc as context.
class Projects {
  Projects(this.dir, {String? home}) : home = home ?? Platform.environment['HOME'] ?? '/';

  final String dir;
  final String home;

  /// The doc a folder is described by: the first of these that exists.
  static const mainDocs = ['README.md', 'AGENTS.md', 'CLAUDE.md'];

  /// How much of a main doc a worker gets in its prompt.
  static const docLimit = 20000;

  /// Projects with a main doc, sorted by name, each with the first line of its doc.
  List<({String name, String summary})> list() {
    final d = Directory(dir);
    if (!d.existsSync()) return const [];
    final out = <({String name, String summary})>[];
    for (final e in d.listSync().whereType<Directory>()) {
      final doc = mainDoc(e.path);
      if (doc == null) continue;
      out.add((name: e.uri.pathSegments.where((s) => s.isNotEmpty).last, summary: _summary(doc.text)));
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// The first line of text that is not a heading (else the first heading), short.
  static String _summary(String text) {
    final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && l != '---');
    final line = lines.firstWhere((l) => !l.startsWith('#'),
        orElse: () => lines.isEmpty ? '' : lines.first.replaceFirst(RegExp(r'^#+\s*'), ''));
    return line.length > 120 ? '${line.substring(0, 119)}…' : line;
  }

  /// The folder of [project]: a project's name (any case), or a path (`~/…`, absolute) to any
  /// folder. Null when there is no such folder.
  String? resolve(String project) {
    final p = project.trim();
    if (p.isEmpty) return null;
    if (p.startsWith('/') || p.startsWith('~')) {
      final path = p == '~' ? home : (p.startsWith('~/') ? '$home/${p.substring(2)}' : p);
      return Directory(path).existsSync() ? path.replaceFirst(RegExp(r'/+$'), '') : null;
    }
    // The folder's own spelling (the Mac's disk ignores case, so an exists check alone would not).
    for (final e in list()) {
      if (e.name.toLowerCase() == p.toLowerCase()) return '$dir/${e.name}';
    }
    return Directory('$dir/$p').existsSync() ? '$dir/$p' : null;
  }

  /// How the folder at [path] is named to the user: a project's name, else its path from `~`.
  String label(String path) {
    if (path.startsWith('$dir/')) return path.substring(dir.length + 1);
    if (path == home) return '~';
    return path.startsWith('$home/') ? '~/${path.substring(home.length + 1)}' : path;
  }

  /// The main doc of the folder at [path], or null when it has none.
  static ({String name, String text})? mainDoc(String path) {
    for (final name in mainDocs) {
      final f = File('$path/$name');
      if (f.existsSync()) return (name: name, text: f.readAsStringSync());
    }
    return null;
  }

  /// When the folder at [path] last changed: itself or the latest of the files and folders
  /// right in it (not deeper, to stay cheap).
  static DateTime modified(String path) {
    final d = Directory(path);
    var latest = d.statSync().modified;
    try {
      for (final e in d.listSync(followLinks: false)) {
        final m = e.statSync().modified;
        if (m.isAfter(latest)) latest = m;
      }
    } on FileSystemException {
      // Unreadable: the folder's own time.
    }
    return latest;
  }

  /// The projects index as a system-prompt section.
  String promptSection() {
    final projects = list();
    return [
      'Projects: folders in $dir, each with a README.md that says what it is, next to its notes and files. '
          'To create one, write $dir/<name>/README.md. When the user turns to a project, read its README.md; '
          'read and update its files with the file tools; start_worker with project runs a worker inside it.',
      for (final p in projects) '- ${p.name}: ${p.summary}',
    ].join('\n');
  }

  /// What a worker started in the folder at [path] is told about it.
  String workerSection(String path) {
    final doc = mainDoc(path);
    var text = doc?.text.trim() ?? '';
    if (text.length > docLimit) text = '${text.substring(0, docLimit)}\n[… cut; read the rest from the file]';
    return [
      'Project: your working folder is $path.',
      if (doc != null) 'Its ${doc.name}:\n<project_doc>\n$text\n</project_doc>',
      if (path.startsWith('$dir/'))
        'Keep the project\'s docs there up to date with what you learn, decide or change.',
    ].join('\n');
  }
}
