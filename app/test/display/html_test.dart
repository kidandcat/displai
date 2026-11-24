import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/display/display.dart';
import 'package:minerva/display/html_widgets.dart';
import 'package:minerva/display/theme.dart' show HtmlStatus;

void main() {
  group('htmlDocument', () {
    test('wraps a fragment with the theme and the bridge', () {
      final doc = htmlDocument('<canvas id="c"></canvas>', scale: 0.8, dataJson: '{"n":1}');
      expect(doc, startsWith('<!doctype html><html><head>'));
      expect(doc, contains('--accent:'));
      expect(doc, contains('--s:0.800'));
      expect(doc, contains('window.minerva.data={"n":1}'));
      expect(doc, endsWith('<body><canvas id="c"></canvas></body></html>'));
    });

    test('injects into the head of a document, keeping its lines', () {
      const page = '<!DOCTYPE html>\n<html>\n<HEAD>\n<title>x</title></head>\n<body>\nhi\n</body></html>';
      final doc = htmlDocument(page, scale: 1);
      expect('\n'.allMatches(doc).length, '\n'.allMatches(page).length);
      expect(doc.indexOf('MinervaBridge'), lessThan(doc.indexOf('<title>')));
      expect(doc, contains('window.minerva.data=null'));
    });

    test('adds a head to a document without one', () {
      final doc = htmlDocument('<html lang="es"><body>hi</body></html>', scale: 1);
      expect(doc, startsWith('<html lang="es"><head><meta charset="utf-8">'));
    });
  });

  group('html tool', () {
    test('shows a page, reports its status and forwards its messages', () async {
      final c = DisplayController();
      addTearDown(c.dispose);
      final events = <String>[];
      final sub = c.userEvents.listen(events.add);
      addTearDown(sub.cancel);

      expect(c.callTool('html', {}), startsWith('error:'));
      final r = c.callTool('html', {
        'title': 'Juego',
        'html': '<p>hola</p>',
        'data': {'level': 1},
      });
      expect(r, contains('page "page1" shown as view 1'));
      expect(c.current!.kind, 'html');
      expect(c.getState(), contains('page page1: not rendered yet'));

      final st = HtmlStatus(html: '<p>hola</p>')
        ..loaded = true
        ..content = const Size(800, 900)
        ..viewport = const Size(800, 600)
        ..state = '{"score":3}';
      st.errors.add('ReferenceError: foo is not defined (line 4)');
      c.reportHtml('page1', st);
      final line = await c.settleHtml(timeout: const Duration(milliseconds: 100));
      expect(line, contains('loaded'));
      expect(line, contains('does not fit'));
      expect(line, contains('state {"score":3}'));
      expect(line, contains('JS ERRORS: ReferenceError'));

      c.handleAction(c.current!.surfaceId, 'page1', 'message', {'text': 'won'});
      await Future<void>.delayed(Duration.zero);
      expect(events.single, '[display] page "Juego" (page1) sent: won');

      expect(c.callTool('update', {'id': 'page1', 'set': {'data': {'level': 2}}}), startsWith('ok'));
      final page = c.current!.root.children.single;
      expect(page.props['dataJson'], '{"level":2}');
      expect(page.props['html'], '<p>hola</p>');
    });

    test('a page node inside show keeps its height', () {
      final c = DisplayController();
      addTearDown(c.dispose);
      c.callTool('show', {
        'title': 'Panel',
        'body': [
          {'type': 'heading', 'text': 'Ventas'},
          {'type': 'html', 'html': '<svg></svg>', 'height': 300},
        ],
      });
      final page = c.current!.root.children.last;
      expect(page.type, 'html');
      expect(page.props['height'], 300);
      expect(c.current!.edgeToEdge, isFalse);
    });
  });
}
