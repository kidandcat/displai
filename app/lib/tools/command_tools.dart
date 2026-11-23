import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../mcp/display_mcp_server.dart';
import 'tool_provider.dart';

/// Shell commands and files on the user's Mac.
///
/// Read-only commands run directly; anything that may change something is confirmed by the user
/// first (design §3.4: confirm only dangerous actions).
class CommandTools extends ToolProvider {
  CommandTools({String? home}) : home = home ?? Platform.environment['HOME'] ?? '/';

  final String home;

  static const _maxOutput = 12000;

  static const _riskyProp = {
    'type': 'boolean',
    'description': 'true if this deletes, sends, buys, publishes or changes something important.',
  };

  @override
  final List<McpTool> tools = const [
    McpTool(
      'run_command',
      'Run a zsh command on the user\'s Mac (login shell, cwd = home unless given). Returns exit '
          'code and output (truncated). Read-only commands run at once; commands that change things '
          'are confirmed by the user automatically, do not ask first. Not for long-running servers.',
      {
        'type': 'object',
        'properties': {
          'command': {'type': 'string'},
          'cwd': {'type': 'string'},
          'timeout_s': {'type': 'integer', 'description': 'Default 60, max 600.'},
          'summary': {'type': 'string', 'description': 'What it does, in a few Spanish words, for the user.'},
          'risky': _riskyProp,
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
      'Create or overwrite a text file (append: true adds to the end). Overwriting is confirmed by '
          'the user automatically.',
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
  Future<ToolResult> call(String name, Map<String, dynamic> args, ConfirmAction confirm) async {
    switch (name) {
      case 'run_command':
        return _run(args, confirm);
      case 'read_file':
        return _read(args);
      case 'write_file':
        return _write(args, confirm);
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

  Future<ToolResult> _run(Map<String, dynamic> args, ConfirmAction confirm) async {
    final command = (args['command'] as String? ?? '').trim();
    if (command.isEmpty) return const ToolResult.error('error: empty command');
    final risky = args['risky'] == true || !isReadOnlyCommand(command);
    if (risky) {
      final summary = (args['summary'] as String?)?.trim();
      final short = command.length > 120 ? '${command.substring(0, 117)}…' : command;
      final ok = await confirm(summary == null || summary.isEmpty ? 'Ejecutar: $short' : '$summary\n$short');
      if (!ok) return declined;
    }
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

  Future<ToolResult> _write(Map<String, dynamic> args, ConfirmAction confirm) async {
    final f = File(_path(args['path'] as String?));
    final content = args['content'] as String? ?? '';
    final append = args['append'] == true;
    if (f.existsSync() && !append) {
      if (!await confirm('Sobrescribir ${f.path}')) return declined;
    }
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

  // ------------------------------------------------------------------ risk heuristic

  static const _readOnly = {
    'ls', 'cat', 'head', 'tail', 'grep', 'egrep', 'rg', 'wc', 'du', 'df', 'ps', 'pwd', 'echo',
    'printf', 'date', 'cal', 'which', 'whereis', 'type', 'whoami', 'id', 'uname', 'sw_vers',
    'system_profiler', 'mdfind', 'mdls', 'file', 'stat', 'sort', 'uniq', 'cut', 'tr', 'jq',
    'uptime', 'hostname', 'env', 'printenv', 'tree', 'less', 'more', 'diff', 'cmp', 'md5',
    'shasum', 'basename', 'dirname', 'realpath', 'readlink', 'ping', 'dig', 'nslookup', 'host',
    'lsof', 'top', 'vm_stat', 'sysctl', 'ioreg', 'networksetup', 'scutil', 'pmset', 'defaults',
    'git', 'brew', 'open', 'curl', 'find', 'sed', 'awk', 'column', 'nl', 'fold', 'tac', 'rev',
    'xxd', 'od', 'strings', 'otool', 'codesign', 'spctl', 'sips', 'say', 'true', 'test', '[',
    'osascript', 'pbpaste', 'mdutil', 'log', 'launchctl', 'man', 'python3', 'node',
  };

  static const _gitReadOnly = {
    'status', 'log', 'diff', 'show', 'branch', 'remote', 'rev-parse', 'ls-files', 'blame',
    'describe', 'tag', 'config', 'shortlog', 'reflog', 'grep',
  };

  /// True when every part of [command] only reads (no redirection into files, no destructive
  /// flags). Conservative: unknown commands count as changing something.
  static bool isReadOnlyCommand(String command) {
    final c = command.replaceAll(RegExp(r'\d?>\s*/dev/null|2>&1'), '');
    if (c.contains('>') || c.contains('`') || c.contains(r'$(') || c.contains('sudo')) return false;
    for (var part in c.split(RegExp(r'\|\||&&|[|;\n&]'))) {
      part = part.trim();
      if (part.isEmpty) continue;
      final words = part.split(RegExp(r'\s+')).where((w) => !RegExp(r'^\w+=').hasMatch(w)).toList();
      if (words.isEmpty) continue;
      final cmd = words.first.split('/').last;
      final rest = words.skip(1).toList();
      if (!_readOnly.contains(cmd)) return false;
      switch (cmd) {
        case 'git':
          final sub = rest.firstWhere((w) => !w.startsWith('-'), orElse: () => '');
          if (!_gitReadOnly.contains(sub)) return false;
          if ((sub == 'branch' || sub == 'tag' || sub == 'remote' || sub == 'config') &&
              rest.any((w) => w.startsWith('-d') || w.startsWith('-D') || w == 'add' || w == 'rm' ||
                  w == 'remove' || w == '--unset' || w == '--delete' || (sub == 'config' && rest.length > 2))) {
            return false;
          }
        case 'brew':
          if (!rest.any((w) => const {'list', 'info', 'search', 'outdated', 'deps', 'doctor', '--version'}.contains(w))) {
            return false;
          }
        case 'curl':
          if (rest.any((w) => RegExp(r'^(-X|--request|-d|--data.*|-F|--form|-T|--upload-file|-o|-O|--output)$').hasMatch(w))) {
            return false;
          }
        case 'find':
          if (rest.any((w) => w == '-delete' || w.startsWith('-exec') || w.startsWith('-ok'))) return false;
        case 'sed':
          if (rest.any((w) => w.startsWith('-i') || w == '--in-place')) return false;
        case 'awk':
          if (part.contains('system(')) return false;
        case 'defaults':
          if (rest.isEmpty || rest.first != 'read') return false;
        case 'launchctl':
          if (rest.isEmpty || !const {'list', 'print'}.contains(rest.first)) return false;
        case 'pmset':
          if (rest.isEmpty || rest.first != '-g') return false;
        case 'networksetup':
          if (rest.isEmpty || !rest.first.startsWith('-get') && !rest.first.startsWith('-list')) return false;
        case 'osascript' || 'python3' || 'node':
          return false; // arbitrary code
        case 'mdutil':
          if (!rest.contains('-s')) return false;
        case 'top':
          if (!rest.contains('-l')) return false;
      }
    }
    return true;
  }
}
