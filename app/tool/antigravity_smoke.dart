// ignore_for_file: avoid_print
// Smoke test: Antigravity (`agy acp`, on the signed-in subscription) calls a stub display tool
// over the embedded MCP server, is interrupted, and resumes its conversation in a new process.
// Run: dart run tool/antigravity_smoke.dart [model]
import 'dart:async';
import 'dart:io';

import 'package:minerva/brain/antigravity_session.dart';
import 'package:minerva/brain/brain_session.dart';
import 'package:minerva/mcp/display_mcp_server.dart';

Future<void> main(List<String> args) async {
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
  final workDir = '${Directory.systemTemp.path}/minerva-agy-smoke';
  String? id;
  AntigravitySession open() => AntigravitySession(
        model: args.isEmpty ? 'gemini-3.8-flash-low' : args.first,
        describe: true,
        systemPrompt: 'You are a voice assistant with a display. Speak one short sentence, then use the show tool.',
        mcpUrl: mcp.url,
        workDir: workDir,
        sessionId: id,
        onSessionId: (s) => id = s,
      );
  final t0 = DateTime.now();
  var failed = false;

  Future<TurnDone> turn(AntigravitySession s, String text, {Duration? interruptAfter}) async {
    var first = true;
    final done = s.events.firstWhere((e) => e is TurnDone);
    final sub = s.events.listen((e) {
      final ms = DateTime.now().difference(t0).inMilliseconds;
      switch (e) {
        case TextDelta():
          if (first) print('[$ms ms] first text');
          first = false;
          stdout.write(e.text);
        case ToolStart():
          print('\n[$ms ms] tool start ${e.name}');
        case ToolInput():
          print('[$ms ms] tool input ${e.name} ${e.partialJson}');
        case Described():
          print('[$ms ms] models: ${e.catalog?.version} ${[for (final m in e.catalog?.all ?? []) m.value]}');
        case Compacting() || MessageTaken() || FastModeState():
          break;
        case TurnDone():
          print('\n[$ms ms] done interrupted=${e.interrupted} error=${e.error} result=${e.result.length} chars');
      }
    });
    await s.send(text);
    if (interruptAfter != null) {
      await Future<void>.delayed(interruptAfter);
      s.interrupt();
    }
    final r = await done.timeout(const Duration(seconds: 120)) as TurnDone;
    await sub.cancel();
    return r;
  }

  final catalog = await AntigravitySession.listModels();
  print('agy models: ${catalog?.version} ${catalog?.all.length} models');
  if (catalog == null) failed = true;

  var s = open();
  await s.start();
  print('session $id');
  final a = await turn(s, 'Enséñame tres frutas de otoño en pantalla. Recuerda además el número 42.');
  if (a.error != null || calls.isEmpty) failed = true;

  final b = await turn(s, 'Cuenta despacio del 1 al 200, un número por línea.', interruptAfter: const Duration(seconds: 4));
  if (!b.interrupted) failed = true;
  // Right after an interruption (a barge-in), the next message gets its own turn.
  final b2 = await turn(s, 'Di solo: hola.');
  if (b2.interrupted || b2.error != null || b2.result.isEmpty) failed = true;
  s.dispose();

  // A new process resumes the same conversation.
  s = open();
  final c = await turn(s, '¿Qué número te pedí que recordaras? Responde solo el número, sin usar herramientas.');
  print('resumed $id: "${c.result}"');
  if (!c.result.contains('42')) failed = true;
  s.dispose();

  print('tool calls: $calls');
  await mcp.stop();
  print(failed ? 'FAILED' : 'OK');
  exit(failed ? 1 : 0);
}
