import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'antigravity_session.dart';
import 'claude_session.dart';
import 'codex_session.dart';
import 'fallback.dart';
import 'models.dart';

/// Events from a brain's turn, as the app needs them.
sealed class BrainEvent {}

class TextDelta extends BrainEvent {
  TextDelta(this.text);
  final String text;
}

/// A tool call started streaming (name without the MCP server prefix for Minerva's tools).
class ToolStart extends BrainEvent {
  ToolStart(this.index, this.name);
  final int index;
  final String name;
}

/// Accumulated (partial) JSON arguments of the tool call at [index].
class ToolInput extends BrainEvent {
  ToolInput(this.index, this.name, this.partialJson);
  final int index;
  final String name;
  final String partialJson;
}

/// The brain is compacting the conversation (true) or finished doing so (false).
class Compacting extends BrainEvent {
  Compacting(this.active);
  final bool active;
}

/// The brain took a message sent with [BrainSession.send] into the conversation, either as a new
/// turn or attached to the turn in progress (only with `replayUserMessages`).
class MessageTaken extends BrainEvent {}

/// The agent's description of itself (only with `describe`): [catalog] holds the models it offers;
/// [info] is its raw answer (Claude Code's initialize answer also says whether fast mode is on).
class Described extends BrainEvent {
  Described(this.info, {this.catalog});
  final Map<String, dynamic> info;
  final ModelCatalog? catalog;
}

/// Claude Code's fast mode state after a turn: fast mode can turn off once a request finds the
/// account can't use it (only [reason] then says why, e.g. `extra_usage_disabled`).
class FastModeState extends BrainEvent {
  FastModeState({required this.on, this.reason});
  final bool on;
  final String? reason;
}

class TurnDone extends BrainEvent {
  TurnDone({required this.interrupted, this.error, this.result = '', ProviderLimit? limit})
    : limit = limit ?? (interrupted ? null : limitIn(error));
  final bool interrupted;
  final String? error;

  /// The turn failed because the provider reached its usage limit (or lost its login): another
  /// provider should take over (see [ProviderLimits]). From the agent's own signal when it has one,
  /// else read from [error].
  final ProviderLimit? limit;

  /// The turn's final text (what a worker reports back).
  final String result;
}

/// A long-lived headless agent the conversation (or a worker) runs on, kept warm between turns,
/// with Minerva's tools from an MCP server. One per [BrainProvider]: [ClaudeSession] (Claude
/// Code), [AntigravitySession] (Antigravity's `agy acp`) and [CodexSession] (`codex app-server`).
abstract interface class BrainSession {
  /// Starts (or resumes) [sessionId] for a provider: see [ClaudeSession], [AntigravitySession]
  /// and [CodexSession]. [fileTools]: allow the agent's own read-only file tools besides the
  /// web (workers); [onSessionId] is told the conversation's id when the agent picks it.
  static BrainSession create({
    required BrainProvider provider,
    required String model,
    required String? effort,
    required bool fast,
    required String systemPrompt,
    required String mcpUrl,
    required String workDir,
    required String? sessionId,
    void Function(String id)? onSessionId,
    bool describe = false,
    bool fileTools = false,
    String autocompact = '100k',
    bool replayUserMessages = false,
  }) {
    switch (provider) {
      case BrainProvider.claude:
        final id = sessionId ?? ClaudeSession.newSessionId();
        if (sessionId == null) onSessionId?.call(id);
        return ClaudeSession(
          model: model,
          effort: effort,
          fast: fast,
          describe: describe,
          systemPrompt: systemPrompt,
          mcpUrl: mcpUrl,
          workDir: workDir,
          sessionId: id,
          builtinTools: fileTools ? const ['Read', 'Glob', 'Grep', 'WebSearch', 'WebFetch'] : const ['WebSearch', 'WebFetch'],
          autocompact: autocompact,
          replayUserMessages: replayUserMessages,
        );
      case BrainProvider.antigravity:
        return AntigravitySession(
          model: model,
          describe: describe,
          systemPrompt: systemPrompt,
          mcpUrl: mcpUrl,
          workDir: workDir,
          sessionId: sessionId,
          onSessionId: onSessionId,
          builtinTools: fileTools ? AntigravitySession.fileTools : AntigravitySession.webTools,
          replayUserMessages: replayUserMessages,
        );
      case BrainProvider.codex:
        return CodexSession(
          model: model,
          effort: effort,
          fast: fast,
          describe: describe,
          systemPrompt: systemPrompt,
          mcpUrl: mcpUrl,
          workDir: workDir,
          sessionId: sessionId,
          onSessionId: onSessionId,
          fileTools: fileTools,
          replayUserMessages: replayUserMessages,
        );
    }
  }

  Stream<BrainEvent> get events;

  /// A turn is in progress.
  bool get busy;

  /// The agent's process is up.
  bool get running;

  /// Last stderr lines, for diagnostics.
  String get stderrTail;

  /// Starts the agent, resuming its conversation if it has one. Concurrent calls share one start.
  Future<void> start();

  /// Sends a user message: a new turn, or one the agent folds into the turn in progress.
  Future<void> send(String text);

  /// Stops the turn in progress (its [TurnDone] comes with `interrupted`).
  void interrupt();

  /// Switches the model, effort or fast mode, keeping the conversation.
  void reconfigure({required String model, required String? effort, required bool fast});

  void dispose();
}

/// The user's login-shell environment (so PATH finds the agents from a GUI app), without
/// variables inherited from a parent Claude Code session (effort, session ids, sockets).
Future<Map<String, String>> loginEnvironment() async {
  final shell = Platform.environment['SHELL'] ?? '/bin/zsh';
  final r = await Process.run(shell, ['-lc', 'env -0'], stdoutEncoding: utf8);
  final env = <String, String>{};
  for (final entry in (r.stdout as String).split('\x00')) {
    final i = entry.indexOf('=');
    if (i <= 0) continue;
    env[entry.substring(0, i)] = entry.substring(i + 1);
  }
  if (env.isEmpty) env.addAll(Platform.environment);
  env.removeWhere((k, _) => k.startsWith('CLAUDE') || k == 'CLAUDECODE' || k.startsWith('OPENBOT'));
  env['PATH'] ??= '/usr/bin:/bin:/usr/sbin:/sbin';
  return env;
}

/// The path of [cmd] on [path] or in the usual install folders, else null.
String? findExecutable(String cmd, String path) {
  for (final dir in [
    ...path.split(':'),
    '${Platform.environment['HOME']}/.local/bin',
    '/opt/homebrew/bin',
    '/usr/local/bin',
  ]) {
    final f = File('$dir/$cmd');
    if (f.existsSync()) return f.path;
  }
  return null;
}
