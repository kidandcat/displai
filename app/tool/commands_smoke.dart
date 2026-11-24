// ignore_for_file: avoid_print
// Smoke test: Claude Code uses Minerva's own command tools over the embedded MCP server.
// Run: dart run tool/commands_smoke.dart
import 'dart:io';

import 'package:minerva/brain/brain_session.dart';
import 'package:minerva/brain/claude_session.dart';
import 'package:minerva/mcp/display_mcp_server.dart';
import 'package:minerva/tools/command_tools.dart';

Future<void> main() async {
  final tools = CommandTools();
  final calls = <String>[];
  final mcp = DisplayMcpServer(
    tools: tools.tools,
    handler: (name, args) {
      calls.add('$name ${args['command'] ?? args['path'] ?? ''}');
      return tools.call(name, args);
    },
  );
  await mcp.start();
  final claude = ClaudeSession(
    model: 'opus',
    systemPrompt: 'You control the user\'s Mac with the run_command, read_file, write_file and list_dir '
        'tools. Act, then answer in one short Spanish sentence.',
    mcpUrl: mcp.url,
    workDir: '${Directory.systemTemp.path}/minerva-smoke',
    sessionId: ClaudeSession.newSessionId(),
  );
  for (final q in [
    '¿Cuánto espacio libre queda en el disco?',
    'Borra la carpeta minerva-smoke-nonexistent de mi home.',
  ]) {
    final done = claude.events.firstWhere((e) => e is TurnDone);
    final sub = claude.events.listen((e) {
      if (e is TextDelta) stdout.write(e.text);
    });
    print('\n> $q');
    await claude.send(q);
    await done.timeout(const Duration(seconds: 120));
    await sub.cancel();
  }
  print('\ncalls: $calls');
  claude.dispose();
  await mcp.stop();
  exit(0);
}
