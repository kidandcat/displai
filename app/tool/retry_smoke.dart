// ignore_for_file: avoid_print
// Smoke test: when the claude process dies mid-turn, the session restarts it and resends the turn once.
// Run: dart run tool/retry_smoke.dart
import 'dart:async';
import 'dart:io';

import 'package:minerva/brain/brain_session.dart';
import 'package:minerva/brain/claude_session.dart';
import 'package:minerva/mcp/display_mcp_server.dart';

Future<void> main() async {
  final mcp = DisplayMcpServer(tools: const [], handler: (_, _) => const ToolResult('ok'));
  await mcp.start();
  final id = ClaudeSession.newSessionId();
  final claude = ClaudeSession(
    model: 'opus',
    systemPrompt: 'You are a voice assistant. Answer in one short sentence.',
    mcpUrl: mcp.url,
    workDir: '${Directory.systemTemp.path}/minerva-smoke',
    sessionId: id,
  );
  final done = <TurnDone>[];
  claude.events.listen((e) {
    if (e is TurnDone) {
      done.add(e);
      print('done interrupted=${e.interrupted} error=${e.error} result=${e.result}');
    }
  });
  await claude.send('¿Cuál es la capital de Francia?');
  var pid = '';
  while (pid.isEmpty) {
    pid = (await Process.run('pgrep', ['-f', id])).stdout.toString().trim().split('\n').first;
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
  if (done.isNotEmpty) throw StateError('turn ended before the kill');
  print('killing claude pid $pid mid-turn');
  Process.killPid(int.parse(pid));
  final t0 = DateTime.now();
  while (done.isEmpty && DateTime.now().difference(t0).inSeconds < 90) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  claude.dispose();
  await mcp.stop();
  final ok = done.length == 1 && done.single.error == null && done.single.result.contains('Par');
  print(ok ? 'PASS' : 'FAIL');
  exit(ok ? 0 : 1);
}
