/// The wake word: while its mode is on, Minerva only takes utterances that begin with "Minerva"
/// (see [WakeWord.take]); everything else is ignored.
class WakeWord {
  WakeWord({this.window = const Duration(seconds: 8)});

  /// After "Minerva" alone, the next utterance this soon is addressed to her too.
  final Duration window;

  DateTime? _armedUntil;

  /// What [text] asks Minerva, without the wake word: empty after "Minerva" alone (the next
  /// utterance within [window] is hers), null when it is not addressed to her.
  String? take(String text, DateTime now) {
    final rest = strip(text);
    final armed = _armedUntil;
    _armedUntil = rest != null && rest.isEmpty ? now.add(window) : null;
    if (rest != null) return rest;
    return armed != null && now.isBefore(armed) ? text : null;
  }

  /// Forgets a pending "Minerva" alone.
  void reset() => _armedUntil = null;

  // The recognizer is local and hears Spanish: leading punctuation, a greeting ("oye Minerva")
  // and common mis-hearings ("mi nerva", "minerba", "menerva", "minelva").
  static final _start = RegExp(
    r'^[\s\p{P}]*(?:(?:oye|oiga|hey|ey|eh|hola|ok|okay|vale)[\s\p{P}]+)?'
    r'''m[ie]\s?n[ei]\s?[rl]?\s?[vb]a(?![\p{L}\p{N}])[\s,.;:!?…\-–—"'”’»)]*''',
    unicode: true,
  );

  static final _wordy = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// [text] without the wake word at its start (empty when nothing else was said), or null when
  /// it does not begin with it. Case and accents don't matter.
  static String? strip(String text) {
    final m = _start.firstMatch(_fold(text));
    if (m == null) return null;
    final rest = text.substring(m.end).trim();
    return _wordy.hasMatch(rest) ? rest : '';
  }

  static const _plain = {'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u', 'ü': 'u', 'à': 'a', 'è': 'e'};

  /// Lowercase and without accents, one character for one, so offsets match [text]'s.
  static String _fold(String text) {
    final b = StringBuffer();
    for (final unit in text.codeUnits) {
      final c = String.fromCharCode(unit);
      final lower = c.toLowerCase();
      b.write(lower.length == 1 ? (_plain[lower] ?? lower) : c);
    }
    return b.toString();
  }
}
