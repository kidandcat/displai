// ignore_for_file: avoid_print
// Smoke test: Claude Code (headless) calls a stub display tool over the embedded MCP server.
// Run: dart run tool/brain_smoke.dart
import 'dart:io';

import 'package:displai/brain/claude_session.dart';
import 'package:displai/mcp/display_mcp_server.dart';

Future<void> main() async {
  final calls = <String>[];
  final mcp = DisplayMcpServer(
    tools: const [
      McpTool('show', 'Show a view. title = short title, body = list of {type:"text", text}.', {
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
          'body': {'type': 'array', 'items': {'type': 'object'}},
        },
        'required': ['title', 'body'],
      }),
    ],
    handler: (name, args) {
      calls.add('$name $args');
      return const ToolResult('ok: shown');
    },
  );
  await mcp.start();
  final claude = ClaudeSession(
    model: 'opus',
    systemPrompt: 'You are a voice assistant with a display. Speak one short sentence, then use the show tool.',
    mcpUrl: mcp.url,
    workDir: '${Directory.systemTemp.path}/displai-smoke',
    sessionId: ClaudeSession.newSessionId(),
  );
  final t0 = DateTime.now();
  var first = true;
  final done = claude.events.firstWhere((e) => e is TurnDone);
  claude.events.listen((e) {
    final ms = DateTime.now().difference(t0).inMilliseconds;
    switch (e) {
      case TextDelta():
        if (first) print('[$ms ms] first text');
        first = false;
        stdout.write(e.text);
      case ToolStart():
        print('\n[$ms ms] tool start ${e.name}');
      case ToolInput() || Compacting():
        break;
      case TurnDone():
        print('\n[$ms ms] done interrupted=${e.interrupted} error=${e.error}');
    }
  });
  await claude.send('Enséñame tres frutas de otoño en pantalla.');
  await done.timeout(const Duration(seconds: 90));
  print('tool calls: $calls');
  claude.dispose();
  await mcp.stop();
  exit(calls.isEmpty ? 1 : 0);
}
