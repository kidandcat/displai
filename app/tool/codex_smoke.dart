// ignore_for_file: avoid_print
// Smoke test: Codex (`codex app-server`, on the signed-in ChatGPT subscription) calls a stub
// display tool over the embedded MCP server, is interrupted, and resumes its conversation in a
// new process. Not signed in, it checks what it can without a turn: the app server starts, lists
// its models, opens a thread with only Minerva's MCP server, and turns fail as a sign-in limit.
// Run: dart run tool/codex_smoke.dart [model]
import 'dart:async';
import 'dart:io';

import 'package:minerva/brain/brain_session.dart';
import 'package:minerva/brain/codex_session.dart';
import 'package:minerva/brain/fallback.dart';
import 'package:minerva/mcp/display_mcp_server.dart';

Future<void> main(List<String> args) async {
  final calls = <String>[];
  final mcp = DisplayMcpServer(
    tools: const [
      McpTool('show', 'Show a view. title = short title, body = list of {type:"text", text}.', {
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
          'body': {
            'type': 'array',
            'items': {'type': 'object'},
          },
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
  final workDir = '${Directory.systemTemp.path}/minerva-codex-smoke';
  String? id;
  CodexSession open({bool requireSignIn = true}) => CodexSession(
    model: args.isEmpty ? 'gpt-6-astra' : args.first,
    effort: 'low',
    describe: true,
    systemPrompt: 'You are a voice assistant with a display. Speak one short sentence, then use the show tool.',
    mcpUrl: mcp.url,
    workDir: workDir,
    sessionId: id,
    onSessionId: (s) => id = s,
    requireSignIn: requireSignIn,
  );
  final t0 = DateTime.now();
  var failed = false;

  Future<TurnDone> turn(CodexSession s, String text, {Duration? interruptAfter}) async {
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
          print(
            '\n[$ms ms] done interrupted=${e.interrupted} error=${e.error} limit=${e.limit} '
            'result=${e.result.length} chars',
          );
      }
    });
    await s.send(text);
    if (interruptAfter != null) {
      await Future<void>.delayed(interruptAfter);
      s.interrupt();
    }
    final r = await done.timeout(const Duration(seconds: 180)) as TurnDone;
    await sub.cancel();
    return r;
  }

  final catalog = await CodexSession.listModels();
  print('codex models: ${catalog?.version} ${catalog?.all.length} models');

  if (catalog == null) {
    // Not signed in (or not installed): check the app server and Minerva's MCP server anyway.
    print('codex is not signed in: checking without turns');
    final s = open(requireSignIn: false);
    final described = s.events.firstWhere((e) => e is Described).timeout(const Duration(seconds: 30));
    await s.start();
    print('thread $id');
    if (id == null) failed = true;
    final models = await described as Described;
    print('models: ${models.catalog?.version} ${[for (final m in models.catalog?.all ?? []) m.value]}');
    for (var i = 0; i < 100 && (s.mcpStatus == null || s.mcpStatus == 'starting'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    print('minerva MCP server: ${s.mcpStatus}');
    if (s.mcpStatus != 'ready') failed = true;
    final a = await turn(s, 'Di solo: hola.');
    if (a.limit?.reason != LimitReason.signIn) failed = true;
    s.dispose();
    try {
      await open().start();
      failed = true;
    } on StateError catch (e) {
      print('signed-in start: $e');
    }
  } else {
    var s = open();
    await s.start();
    print('thread $id, minerva MCP server: ${s.mcpStatus}');
    final a = await turn(s, 'Enséñame tres frutas de otoño en pantalla. Recuerda además el número 42.');
    if (a.limit != null) {
      // Signed in once but the login expired (or out of usage): the app server and Minerva's MCP
      // server work, and the turn fails as a limit the fallback can act on.
      print('codex turn failed as ${a.limit}: run codex login for the full smoke test');
      s.dispose();
      await mcp.stop();
      final ok = s.mcpStatus == 'ready' && id != null;
      print(ok ? 'OK (without turns)' : 'FAILED');
      exit(ok ? 0 : 1);
    }
    if (a.error != null || calls.isEmpty) failed = true;

    final b = await turn(
      s,
      'Cuenta despacio del 1 al 200, un número por línea.',
      interruptAfter: const Duration(seconds: 4),
    );
    if (!b.interrupted) failed = true;
    final b2 = await turn(s, 'Di solo: hola.');
    if (b2.interrupted || b2.error != null || b2.result.isEmpty) failed = true;
    s.dispose();

    // A new process resumes the same conversation.
    s = open();
    final c = await turn(s, '¿Qué número te pedí que recordaras? Responde solo el número, sin usar herramientas.');
    print('resumed $id: "${c.result}"');
    if (!c.result.contains('42')) failed = true;
    s.dispose();
  }

  print('tool calls: $calls');
  await mcp.stop();
  print(failed ? 'FAILED' : 'OK');
  exit(failed ? 1 : 0);
}
