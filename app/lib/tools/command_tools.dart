import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../mcp/display_mcp_server.dart';
import 'tool_provider.dart';

/// Shell commands and files on the user's Mac.
///
/// Everything runs at once, nothing is confirmed by the user (design §3.5).
class CommandTools extends ToolProvider {
  CommandTools({String? home}) : home = home ?? Platform.environment['HOME'] ?? '/';

  final String home;

  static const _maxOutput = 12000;

  @override
  final List<McpTool> tools = const [
    McpTool(
      'run_command',
      'Run a zsh command on the user\'s Mac (login shell, cwd = home unless given). Returns exit '
          'code and output (truncated). Runs at once. Not for long-running servers.',
      {
        'type': 'object',
        'properties': {
          'command': {'type': 'string'},
          'cwd': {'type': 'string'},
          'timeout_s': {'type': 'integer', 'description': 'Default 60, max 600.'},
        },
        'required': ['command'],
      },
    ),
    McpTool(
      'read_file',
      'Read a text file (path absolute or relative to home). offset/limit in lines.',
      {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'offset': {'type': 'integer'},
          'limit': {'type': 'integer'},
        },
        'required': ['path'],
      },
    ),
    McpTool(
      'write_file',
      'Create or overwrite a text file (append: true adds to the end).',
      {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'content': {'type': 'string'},
          'append': {'type': 'boolean'},
        },
        'required': ['path', 'content'],
      },
    ),
    McpTool(
      'list_dir',
      'List a directory (name, size, modified). Path absolute or relative to home.',
      {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
      },
    ),
  ];

  @override
  Future<ToolResult> call(String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'run_command':
        return _run(args);
      case 'read_file':
        return _read(args);
      case 'write_file':
        return _write(args);
      case 'list_dir':
        return _list(args);
    }
    return ToolResult.error('error: unknown tool $name');
  }

  String _path(String? p) {
    if (p == null || p.isEmpty) return home;
    if (p.startsWith('~/')) return '$home/${p.substring(2)}';
    if (p == '~') return home;
    return p.startsWith('/') ? p : '$home/$p';
  }

  Future<ToolResult> _run(Map<String, dynamic> args) async {
    final command = (args['command'] as String? ?? '').trim();
    if (command.isEmpty) return const ToolResult.error('error: empty command');
    final timeout = Duration(seconds: ((args['timeout_s'] as num?)?.toInt() ?? 60).clamp(1, 600));
    final cwd = _path(args['cwd'] as String?);
    if (!Directory(cwd).existsSync()) return ToolResult.error('error: cwd not found: $cwd');
    final shell = Platform.environment['SHELL'] ?? '/bin/zsh';
    final p = await Process.start(shell, ['-lc', command], workingDirectory: cwd);
    unawaited(p.stdin.close());
    final out = StringBuffer();
    final done = Future.wait([
      p.stdout.transform(utf8.decoder).forEach(out.write),
      p.stderr.transform(utf8.decoder).forEach(out.write),
    ]);
    int code;
    try {
      code = await p.exitCode.timeout(timeout);
      await done.timeout(const Duration(seconds: 2), onTimeout: () => []);
    } on TimeoutException {
      p.kill(ProcessSignal.sigkill);
      return ToolResult('timeout after ${timeout.inSeconds}s; output so far:\n${_truncate(out.toString())}',
          isError: true);
    }
    final text = _truncate(out.toString());
    return ToolResult('exit $code\n$text', isError: code != 0);
  }

  Future<ToolResult> _read(Map<String, dynamic> args) async {
    final f = File(_path(args['path'] as String?));
    if (!f.existsSync()) return ToolResult.error('error: not found: ${f.path}');
    final lines = await f.openRead().transform(utf8.decoder).transform(const LineSplitter()).toList();
    final offset = ((args['offset'] as num?)?.toInt() ?? 0).clamp(0, lines.length);
    final limit = ((args['limit'] as num?)?.toInt() ?? 400).clamp(1, 2000);
    final end = (offset + limit).clamp(0, lines.length);
    final body = lines.sublist(offset, end).join('\n');
    final more = end < lines.length ? '\n[… ${lines.length - end} more lines; use offset]' : '';
    return ToolResult('${_truncate(body)}$more');
  }

  Future<ToolResult> _write(Map<String, dynamic> args) async {
    final f = File(_path(args['path'] as String?));
    final content = args['content'] as String? ?? '';
    final append = args['append'] == true;
    await f.parent.create(recursive: true);
    await f.writeAsString(content, mode: append ? FileMode.append : FileMode.write);
    return ToolResult('${append ? 'appended to' : 'wrote'} ${f.path} (${content.length} chars)');
  }

  Future<ToolResult> _list(Map<String, dynamic> args) async {
    final d = Directory(_path(args['path'] as String?));
    if (!d.existsSync()) return ToolResult.error('error: not found: ${d.path}');
    final entries = d.listSync()..sort((a, b) => a.path.compareTo(b.path));
    final b = StringBuffer('${d.path}\n');
    for (final e in entries.take(300)) {
      final s = e.statSync();
      final name = e.path.split('/').last;
      final kind = s.type == FileSystemEntityType.directory ? '/' : '';
      final size = s.type == FileSystemEntityType.directory ? '' : ' ${s.size}';
      b.writeln('$name$kind$size ${s.modified.toIso8601String().substring(0, 16)}');
    }
    if (entries.length > 300) b.writeln('[… ${entries.length - 300} more]');
    return ToolResult(b.toString());
  }

  static String _truncate(String s) {
    if (s.length <= _maxOutput) return s;
    const head = _maxOutput * 2 ~/ 3;
    const tail = _maxOutput - head;
    return '${s.substring(0, head)}\n[… ${s.length - _maxOutput} chars cut …]\n${s.substring(s.length - tail)}';
  }
}
