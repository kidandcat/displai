import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:minerva/l10n/l10n.dart';
import 'package:minerva/telegram/telegram.dart';
import 'package:minerva/telegram/telegram_tools.dart';

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

    /// A bot that gets [messages] (from the user's chat 42) once, serves their files, and records
    /// what it sends back.
    Future<(List<String>, List<String>, List<String>)> receive(
      List<Map<String, dynamic>> messages, {
      Future<String> Function(String path)? transcribe,
      bool fileMissing = false,
    }) async {
      final sent = <String>[];
      final transcribed = <String>[];
      var polls = 0;
      final client = MockClient((req) async {
        if (req.url.path.startsWith('/file/botTOKEN/')) {
          if (fileMissing) return http.Response('', 404);
          return http.Response.bytes(utf8.encode('audio:${req.url.pathSegments.last}'), 200);
        }
        final method = req.url.pathSegments.last;
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        switch (method) {
          case 'getUpdates':
            if (polls++ > 0) return Completer<http.Response>().future;
            return http.Response(
                jsonEncode({
                  'ok': true,
                  'result': [for (var i = 0; i < messages.length; i++) update(20 + i, 42, messages[i])],
                }),
                200);
          case 'getFile':
            return http.Response(jsonEncode({'ok': true, 'result': {'file_path': 'voice/${body['file_id']}.oga'}}), 200);
          case 'sendMessage':
            sent.add(body['text'] as String);
        }
        return http.Response(jsonEncode({'ok': true, 'result': true}), 200);
      });
      final got = <String>[];
      final bot = Telegram(
        token: () => 'TOKEN',
        chatId: () => 42,
        dir: tmp.path,
        onMessage: got.add,
        transcribe: transcribe == null
            ? null
            : (path) {
                transcribed.add(File(path).readAsStringSync());
                return transcribe(path);
              },
        api: 'https://api.test',
        client: () => client,
      )..start();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await bot.close();
      return (got, sent, transcribed);
    }

    test('a voice note reaches the brain transcribed and marked as such', () async {
      final (got, sent, transcribed) = await receive([
        {'voice': {'file_id': 'v1', 'duration': 3, 'mime_type': 'audio/ogg'}},
      ], transcribe: (_) async => ' remind me to buy bread ');
      expect(transcribed, ['audio:v1.oga']);
      expect(sent, isEmpty);
      expect(got, hasLength(1));
      expect(got.single, startsWith('(voice note transcribed by speech recognition, so it may have recognition errors; audio saved at ${tmp.path}/files/'));
      expect(got.single, endsWith('v1.oga) remind me to buy bread'));
    });

    test('audio files and recordings sent as files are transcribed, with their caption', () async {
      final (got, _, transcribed) = await receive([
        {'audio': {'file_id': 'a1', 'file_name': 'meeting notes.mp3', 'mime_type': 'audio/mpeg'}, 'caption': 'summarize this'},
        {'document': {'file_id': 'd1', 'file_name': 'memo.m4a', 'mime_type': 'audio/mp4'}},
        {'document': {'file_id': 'd2', 'file_name': 'report.pdf', 'mime_type': 'application/pdf'}},
      ], transcribe: (path) async => 'words of ${path.split('-').last}');
      expect(transcribed, ['audio:a1.oga', 'audio:d1.oga']);
      expect(got, hasLength(3));
      expect(got[0], startsWith('(audio file transcribed by speech recognition'));
      expect(got[0], endsWith('meeting_notes.mp3) summarize this\nTranscript: words of meeting_notes.mp3'));
      expect(got[1], startsWith('(audio file transcribed'));
      expect(got[1], endsWith('memo.m4a) words of memo.m4a'));
      expect(got[2], startsWith('(file saved at '));
    });

    test('a failed transcription, silence or a failed download get a short answer', () async {
      var (got, sent, _) = await receive([
        {'voice': {'file_id': 'v1'}},
      ], transcribe: (_) async => throw Exception('no converter'));
      expect(got, isEmpty);
      expect(sent, [strings.telegramTranscribeFailed]);

      (got, sent, _) = await receive([
        {'voice': {'file_id': 'v2'}},
      ], transcribe: (_) async => '  ');
      expect(got, isEmpty);
      expect(sent, [strings.telegramNoSpeech]);

      final (got3, sent3, transcribed3) = await receive([
        {'voice': {'file_id': 'v3'}},
      ], transcribe: (_) async => 'never', fileMissing: true);
      expect(got3, isEmpty);
      expect(transcribed3, isEmpty);
      expect(sent3, [strings.telegramDownloadFailed]);
    });

    test('without a recognizer, audio gets the "not supported" answer', () async {
      final (got, sent, _) = await receive([
        {'voice': {'file_id': 'v1'}},
        {'audio': {'file_id': 'a1'}},
      ]);
      expect(got, isEmpty);
      expect(sent, [strings.telegramUnsupported, strings.telegramUnsupported]);
    });

    test('the prompt tells the brain about transcribed recordings', () {
      final bot = Telegram(token: () => 'TOKEN', chatId: () => 42, dir: tmp.path, onMessage: (_) {});
      expect(bot.promptSection(), contains('(voice note transcribed'));
      expect(bot.promptSection(), contains('recognition errors'));
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

    test('reachable only with a token and a chat', () {
      String? token = 'TOKEN';
      int? chat;
      final bot = Telegram(token: () => token, chatId: () => chat, dir: tmp.path, onMessage: (_) {});
      expect(bot.reachable, isFalse);
      chat = 42;
      expect(bot.reachable, isTrue);
      token = null;
      expect(bot.reachable, isFalse);
    });

    group('sending files', () {
      /// A bot whose API records each upload (method, multipart body as text) and answers with
      /// [reply] (null: ok).
      (Telegram, List<(String, String)>) bot({
        http.Response? Function(String method)? reply,
        int? chat = 42,
        String? token = 'TOKEN',
      }) {
        final calls = <(String, String)>[];
        final client = MockClient((req) async {
          final method = req.url.pathSegments.last;
          calls.add((method, latin1.decode(req.bodyBytes)));
          return reply?.call(method) ?? http.Response(jsonEncode({'ok': true, 'result': {}}), 200);
        });
        final t = Telegram(
          token: () => token,
          chatId: () => chat,
          dir: tmp.path,
          onMessage: (_) {},
          api: 'https://api.test',
          client: () => client,
        );
        return (t, calls);
      }

      String file(String name, [int size = 10]) {
        final f = File('${tmp.path}/$name')..writeAsBytesSync(List.filled(size, 65));
        return f.path;
      }

      test('photos by extension, documents otherwise, or as asked', () {
        expect(Telegram.sendsAsPhoto('a.JPG', 100), isTrue);
        expect(Telegram.sendsAsPhoto('a.webp', 100), isTrue);
        expect(Telegram.sendsAsPhoto('a.pdf', 100), isFalse);
        expect(Telegram.sendsAsPhoto('a.gif', 100), isFalse);
        expect(Telegram.sendsAsPhoto('a.png', 100, as: 'document'), isFalse);
        expect(Telegram.sendsAsPhoto('a.bmp', 100, as: 'photo'), isTrue);
        // Too big for sendPhoto.
        expect(Telegram.sendsAsPhoto('a.png', Telegram.maxPhoto + 1), isFalse);
        expect(Telegram.sendsAsPhoto('a.png', Telegram.maxPhoto + 1, as: 'photo'), isFalse);
      });

      test('a photo and a document go to the user\'s chat with their caption', () async {
        final (t, calls) = bot();
        expect(await t.sendFiles([file('pic.png')], caption: 'look'), ['photo pic.png']);
        expect(await t.sendFiles([file('notes.pdf')]), ['document notes.pdf']);
        expect(calls.map((c) => c.$1), ['sendPhoto', 'sendDocument']);
        expect(calls[0].$2, contains('name="chat_id"\r\n\r\n42'));
        expect(calls[0].$2, contains('name="caption"\r\n\r\nlook'));
        expect(calls[0].$2, contains('name="photo"; filename="pic.png"'));
        expect(calls[1].$2, contains('name="document"; filename="notes.pdf"'));
        expect(calls[1].$2, isNot(contains('name="caption"')));
        await t.close();
      });

      test('a photo Telegram rejects is sent again as a document', () async {
        final (t, calls) = bot(
            reply: (m) => m == 'sendPhoto'
                ? http.Response(jsonEncode({'ok': false, 'error_code': 400, 'description': 'PHOTO_INVALID_DIMENSIONS'}), 400)
                : null);
        final sent = await t.sendFiles([file('wide.jpg')]);
        expect(sent.single, startsWith('document wide.jpg'));
        expect(sent.single, contains('PHOTO_INVALID_DIMENSIONS'));
        expect(calls.map((c) => c.$1), ['sendPhoto', 'sendDocument']);
        await t.close();
      });

      test('several files go as albums of up to ten, documents with documents', () async {
        final (t, calls) = bot();
        final photos = [for (var i = 0; i < 11; i++) file('p$i.jpg')];
        final sent = await t.sendFiles(photos, caption: 'trip');
        expect(calls.map((c) => c.$1), ['sendMediaGroup', 'sendPhoto']);
        expect(sent.first, startsWith('photo album: p0.jpg, p1.jpg'));
        expect(sent.last, 'photo p10.jpg');
        final album = calls.first.$2;
        expect(album, contains('"type":"photo","media":"attach://file0","caption":"trip"'));
        expect(album, contains('attach://file9'));
        expect(album, contains('name="file9"; filename="p9.jpg"'));
        // The caption goes only with the first file.
        expect(calls.last.$2, isNot(contains('name="caption"')));

        calls.clear();
        await t.sendFiles([file('a.jpg'), file('b.zip')]);
        expect(calls.single.$1, 'sendMediaGroup');
        expect(calls.single.$2, contains('"type":"document","media":"attach://file0"'));
        expect(calls.single.$2, isNot(contains('"type":"photo"')));
        await t.close();
      });

      test('a caption too long for Telegram follows as a message', () async {
        final (t, calls) = bot();
        final sent = await t.sendFiles([file('a.txt')], caption: 'x' * (Telegram.maxCaption + 1));
        expect(calls.map((c) => c.$1), ['sendDocument', 'sendMessage']);
        expect(calls.first.$2, isNot(contains('name="caption"')));
        expect(sent.last, contains('caption as a message'));
        await t.close();
      });

      test('missing, empty and too large files, no chat and API errors are errors', () async {
        final (t, calls) = bot(
            reply: (m) => http.Response(jsonEncode({'ok': false, 'error_code': 403, 'description': 'Forbidden: bot was blocked by the user'}), 403));
        Future<String> error(Future<Object?> f) async {
          try {
            await f;
          } on TelegramException catch (e) {
            return e.message;
          }
          fail('no error');
        }

        expect(await error(t.sendFiles(['${tmp.path}/nope.png'])), contains('not found'));
        expect(await error(t.sendFiles([file('empty.txt', 0)])), contains('empty'));
        final big = File('${tmp.path}/big.mov');
        final raf = big.openSync(mode: FileMode.write)..truncateSync(Telegram.maxUpload + 1);
        raf.closeSync();
        expect(await error(t.sendFiles([big.path])), contains('at most 50.0 MB'));
        expect(calls, isEmpty);
        expect(await error(t.sendFiles([file('a.png')])), contains('blocked'));
        await t.close();

        final (noChat, _) = bot(chat: null);
        expect(await error(noChat.sendFiles([file('a.png')])), contains('write to the bot first'));
        final (noToken, _) = bot(token: null);
        expect(await error(noToken.sendFiles([file('a.png')])), contains('not set up'));
      });

      test('the tool resolves paths and reports the result', () async {
        final (t, calls) = bot();
        final tools = TelegramTools(t, home: tmp.path);
        file('report.pdf');
        file('a.png');
        var r = await tools.call('telegram_send_file', {'path': '~/report.pdf', 'caption': 'here'});
        expect(r.isError, isFalse);
        expect(r.text, 'sent to the user on Telegram: document report.pdf');
        r = await tools.call('telegram_send_file', {'path': 'report.pdf', 'more_paths': ['a.png'], 'as': 'document'});
        expect(r.text, contains('document album: report.pdf, a.png'));
        r = await tools.call('telegram_send_file', {'path': 'missing.png'});
        expect(r.isError, isTrue);
        expect(r.text, startsWith('error: not sent: not found'));
        r = await tools.call('telegram_send_file', {'path': 'a.png', 'as': 'video'});
        expect(r.isError, isTrue);
        expect(calls, hasLength(2));
        await t.close();
      });
    });
  });

  group('where notices are answered', () {
    bool here({bool reachable = true, bool lastOnTelegram = false, bool windowOpen = true, bool onPhone = false}) =>
        Telegram.answersNotice(
            reachable: reachable, lastOnTelegram: lastOnTelegram, windowOpen: windowOpen, onPhone: onPhone);

    test('spoken while the user is at the Mac (window open, also as the orb) or on the phone', () {
      expect(here(), isFalse);
      expect(here(onPhone: true), isFalse);
      expect(here(windowOpen: false, onPhone: true), isFalse);
    });

    test('on Telegram when the window is closed or the user last wrote there', () {
      expect(here(windowOpen: false), isTrue);
      expect(here(lastOnTelegram: true), isTrue);
      expect(here(lastOnTelegram: true, onPhone: true), isTrue);
    });

    test('never when the chat cannot be written to', () {
      expect(here(reachable: false, windowOpen: false), isFalse);
      expect(here(reachable: false, lastOnTelegram: true), isFalse);
    });
  });
}
