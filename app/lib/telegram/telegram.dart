import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../l10n/l10n.dart';

class TelegramException implements Exception {
  TelegramException(this.code, this.message);

  /// Telegram's error_code (HTTP status), 0 for network errors.
  final int code;
  final String message;

  @override
  String toString() => 'telegram $code: $message';
}

/// The written channel: a Telegram bot the user chats with when they can't talk or listen
/// (docs/design.md §3.10).
///
/// It long-polls getUpdates from the Mac (no public webhook needed). Only messages from [chatId]
/// reach the brain, through [onMessage]; anything else is ignored without an answer. The token is
/// read from the vault at each request ([token]), so a token saved or replaced while the app runs
/// is picked up by [restart].
///
/// A token that has a webhook set (or another program polling it) gets 409 from getUpdates: the
/// webhook is left alone (it belongs to whatever set it) and polling retries every few minutes.
class Telegram extends ChangeNotifier {
  Telegram({
    required this.token,
    required this.chatId,
    required this.dir,
    required this.onMessage,
    this.transcribe,
    this.offset = 0,
    this.onOffset,
    this.api = 'https://api.telegram.org',
    http.Client Function()? client,
  }) : _newClient = client ?? http.Client.new;

  /// The bot's token (null or empty: Telegram is off).
  final String? Function() token;

  /// The only chat whose messages are taken (the user's private chat with the bot).
  final int? Function() chatId;

  /// Where photos and files the user sends are saved (`<dir>/files`).
  final String dir;

  /// A message from the user, as the brain gets it (without the `[telegram]` tag).
  final void Function(String text) onMessage;

  /// The transcript of a saved voice note or audio file (empty when there is no speech in it), by
  /// the local speech recognizer. Null: audio gets the "not supported" answer.
  final Future<String> Function(String path)? transcribe;

  /// The next update to ask for; [onOffset] is told each new one, to keep it across restarts.
  int offset;
  final void Function(int offset)? onOffset;

  final String api;
  final http.Client Function() _newClient;
  late http.Client _client = _newClient();

  /// Polling works.
  bool online = false;

  /// Why it does not (no token, token rejected, webhook set…), or null.
  String? error;

  bool _running = false;
  bool _closed = false;
  String? _polledToken;
  Completer<void> _wake = Completer<void>();
  Future<void> _sends = Future.value();
  int _failures = 0;

  /// A token is saved.
  bool get configured => (token() ?? '').isNotEmpty;

  /// Minerva can write to the user: a token and their chat are saved.
  bool get reachable => configured && chatId() != null;

  /// A worker report, routine, webhook or other notice (not something the user did) is answered
  /// on Telegram, not spoken, when the chat is [reachable] and the user is not at the Mac: they
  /// last wrote on Telegram, or nobody hears the Mac, because Minerva's window is closed (the app
  /// runs in the background without its mic and voice) and no phone is connected. The corner orb
  /// counts as open: the user is at the Mac working in other apps.
  static bool answersNotice({
    required bool reachable,
    required bool lastOnTelegram,
    required bool windowOpen,
    required bool onPhone,
  }) =>
      reachable && (lastOnTelegram || (!windowOpen && !onPhone));

  /// Starts polling (in the background; it waits while there is no token).
  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop());
  }

  /// Polls again at once with the current token (it was saved, replaced or deleted).
  void restart() {
    if (token() == _polledToken && online) return;
    _client.close();
    _client = _newClient();
    if (!_wake.isCompleted) _wake.complete();
  }

  Future<void> _sleep(Duration d) => Future.any([Future<void>.delayed(d), _wake.future]);

  Future<void> _loop() async {
    while (!_closed) {
      if (_wake.isCompleted) _wake = Completer<void>();
      final t = token() ?? '';
      _polledToken = t;
      if (t.isEmpty) {
        _setState(false, null);
        await _wake.future;
        continue;
      }
      try {
        final updates = await _call('getUpdates', {
          'offset': offset,
          'timeout': 50,
          'allowed_updates': ['message'],
        }, timeout: const Duration(seconds: 65));
        _failures = 0;
        _setState(true, null);
        for (final u in updates as List) {
          final m = u as Map<String, dynamic>;
          offset = (m['update_id'] as num).toInt() + 1;
          onOffset?.call(offset);
          final msg = m['message'];
          if (msg is Map<String, dynamic>) await _onUpdate(msg);
        }
      } on TelegramException catch (e) {
        if (_closed || _wake.isCompleted) continue;
        debugPrint('telegram: $e');
        if (e.code == 401 || e.code == 404) {
          // The token is wrong or revoked: wait until it changes.
          _setState(false, strings.telegramBadToken);
          await _wake.future;
        } else if (e.code == 409) {
          // A webhook is set or another program polls this bot: never take it over.
          _setState(false, strings.telegramConflict);
          await _sleep(const Duration(minutes: 5));
        } else {
          _setState(false, e.message);
          await _sleep(_backoff());
        }
      } catch (e) {
        if (_closed || _wake.isCompleted) continue;
        debugPrint('telegram: ${_scrub('$e')}');
        _setState(false, _scrub('$e'));
        await _sleep(_backoff());
      }
    }
  }

  Duration _backoff() => Duration(seconds: 2 << (_failures++).clamp(0, 5));

  void _setState(bool online, String? error) {
    if (this.online == online && this.error == error) return;
    this.online = online;
    this.error = error;
    notifyListeners();
  }

  Future<void> _onUpdate(Map<String, dynamic> m) async {
    final chat = (m['chat'] as Map?)?['id'];
    final allowed = chatId();
    if (allowed == null || chat != allowed) {
      // Not the user: no answer at all, so the bot gives nothing away.
      debugPrint('telegram: ignored a message from chat $chat${allowed == null ? ' (no chat configured)' : ''}');
      return;
    }
    final text = '${m['text'] ?? m['caption'] ?? ''}'.trim();
    final hearing = transcribe != null;
    String? saved;
    String? kind;
    try {
      if (m['photo'] is List && (m['photo'] as List).isNotEmpty) {
        kind = 'photo';
        saved = await _download(_bestPhoto(m['photo'] as List)['file_id'] as String, m, 'jpg');
      } else if (m['voice'] is Map && hearing) {
        kind = 'voice';
        saved = await _download((m['voice'] as Map)['file_id'] as String, m, null);
      } else if (m['audio'] is Map && hearing) {
        final a = m['audio'] as Map;
        kind = 'audio';
        saved = await _download(a['file_id'] as String, m, null, name: a['file_name'] as String?);
      } else if (m['document'] is Map) {
        final d = m['document'] as Map;
        // A recording sent as a file is still audio.
        kind = hearing && '${d['mime_type']}'.startsWith('audio/') ? 'audio' : 'file';
        saved = await _download(d['file_id'] as String, m, null, name: d['file_name'] as String?);
      }
    } catch (e) {
      debugPrint('telegram: could not download the $kind: ${_scrub('$e')}');
      await send(strings.telegramDownloadFailed);
      return;
    }
    if (kind == null && text.isEmpty) {
      // Video, stickers, locations… (and audio without a recognizer): nothing the brain can take yet.
      await send(strings.telegramUnsupported);
      return;
    }
    final b = StringBuffer();
    if (kind == 'voice' || kind == 'audio') {
      unawaited(typing());
      final String transcript;
      try {
        transcript = (await transcribe!(saved!)).trim();
      } catch (e) {
        debugPrint('telegram: could not transcribe the $kind: $e');
        await send(strings.telegramTranscribeFailed);
        return;
      }
      if (transcript.isEmpty && text.isEmpty) {
        await send(strings.telegramNoSpeech);
        return;
      }
      b.write('(${kind == 'voice' ? 'voice note' : 'audio file'} transcribed by speech recognition, '
          'so it may have recognition errors; audio saved at $saved) ');
      if (text.isNotEmpty) b.write('$text\nTranscript: ');
      b.write(transcript.isEmpty ? '(no speech in it)' : transcript);
      onMessage(b.toString().trim());
      return;
    }
    if (saved != null) {
      b.write(kind == 'photo'
          ? '(photo saved at $saved; look at it with read_file) '
          : '(file saved at $saved) ');
    }
    b.write(text);
    onMessage(b.toString().trim());
  }

  /// The largest size up to about 1600 px, else the smallest (Telegram lists them smallest first).
  static Map<String, dynamic> _bestPhoto(List sizes) {
    Map<String, dynamic> best = sizes.first as Map<String, dynamic>;
    for (final s in sizes.cast<Map<String, dynamic>>()) {
      final w = (s['width'] as num?) ?? 0, h = (s['height'] as num?) ?? 0;
      if (w <= 1600 && h <= 1600) best = s;
    }
    return best;
  }

  Future<String> _download(String fileId, Map<String, dynamic> m, String? ext, {String? name}) async {
    final f = await _call('getFile', {'file_id': fileId}) as Map<String, dynamic>;
    final path = f['file_path'] as String;
    final r = await _client.get(Uri.parse('$api/file/bot${token()}/$path'));
    if (r.statusCode != 200) throw TelegramException(r.statusCode, 'download failed');
    final safe = (name ?? path.split('/').last).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final stamp = DateTime.now().toIso8601String().substring(0, 19).replaceAll(':', '-');
    var file = '$dir/files/$stamp-${m['message_id']}-$safe';
    if (ext != null && !file.toLowerCase().endsWith('.$ext')) file = '$file.$ext';
    await File(file).create(recursive: true);
    await File(file).writeAsBytes(r.bodyBytes, flush: true);
    return file;
  }

  /// Sends [markdown] to the user: as Telegram HTML, split under Telegram's 4096 characters, in
  /// plain text when Telegram rejects the formatting. Sends go out one after the other.
  Future<void> send(String markdown) {
    final done = _sends.then((_) async {
      final chat = chatId();
      if (chat == null || !configured) return;
      for (final chunk in TelegramFormat.chunks(markdown)) {
        final html = TelegramFormat.toHtml(chunk);
        try {
          if (html.length > TelegramFormat.maxLength) throw TelegramException(400, 'too long as HTML');
          await _call('sendMessage', {
            'chat_id': chat,
            'text': html,
            'parse_mode': 'HTML',
            'link_preview_options': {'is_disabled': true},
          });
        } on TelegramException catch (e) {
          if (e.code != 400) rethrow;
          debugPrint('telegram: sending as plain text ($e)');
          await _call('sendMessage', {'chat_id': chat, 'text': chunk});
        }
      }
    });
    _sends = done.catchError((Object e) => debugPrint('telegram: send failed: ${_scrub('$e')}'));
    return _sends;
  }

  /// Shows "typing…" in the chat for about five seconds.
  Future<void> typing() async {
    final chat = chatId();
    if (chat == null || !configured) return;
    try {
      await _call('sendChatAction', {'chat_id': chat, 'action': 'typing'});
    } catch (_) {}
  }

  Future<Object?> _call(String method, Map<String, dynamic> params, {Duration timeout = const Duration(seconds: 30)}) async {
    final t = token() ?? '';
    if (t.isEmpty) throw TelegramException(401, 'no token');
    final http.Response r;
    try {
      r = await _client
          .post(Uri.parse('$api/bot$t/$method'), headers: {'content-type': 'application/json'}, body: jsonEncode(params))
          .timeout(timeout);
    } catch (e) {
      // Network errors can carry the URL, and so the token.
      throw TelegramException(0, _scrub('$e'));
    }
    Map<String, dynamic> j;
    try {
      j = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      throw TelegramException(r.statusCode, 'HTTP ${r.statusCode}');
    }
    if (j['ok'] != true) throw TelegramException((j['error_code'] as num?)?.toInt() ?? r.statusCode, '${j['description']}');
    return j['result'];
  }

  String _scrub(String s) {
    final t = token() ?? '';
    return t.isEmpty ? s : s.replaceAll(t, '<token>');
  }

  /// What the brain is told about Telegram (empty when it is off).
  String promptSection() {
    if (!configured) return '';
    return '''
Telegram (the written channel):
- "[telegram]" after the time means the user wrote to you on Telegram (typed, unless marked as a transcribed recording): they can't talk or listen now. Your reply is sent back to them on Telegram as text, not spoken, so the voice rules don't apply: write it (Markdown allowed: **bold**, *italic*, `code`, lists, links), as long as the answer needs, still to the point.
- A Telegram message that starts "(voice note transcribed…" or "(audio file transcribed…" is a recording the user sent, transcribed locally: read past likely recognition errors as you do with speech, and ask if something important is unclear. Your reply is still written.
- Don't use the display or Minerva's window for a Telegram message (the user is not at the Mac) unless they ask for it; put everything in the text. Don't ask for credentials with vault_request there: ask the user to save them in Minerva's settings.
- A "[telegram]" in front of a worker report, routine, webhook or other event means the user is away from the Mac (they last wrote on Telegram, or Minerva's window is closed): your reply goes to Telegram as text too, written as above.''';
  }

  Future<void> close() async {
    _closed = true;
    if (!_wake.isCompleted) _wake.complete();
    _client.close();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

/// Markdown (as the brain writes it) to the HTML subset Telegram takes, and splitting.
abstract final class TelegramFormat {
  static const maxLength = 4096;

  /// Source chunks are kept under this, so the HTML (a bit longer) still fits [maxLength].
  static const chunkLength = 3500;

  static final _fence = RegExp(r'^\s*```');

  /// [text] in pieces of at most [max] characters, cut at blank lines, else at line ends, else
  /// anywhere. A code block cut in two is closed and reopened.
  static List<String> chunks(String text, {int max = chunkLength}) {
    text = text.trim();
    if (text.isEmpty) return const [];
    if (text.length <= max) return [text];
    final out = <String>[];
    final cur = StringBuffer();
    var inFence = false;
    var fenceOpen = '```';
    void flush() {
      var s = cur.toString().trimRight();
      cur.clear();
      if (inFence) {
        s = '$s\n```';
        cur.write(fenceOpen);
      }
      if (s.trim().isNotEmpty && s.trim() != '```') out.add(s);
    }

    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      // A single line longer than a chunk: cut it.
      while (line.length > max - 8) {
        if (cur.isNotEmpty) flush();
        cur.write(line.substring(0, max - 8));
        flush();
        line = line.substring(max - 8);
      }
      if (cur.length + line.length + 1 > max - 4) {
        flush();
      } else if (line.trim().isEmpty && cur.length > max * 3 ~/ 4 && !inFence) {
        // Near the limit: a paragraph break is a good place to cut.
        flush();
        continue;
      }
      if (cur.isNotEmpty) cur.write('\n');
      cur.write(line);
      if (_fence.hasMatch(line)) {
        inFence = !inFence;
        if (inFence) fenceOpen = line.trim();
      }
    }
    inFence = false;
    flush();
    return out;
  }

  static String _escape(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  static final _inlineCode = RegExp(r'`([^`\n]+)`');
  static final _link = RegExp(r'\[([^\]\n]+)\]\((https?://[^\s)]+)\)');
  static final _bold = RegExp(r'\*\*(?=\S)(.+?)(?<=\S)\*\*|__(?=\S)(.+?)(?<=\S)__');
  static final _italic = RegExp(r'(?<![\w*])\*(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*(?![\w*])|(?<!\w)_(?=[^\s_])([^_\n]+?)(?<=[^\s_])_(?!\w)');
  static final _strike = RegExp(r'~~(?=\S)(.+?)(?<=\S)~~');
  static final _heading = RegExp(r'^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$');
  static final _bullet = RegExp(r'^(\s*)[-*+]\s+');
  static final _quote = RegExp(r'^\s*>\s?');

  /// [markdown] as Telegram HTML: bold, italic, strikethrough, inline code, code blocks, links,
  /// headings (bold), bullets (•) and quotes; everything else is escaped text.
  static String toHtml(String markdown) {
    final out = <String>[];
    final code = StringBuffer();
    String? lang;
    var inFence = false;
    final quote = <String>[];
    void endQuote() {
      if (quote.isEmpty) return;
      out.add('<blockquote>${quote.join('\n')}</blockquote>');
      quote.clear();
    }

    for (final line in markdown.split('\n')) {
      if (_fence.hasMatch(line)) {
        if (!inFence) {
          endQuote();
          inFence = true;
          final l = line.trim().substring(3).trim();
          lang = RegExp(r'^[\w+-]+$').hasMatch(l) ? l : null;
          code.clear();
        } else {
          inFence = false;
          final body = _escape(code.toString().replaceFirst(RegExp(r'\n$'), ''));
          out.add(lang == null ? '<pre>$body</pre>' : '<pre><code class="language-$lang">$body</code></pre>');
        }
        continue;
      }
      if (inFence) {
        code.writeln(line);
        continue;
      }
      if (_quote.hasMatch(line)) {
        quote.add(_inline(line.replaceFirst(_quote, '')));
        continue;
      }
      endQuote();
      final h = _heading.firstMatch(line);
      if (h != null) {
        out.add('<b>${_inline(h[1]!)}</b>');
        continue;
      }
      final b = _bullet.firstMatch(line);
      if (b != null) {
        out.add('${b[1]}• ${_inline(line.substring(b.end))}');
        continue;
      }
      out.add(_inline(line));
    }
    endQuote();
    if (inFence) out.add('<pre>${_escape(code.toString().trimRight())}</pre>');
    return out.join('\n');
  }

  static String _inline(String s) {
    // Inline code and links first, kept out of the other rules.
    final kept = <String>[];
    String keep(String html) {
      kept.add(html);
      return '\u0000${kept.length - 1}\u0000';
    }

    s = s.replaceAllMapped(_inlineCode, (m) => keep('<code>${_escape(m[1]!)}</code>'));
    s = s.replaceAllMapped(_link, (m) {
      final url = _escape(m[2]!).replaceAll('"', '&quot;');
      return keep('<a href="$url">${_emphasis(_escape(m[1]!))}</a>');
    });
    s = _emphasis(_escape(s));
    return s.replaceAllMapped(RegExp('\u0000(\\d+)\u0000'), (m) => kept[int.parse(m[1]!)]);
  }

  static String _emphasis(String s) => s
      .replaceAllMapped(_bold, (m) => '<b>${m[1] ?? m[2]}</b>')
      .replaceAllMapped(_strike, (m) => '<s>${m[1]}</s>')
      .replaceAllMapped(_italic, (m) => '<i>${m[1] ?? m[2]}</i>');
}
