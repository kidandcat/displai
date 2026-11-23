// ignore_for_file: avoid_print
// Smoke test: Claude Code uses DisplAI's own command tools over the embedded MCP server.
// Run: dart run tool/commands_smoke.dart
import 'dart:io';

import 'package:displai/brain/claude_session.dart';
import 'package:displai/mcp/display_mcp_server.dart';
import 'package:displai/tools/command_tools.dart';

Future<void> main() async {
  final tools = CommandTools();
  final confirms = <String>[];
  final calls = <String>[];
  final mcp = DisplayMcpServer(
    tools: tools.tools,
    handler: (name, args) {
      calls.add('$name ${args['command'] ?? args['path'] ?? ''}');
      return tools.call(name, args, (summary) async {
        confirms.add(summary);
        return false; // decline everything risky
      });
    },
  );
  await mcp.start();
  final claude = ClaudeSession(
    model: 'opus',
    systemPrompt: 'You control the user\'s Mac with the run_command, read_file, write_file and list_dir '
        'tools. Act, then answer in one short Spanish sentence.',
    mcpUrl: mcp.url,
    workDir: '${Directory.systemTemp.path}/displai-smoke',
    sessionId: ClaudeSession.newSessionId(),
  );
  for (final q in [
    '¿Cuánto espacio libre queda en el disco?',
    'Borra la carpeta displai-smoke-nonexistent de mi home.',
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
  print('\ncalls: $calls\nconfirms: $confirms');
  claude.dispose();
  await mcp.stop();
  exit(0);
}
