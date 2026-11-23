import 'dart:convert';

import 'package:displai/display/partial_json.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parsePartialJson', () {
    test('parses complete JSON like jsonDecode', () {
      const src =
          '{"a": [1, 2.5, -3e2, true, false, null], "b": {"c": "d\\n\\u00e9"}}';
      expect(parsePartialJson(src), jsonDecode(src));
    });

    test('closes open containers and keeps truncated strings', () {
      expect(parsePartialJson('{"title": "Recetas de la sem'), {
        'title': 'Recetas de la sem',
      });
      expect(parsePartialJson('{"body": [{"type": "text", "text": "Hola'), {
        'body': [
          {'type': 'text', 'text': 'Hola'},
        ],
      });
    });

    test('drops dangling keys, numbers and literals', () {
      expect(parsePartialJson('{"a": 1, "b"'), {'a': 1});
      expect(parsePartialJson('{"a": 1, "b":'), {'a': 1});
      expect(parsePartialJson('{"a": 12'), <String, dynamic>{});
      expect(parsePartialJson('{"a": tr'), <String, dynamic>{});
      expect(parsePartialJson('[1, 2, 3'), [1, 2]);
    });

    test('drops truncated atomic values', () {
      expect(
        parsePartialJson('{"type": "ima', atomicKeys: const {'type', 'url'}),
        <String, dynamic>{},
      );
      expect(
        parsePartialJson(
          '{"type": "image", "url": "https://upload.wiki',
          atomicKeys: const {'type', 'url'},
        ),
        {'type': 'image'},
      );
    });

    test('never throws on any prefix of a valid document', () {
      final String doc = jsonEncode({
        'title': 'Menú «semanal» — ñandú',
        'body': [
          {
            'type': 'cards',
            'items': [
              {'title': 'Paella', 'value': 12.5},
              {'title': 'Tortilla', 'body': 'Con \\"cebolla\\"'},
            ],
          },
          {'type': 'progress', 'value': 0.4, 'flag': true, 'x': null},
        ],
      });
      for (var i = 0; i <= doc.length; i++) {
        expect(
          () => parsePartialJson(doc.substring(0, i)),
          returnsNormally,
          reason: 'prefix $i',
        );
      }
      expect(parsePartialJson(doc), jsonDecode(doc));
    });

    test('rejects invalid JSON', () {
      expect(() => parsePartialJson('{"a" 1}'), throwsFormatException);
    });
  });
}
