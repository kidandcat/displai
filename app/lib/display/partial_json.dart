/// Tolerant parser for JSON documents that are still streaming in.
///
/// A tool call's arguments arrive as `input_json_delta` fragments that can be
/// cut anywhere. [parsePartialJson] returns everything that is already
/// complete enough to render:
/// - open objects/arrays are closed implicitly;
/// - a string cut in the middle is kept as-is (text grows like a typewriter),
///   except for keys listed in `atomicKeys` (ids, types, urls), whose values
///   are dropped until their closing quote arrives;
/// - a number or literal at the very end is dropped (it may still grow);
/// - an object key without a value yet is dropped.
///
/// Throws [FormatException] for input that can never become valid JSON.
library;

Object? parsePartialJson(String source, {Set<String> atomicKeys = const {}}) {
  final parser = _PartialJsonParser(source, atomicKeys);
  final Object? value = parser.parseValue();
  if (identical(value, _missing)) return null;
  return value;
}

const Object _missing = Object();

class _PartialJsonParser {
  _PartialJsonParser(this.s, this.atomicKeys);

  final String s;
  final Set<String> atomicKeys;
  int i = 0;

  /// Set when the last parsed string ran into the end of input.
  bool lastStringCut = false;

  bool get eof => i >= s.length;

  void skipWs() {
    while (i < s.length) {
      final int c = s.codeUnitAt(i);
      if (c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09) {
        i++;
      } else {
        break;
      }
    }
  }

  Object? parseValue() {
    skipWs();
    if (eof) return _missing;
    final String c = s[i];
    switch (c) {
      case '{':
        return parseObject();
      case '[':
        return parseArray();
      case '"':
        return parseString();
      case 't':
        return parseLiteral('true', true);
      case 'f':
        return parseLiteral('false', false);
      case 'n':
        return parseLiteral('null', null);
      default:
        if (c == '-' || (c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39)) {
          return parseNumber();
        }
        throw FormatException('Unexpected character', s, i);
    }
  }

  Object? parseLiteral(String word, Object? value) {
    final int end = i + word.length;
    if (end > s.length) {
      if (!word.startsWith(s.substring(i))) {
        throw FormatException('Bad literal', s, i);
      }
      i = s.length;
      return _missing;
    }
    if (s.substring(i, end) != word) throw FormatException('Bad literal', s, i);
    i = end;
    return value;
  }

  Object? parseNumber() {
    final int start = i;
    while (i < s.length && '+-0123456789.eE'.contains(s[i])) {
      i++;
    }
    // A number touching the end of input may still be growing.
    if (eof) return _missing;
    final String text = s.substring(start, i);
    final num? n = num.tryParse(text);
    if (n == null) throw FormatException('Bad number', s, start);
    return n;
  }

  String parseString() {
    lastStringCut = false;
    i++; // opening quote
    final buf = StringBuffer();
    while (i < s.length) {
      final String c = s[i];
      if (c == '"') {
        i++;
        return buf.toString();
      }
      if (c == '\\') {
        if (i + 1 >= s.length) {
          i = s.length;
          break;
        }
        final String e = s[i + 1];
        switch (e) {
          case 'n':
            buf.write('\n');
          case 't':
            buf.write('\t');
          case 'r':
            buf.write('\r');
          case 'b':
            buf.write('\b');
          case 'f':
            buf.write('\f');
          case 'u':
            if (i + 6 > s.length) {
              i = s.length;
              lastStringCut = true;
              return buf.toString();
            }
            final int? code = int.tryParse(
              s.substring(i + 2, i + 6),
              radix: 16,
            );
            if (code == null) throw FormatException('Bad escape', s, i);
            buf.writeCharCode(code);
            i += 6;
            continue;
          default:
            buf.write(e); // \" \\ \/
        }
        i += 2;
        continue;
      }
      buf.write(c);
      i++;
    }
    lastStringCut = true;
    return buf.toString();
  }

  Map<String, Object?> parseObject() {
    i++; // {
    final map = <String, Object?>{};
    while (true) {
      skipWs();
      if (eof) return map;
      final String c = s[i];
      if (c == '}') {
        i++;
        return map;
      }
      if (c == ',') {
        i++;
        continue;
      }
      if (c != '"') throw FormatException('Expected key', s, i);
      final String key = parseString();
      if (lastStringCut) return map;
      skipWs();
      if (eof) return map;
      if (s[i] != ':') throw FormatException('Expected colon', s, i);
      i++;
      final Object? value = parseValue();
      if (identical(value, _missing)) return map;
      if (value is String && lastStringCut) {
        lastStringCut = false;
        if (!atomicKeys.contains(key)) map[key] = value;
        return map;
      }
      map[key] = value;
    }
  }

  List<Object?> parseArray() {
    i++; // [
    final list = <Object?>[];
    while (true) {
      skipWs();
      if (eof) return list;
      final String c = s[i];
      if (c == ']') {
        i++;
        return list;
      }
      if (c == ',') {
        i++;
        continue;
      }
      final Object? value = parseValue();
      if (identical(value, _missing)) return list;
      list.add(value);
      if (value is String && lastStringCut) {
        lastStringCut = false;
        return list;
      }
    }
  }
}
