import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:minerva/telegram/telegram.dart';

void main() {
  group('markdown to Telegram HTML', () {
    test('emphasis, code and links', () {
      expect(TelegramFormat.toHtml('**bold** and *it* and _it2_ and ~~gone~~'),
          '<b>bold</b> and <i>it</i> and <i>it2</i> and <s>gone</s>');
      expect(TelegramFormat.toHtml('run `a <b> & *c*` now'), 'run <code>a &lt;b&gt; &amp; *c*</code> now');
      expect(TelegramFormat.toHtml('see [the **docs**](https://x.dev/a_b?q=1&r=2)'),
          'see <a href="https://x.dev/a_b?q=1&amp;r=2">the <b>docs</b></a>');
    });

    test('leaves plain text alone and escapes it', () {
      expect(TelegramFormat.toHtml('2 * 3 * 4 < 30 & snake_case_name'), '2 * 3 * 4 &lt; 30 &amp; snake_case_name');
      expect(TelegramFormat.toHtml('https://x.dev/a_b_c'), 'https://x.dev/a_b_c');
    });

    test('headings, bullets, quotes and code blocks', () {
      expect(
        TelegramFormat.toHtml('# Title\n- one\n  * two\n> quoted\n> more\n```dart\nif (a < b) {}\n```\nend'),
        '<b>Title</b>\n• one\n  • two\n<blockquote>quoted\nmore</blockquote>\n'
        '<pre><code class="language-dart">if (a &lt; b) {}</code></pre>\nend',
      );
      expect(TelegramFormat.toHtml('```\nopen'), '<pre>open</pre>');
    });
  });

  group('chunks', () {
    test('short text is one chunk', () {
      expect(TelegramFormat.chunks('  hi  '), ['hi']);
      expect(TelegramFormat.chunks(''), isEmpty);
    });

    test('long text is cut at lines, each under the limit, nothing lost', () {
      final lines = [for (var i = 0; i < 400; i++) 'line $i of a long answer']
          .join('\n');
      final chunks = TelegramFormat.chunks(lines, max: 1000);
      expect(chunks.length, greaterThan(1));
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(1000));
      }
      expect(chunks.join('\n').split('\n').where((l) => l.isNotEmpty), lines.split('\n'));
    });

    test('a code block cut in two is closed and reopened', () {
      final text = '```python\n${List.filled(100, 'print("x")').join('\n')}\n```';
      final chunks = TelegramFormat.chunks(text, max: 500);
      expect(chunks.length, greaterThan(1));
      for (final c in chunks) {
        expect(c, startsWith('```python'));
        expect(c, endsWith('```'));
        expect(TelegramFormat.toHtml(c), startsWith('<pre><code class="language-python">'));
      }
    });

    test('a very long line is cut anywhere', () {
      final chunks = TelegramFormat.chunks('x' * 2500, max: 1000);
      expect(chunks.join(), 'x' * 2500);
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(1000));
      }
    });
  });

  group('bot', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('minerva-telegram-test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    Map<String, dynamic> update(int id, int chat, Map<String, dynamic> m) => {
          'update_id': id,
          'message': {'message_id': id, 'chat': {'id': chat}, ...m},
        };

    test('takes only the user\'s chat, keeps the offset, answers what it cannot read', () async {
      final calls = <(String, Map<String, dynamic>)>[];
      var polls = 0;
      final client = MockClient((req) async {
        final method = req.url.pathSegments.last;
        expect(req.url.path, startsWith('/botTOKEN/'));
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        calls.add((method, body));
        if (method == 'getUpdates') {
          if (polls++ > 0) return Completer<http.Response>().future;
          return http.Response(
              jsonEncode({
                'ok': true,
                'result': [
                  update(10, 999, {'text': 'stranger'}),
                  update(11, 42, {'text': 'hola **Minerva**'}),
                  update(12, 42, {'voice': {'file_id': 'v'}}),
                ],
              }),
              200);
        }
        return http.Response(jsonEncode({'ok': true, 'result': true}), 200);
      });
      final got = <String>[];
      final offsets = <int>[];
      final bot = Telegram(
        token: () => 'TOKEN',
        chatId: () => 42,
        dir: tmp.path,
        onMessage: got.add,
        onOffset: offsets.add,
        api: 'https://api.test',
        client: () => client,
      )..start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(got, ['hola **Minerva**']);
      expect(offsets.last, 13);
      expect(bot.online, isTrue);
      // The voice note got an answer, the stranger nothing.
      final sent = [for (final (m, b) in calls) if (m == 'sendMessage') b];
      expect(sent, hasLength(1));
      expect(sent.single['chat_id'], 42);
      await bot.close();
    });

    test('sends HTML, and plain text when Telegram rejects the formatting', () async {
      final sent = <Map<String, dynamic>>[];
      final client = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        sent.add(body);
        if (body['parse_mode'] == 'HTML') {
          return http.Response(jsonEncode({'ok': false, 'error_code': 400, 'description': "can't parse entities"}), 400);
        }
        return http.Response(jsonEncode({'ok': true, 'result': {}}), 200);
      });
      final bot = Telegram(
        token: () => 'TOKEN',
        chatId: () => 42,
        dir: tmp.path,
        onMessage: (_) {},
        api: 'https://api.test',
        client: () => client,
      );
      await bot.send('**hi** & bye');
      expect(sent, [
        {'chat_id': 42, 'text': '<b>hi</b> &amp; bye', 'parse_mode': 'HTML', 'link_preview_options': {'is_disabled': true}},
        {'chat_id': 42, 'text': '**hi** & bye'},
      ]);
      await bot.close();
    });

    test('a webhook on the bot (409) is left alone and reported', () async {
      final methods = <String>[];
      final client = MockClient((req) async {
        methods.add(req.url.pathSegments.last);
        return http.Response(
            jsonEncode({'ok': false, 'error_code': 409, 'description': "Conflict: can't use getUpdates method while webhook is active"}),
            409);
      });
      final bot = Telegram(
        token: () => 'TOKEN',
        chatId: () => 42,
        dir: tmp.path,
        onMessage: (_) {},
        api: 'https://api.test',
        client: () => client,
      )..start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(bot.online, isFalse);
      expect(bot.error, isNotNull);
      expect(methods, ['getUpdates']);
      await bot.close();
    });

    test('without a token it does nothing, and starts when one is saved', () async {
      String? token;
      var polls = 0;
      final client = MockClient((req) async {
        polls++;
        return Completer<http.Response>().future;
      });
      final bot = Telegram(
        token: () => token,
        chatId: () => 42,
        dir: tmp.path,
        onMessage: (_) {},
        api: 'https://api.test',
        client: () => client,
      )..start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(polls, 0);
      expect(bot.promptSection(), isEmpty);
      token = 'TOKEN';
      bot.restart();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(polls, 1);
      expect(bot.promptSection(), contains('[telegram]'));
      await bot.close();
    });
  });
}
