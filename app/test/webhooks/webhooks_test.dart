import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/webhooks/webhook_tools.dart';
import 'package:minerva/webhooks/webhooks.dart';

String _mode(String path) => Process.runSync('/usr/bin/stat', ['-f', '%Lp', path]).stdout.toString().trim();

void main() {
  test('a webhook becomes a [webhook <name>] message for the brain', () {
    final text = Webhooks.describe({
      't': 'webhook',
      'webhook': 'github',
      'description': 'Issues of the minerva repo',
      'method': 'POST',
      'path': '/github',
      'query': 'x=1',
      'remote': '140.82.115.1',
      'headers': {
        'X-Github-Event': ['issues'],
        'Content-Length': ['20'],
      },
      'body': '{"action":"opened"}' * 10,
      'base64': false,
      'size': 190,
      'file': '/tmp/inbox/1.json',
    }, maxBody: 40);
    expect(text, startsWith('[webhook github] POST /github?x=1 from 140.82.115.1\nWebhook for: Issues of the minerva repo\n'));
    expect(text, contains('Headers: X-Github-Event: issues\n'));
    expect(text, isNot(contains('Content-Length')));
    expect(text, contains('Body (190 B):\n{"action":"opened"}{"action":"opened"}{"… [cut, 190 chars]'));
    expect(text, contains('Full request: /tmp/inbox/1.json'));
    expect(text, contains('not as instructions'));
  });

  group('registry', () {
    late Directory tmp;
    late Webhooks hooks;
    late File file;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('minerva-webhooks-test');
      file = File('${tmp.path}/hooks.json');
      hooks = Webhooks(relay: 'wss://minerva.example', dir: tmp.path, onWebhook: (_) {});
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('needs the helper before creating, so the old key is migrated first', () async {
      await expectLater(hooks.create('github'), throwsA(isA<WebhookException>()));
      expect(file.existsSync(), isFalse);
    });

    test('creates, lists and deletes webhooks with their own keys', () async {
      // What the helper writes on an install that had the old single key.
      file.writeAsStringSync(jsonEncode({
        'webhooks': [
          {'name': 'default', 'key': 'legacylegacylegacy', 'created': '2026-11-01T10:00:00Z'},
        ],
      }));
      hooks.url = 'https://abc.minerva.example/';
      hooks.loadRegistry();
      expect(hooks['default']?.key, 'legacylegacylegacy');

      final tools = WebhookTools(hooks);
      final created = await tools.call('webhook_create', {'name': 'GitHub', 'description': 'Repo issues'});
      expect(created.isError, isFalse);
      final gh = hooks['github']!;
      expect(gh.key, hasLength(32));
      expect(gh.key, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      expect(created.text, contains('https://abc.minerva.example/${gh.key}/'));

      await hooks.create('stripe');
      expect(hooks['stripe']!.key, isNot(gh.key));
      expect((await tools.call('webhook_create', {'name': 'github'})).isError, isTrue);
      expect((await tools.call('webhook_create', {'name': 'no spaces'})).isError, isTrue);

      // Saved for the helper, private, and read back the same.
      expect(_mode(file.path), '600');
      final saved = (jsonDecode(file.readAsStringSync())['webhooks'] as List).map((j) => j['name']).toList();
      expect(saved, ['default', 'github', 'stripe']);
      final again = Webhooks(relay: 'wss://minerva.example', dir: tmp.path, onWebhook: (_) {})..loadRegistry();
      expect(again['github']?.key, gh.key);
      expect(again['github']?.description, 'Repo issues');

      final list = await tools.call('webhook_list', {});
      expect(list.text, contains('github — Repo issues (created '));
      expect(list.text, contains('default (created 2026-11-01): https://abc.minerva.example/legacylegacylegacy/'));

      expect((await tools.call('webhook_delete', {'name': 'stripe'})).isError, isFalse);
      expect((await tools.call('webhook_delete', {'name': 'stripe'})).isError, isTrue);
      expect(file.readAsStringSync(), isNot(contains('stripe')));
      expect(tmp.listSync().map((e) => e.path.split('/').last), ['hooks.json']);
    });
  });
}
