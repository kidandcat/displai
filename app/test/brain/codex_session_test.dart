import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/brain/brain_session.dart';
import 'package:minerva/brain/codex_session.dart';
import 'package:minerva/brain/fallback.dart';

/// A session with no process: its turn's notifications are fed to it by hand, as
/// `codex app-server` sends them.
CodexSession _session() =>
    CodexSession(model: 'gpt-6-astra', systemPrompt: '', mcpUrl: '', workDir: '/tmp', sessionId: 'thread-1')
      ..busy = true;

Future<List<BrainEvent>> _events(CodexSession s, List<(String, Map<String, dynamic>)> notifications) async {
  final events = <BrainEvent>[];
  final sub = s.events.listen(events.add);
  for (final (method, params) in notifications) {
    s.onNotification(method, params);
  }
  await Future<void>.delayed(Duration.zero);
  await sub.cancel();
  return events;
}

void main() {
  test('a turn becomes text, tool calls and its end, with the last message as its result', () async {
    final s = _session();
    final events = await _events(s, [
      ('turn/started', {'threadId': 'thread-1', 'turn': {'id': 'turn-1'}}),
      ('item/agentMessage/delta', {'threadId': 'thread-1', 'itemId': 'm1', 'delta': 'Te lo '}),
      ('item/agentMessage/delta', {'threadId': 'thread-1', 'itemId': 'm1', 'delta': 'enseño.'}),
      ('item/completed', {'threadId': 'thread-1', 'item': {'type': 'agentMessage', 'id': 'm1', 'text': 'Te lo enseño.'}}),
      ('item/started', {'threadId': 'thread-1', 'item': {'type': 'webSearch', 'id': 'w1', 'query': 'otoño'}}),
      (
        'item/started',
        {
          'threadId': 'thread-1',
          'item': {
            'type': 'mcpToolCall',
            'id': 't1',
            'server': 'minerva',
            'tool': 'show',
            'arguments': {'title': 'Frutas'},
            'status': 'inProgress',
          },
        },
      ),
      ('item/started', {'threadId': 'thread-1', 'item': {'type': 'contextCompaction', 'id': 'c1'}}),
      ('item/completed', {'threadId': 'thread-1', 'item': {'type': 'contextCompaction', 'id': 'c1'}}),
      // Another thread's notifications are not this session's.
      ('item/agentMessage/delta', {'threadId': 'other', 'itemId': 'x', 'delta': 'nope'}),
      ('item/completed', {'threadId': 'thread-1', 'item': {'type': 'agentMessage', 'id': 'm2', 'text': 'Listo.'}}),
      ('turn/completed', {'threadId': 'thread-1', 'turn': {'id': 'turn-1', 'status': 'completed'}}),
    ]);
    expect([for (final e in events.whereType<TextDelta>()) e.text], ['Te lo ', 'enseño.']);
    expect([for (final e in events.whereType<ToolStart>()) (e.index, e.name)], [(0, 'web_search'), (1, 'show')]);
    final input = events.whereType<ToolInput>().single;
    expect((input.index, input.name, input.partialJson), (1, 'show', '{"title":"Frutas"}'));
    expect([for (final e in events.whereType<Compacting>()) e.active], [true, false]);
    final done = events.whereType<TurnDone>().single;
    expect((done.interrupted, done.error, done.result, done.limit), (false, null, 'Listo.', null));
    expect(s.busy, isFalse);
  });

  test("Codex's usage limit is a limit, with the reset of its full window", () async {
    final s = _session();
    final reset = DateTime(2026, 11, 25, 18);
    final events = await _events(s, [
      (
        'account/rateLimits/updated',
        {
          'rateLimits': {
            'primary': {'usedPercent': 100, 'windowDurationMins': 300, 'resetsAt': reset.millisecondsSinceEpoch ~/ 1000},
            'secondary': {'usedPercent': 40, 'windowDurationMins': 10080, 'resetsAt': 1999999999},
          },
        },
      ),
      (
        'turn/completed',
        {
          'threadId': 'thread-1',
          'turn': {
            'id': 'turn-1',
            'status': 'failed',
            'error': {'message': "You've hit your usage limit.", 'codexErrorInfo': 'usageLimitExceeded'},
          },
        },
      ),
    ]);
    final done = events.whereType<TurnDone>().single;
    expect(done.error, "You've hit your usage limit.");
    expect(done.limit?.reason, LimitReason.usage);
    expect(done.limit?.resetsAt, reset);
  });

  test('a lost login is a sign-in limit', () async {
    final s = _session();
    final events = await _events(s, [
      (
        'error',
        {
          'threadId': 'thread-1',
          'willRetry': false,
          'error': {
            'message': 'Your access token could not be refreshed. Please log out and sign in again.',
            'codexErrorInfo': 'unauthorized',
          },
        },
      ),
      ('turn/completed', {'threadId': 'thread-1', 'turn': {'id': 'turn-1', 'status': 'failed'}}),
    ]);
    final done = events.whereType<TurnDone>().single;
    expect(done.limit?.reason, LimitReason.signIn);
    expect(done.error, startsWith(CodexSession.notSignedIn));
  });

  test('an interrupted turn ends without error', () async {
    final s = _session();
    final events = await _events(s, [
      ('turn/completed', {'threadId': 'thread-1', 'turn': {'id': 'turn-1', 'status': 'interrupted'}}),
    ]);
    final done = events.whereType<TurnDone>().single;
    expect((done.interrupted, done.error, done.limit), (true, null, null));
  });

  test('other errors are not limits', () {
    expect(CodexSession.limitOf({'message': 'boom', 'codexErrorInfo': 'contextWindowExceeded'}), isNull);
    expect(CodexSession.limitOf({'message': 'stream error: 429 Too Many Requests'})?.reason, LimitReason.usage);
    expect(CodexSession.limitOf({'message': 'x', 'codexErrorInfo': 'rateLimitExceeded'})?.reason, LimitReason.usage);
    expect(CodexSession.limitOf(null), isNull);
  });

  test("Codex's own extras are off, and the brain has no shell", () {
    expect(CodexSession.versionOf('minerva/0.154.0 (Mac OS 26.6.0; arm64) xterm'), '0.154.0');
    expect(CodexSession.versionOf(null), '');
    final brain = CodexSession.overrides(shell: false);
    expect(brain, containsAll(['notify=[]', 'features.plugins=false', 'features.memories=false', 'features.shell_tool=false']));
    final worker = CodexSession.overrides(shell: true);
    expect(worker, contains('features.hooks=false'));
    expect(worker, isNot(contains('features.shell_tool=false')));
  });
}
