import 'dart:convert';

import 'package:minerva/display/display.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps a [DisplayView] at 1440x900 and returns its controller.
Future<DisplayController> pumpDisplay(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = DisplayController();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: DisplayView(controller: controller),
      ),
    ),
  );
  return controller;
}

/// Unmounts the view and disposes the controller.
Future<void> tearDownDisplay(
  WidgetTester tester,
  DisplayController controller,
) async {
  await tester.pumpWidget(const SizedBox());
  controller.dispose();
}

/// Lets transitions and genui's async validation settle.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

const Map<String, dynamic> recipesView = {
  'title': 'Recetas',
  'subtitle': 'Ideas para la cena de **hoy**',
  'body': [
    {'type': 'heading', 'text': 'Platos principales'},
    {
      'type': 'text',
      'text': 'Tres recetas *rápidas* con lo que hay en la nevera.',
    },
    {
      'type': 'cards',
      'items': [
        {
          'title': 'Tortilla de patatas',
          'subtitle': '30 min',
          'body': 'Con cebolla, por supuesto.',
        },
        {'title': 'Pizza margarita', 'subtitle': '25 min', 'value': '9 €'},
        {'title': 'Gazpacho', 'subtitle': '15 min'},
      ],
    },
    {
      'type': 'table',
      'columns': ['Ingrediente', 'Cantidad'],
      'rows': [
        ['Huevos', '6'],
        ['Patatas', '500 g'],
      ],
    },
    {
      'type': 'row',
      'children': [
        {
          'type': 'stats',
          'items': [
            {'label': 'Calorías', 'value': '540', 'delta': '-12%'},
          ],
        },
        {
          'type': 'kv',
          'items': [
            ['Dificultad', 'Fácil'],
            ['Raciones', '4'],
          ],
        },
      ],
    },
    {
      'type': 'chips',
      'items': ['Vegetariano', 'Sin gluten'],
    },
    {'type': 'progress', 'value': 0.6, 'label': 'Compra hecha'},
    {'type': 'divider'},
    {
      'type': 'buttons',
      'items': ['Ver más', 'Lista de la compra'],
    },
  ],
};

void main() {
  testWidgets('tool specs cover every tool with an object schema', (
    tester,
  ) async {
    final names = [for (final t in DisplayController.toolSpecs) t.name];
    expect(
      names,
      containsAll(['show', 'update', 'form', 'video', 'clear', 'get_state']),
    );
    for (final t in DisplayController.toolSpecs) {
      expect(t.inputSchema['type'], 'object', reason: t.name);
      expect(t.description, isNotEmpty);
      // Must be JSON-encodable for the model API.
      expect(() => jsonEncode(t.inputSchema), returnsNormally);
    }
  });

  testWidgets('show renders every node type with ordinals', (tester) async {
    final c = await pumpDisplay(tester);
    expect(c.isEmpty, isTrue);
    expect(c.getState(), contains('display empty'));

    final String result = c.callTool('show', recipesView);
    await settle(tester);

    expect(result, startsWith('ok:'));
    expect(result, contains('cards1 [1-3]'));
    expect(c.isEmpty, isFalse);
    expect(find.text('Recetas'), findsOneWidget);
    expect(find.text('Platos principales'), findsOneWidget);
    expect(find.text('Pizza margarita'), findsOneWidget);
    expect(find.text('Huevos'), findsOneWidget);
    expect(find.text('Dificultad'), findsOneWidget);
    expect(find.text('Vegetariano'), findsOneWidget);
    expect(find.text('Lista de la compra'), findsOneWidget);
    // Ordinal badges: 3 cards + 2 rows + 2 chips + 2 buttons.
    for (var i = 1; i <= 9; i++) {
      expect(find.text('$i'), findsWidgets, reason: 'badge $i');
    }

    final String state = c.getState();
    expect(state, contains('view 1/1 "Recetas"'));
    expect(state, contains('[1] "Tortilla de patatas'));
    expect(state, contains('[2] "Pizza margarita'));
    expect(state, contains('[3] "Gazpacho'));
    expect(state, contains('[4] Huevos'));
    expect(state, contains('[5] Patatas'));
    expect(state, contains('[6] "Vegetariano"'));
    expect(state, contains('[9] "Lista de la compra"'));
    expect(state, contains('stats'));
    expect(state, contains('Dificultad=Fácil'));
    expect(state, contains('60%'));
    // Indented tree: children of the row are nested.
    expect(state, contains('  row row1\n    stats stats1'));

    expect(c.rendererErrors, isEmpty);
    expect(tester.takeException(), isNull);
    await tearDownDisplay(tester, c);
  });

  testWidgets('tapping items and buttons emits user events', (tester) async {
    final c = await pumpDisplay(tester);
    final events = <String>[];
    c.userEvents.listen(events.add);
    c.callTool('show', recipesView);
    await settle(tester);

    await tester.tap(find.text('Pizza margarita'));
    await tester.ensureVisible(find.text('Lista de la compra'));
    await settle(tester);
    await tester.tap(find.text('Lista de la compra'));
    await tester.pump();

    expect(events, [
      '[display] tapped item 2 "Pizza margarita — 9 €" in "Recetas"',
      '[display] pressed button 9 "Lista de la compra" in "Recetas"',
    ]);
    expect(c.getState(), contains('recent user actions:'));
    await tearDownDisplay(tester, c);
  });

  testWidgets('update sets, appends and removes by id', (tester) async {
    final c = await pumpDisplay(tester);
    c.callTool('show', {
      'title': 'Pedido',
      'body': [
        {'type': 'text', 'id': 'estado', 'text': 'Preparando…'},
        {'type': 'progress', 'id': 'barra', 'value': 0.2},
        {
          'type': 'cards',
          'id': 'platos',
          'items': [
            {'title': 'Croquetas'},
          ],
        },
      ],
    });
    await settle(tester);

    expect(
      c.callTool('update', {
        'id': 'estado',
        'set': {'text': 'En camino'},
      }),
      startsWith('ok:'),
    );
    expect(
      c.callTool('update', {
        'id': 'platos',
        'append': [
          {'title': 'Calamares'},
        ],
      }),
      contains('ordinals 1-2'),
    );
    expect(
      c.callTool('update', {'id': 'barra', 'remove': true}),
      startsWith('ok:'),
    );
    await settle(tester);

    expect(find.text('En camino'), findsOneWidget);
    expect(find.text('Preparando…'), findsNothing);
    expect(find.text('Calamares'), findsOneWidget);
    final String state = c.getState();
    expect(state, contains('[2] "Calamares"'));
    expect(state, isNot(contains('progress')));
    expect(
      c.callTool('update', {
        'id': 'nada',
        'set': {'text': 'x'},
      }),
      startsWith('error:'),
    );
    expect(c.rendererErrors, isEmpty);
    await tearDownDisplay(tester, c);
  });

  testWidgets('form shows fields, validates and emits submit event', (
    tester,
  ) async {
    final c = await pumpDisplay(tester);
    final events = <String>[];
    c.userEvents.listen(events.add);

    final String result = c.callTool('form', {
      'title': 'Reserva',
      'id': 'reserva',
      'intro': 'Mesa para esta noche',
      'fields': [
        {'name': 'nombre', 'label': 'Nombre', 'type': 'text', 'required': true},
        {
          'name': 'personas',
          'label': 'Personas',
          'type': 'number',
          'default': 2,
        },
        {
          'name': 'zona',
          'label': 'Zona',
          'type': 'select',
          'options': ['Terraza', 'Interior'],
        },
        {'name': 'trona', 'label': 'Trona', 'type': 'checkbox'},
      ],
    });
    await settle(tester);
    expect(result, startsWith('ok: form "reserva"'));
    expect(find.text('Reserva'), findsOneWidget);
    expect(find.text('Terraza'), findsOneWidget);

    // Required field missing: no event.
    await tester.ensureVisible(find.byKey(const ValueKey('form-submit')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('form-submit')));
    await tester.pump();
    expect(events, isEmpty);

    await tester.enterText(find.byKey(const ValueKey('field-nombre')), 'Lucía');
    await tester.tap(find.text('Interior'));
    await tester.pump();

    String state = c.getState();
    expect(state, contains('form reserva (not submitted yet)'));
    expect(state, contains('nombre (text, required) = "Lucía"'));
    expect(state, contains('personas (number) = 2'));
    expect(
      state,
      contains('zona (select) = "Interior": [1] Terraza [2] Interior'),
    );

    // The model can fill values too.
    expect(
      c.callTool('update', {
        'id': 'reserva',
        'values': {'trona': true},
      }),
      startsWith('ok:'),
    );
    await tester.pump();

    await tester.ensureVisible(find.byKey(const ValueKey('form-submit')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('form-submit')));
    await tester.pump();

    expect(events, hasLength(1));
    expect(events.single, startsWith('[display] form "Reserva" submitted: '));
    final Map<String, dynamic> values = jsonDecode(
      events.single.split('submitted: ').last,
    ) as Map<String, dynamic>;
    expect(values, {
      'nombre': 'Lucía',
      'personas': 2,
      'zona': 'Interior',
      'trona': true,
    });
    state = c.getState();
    expect(state, contains('form reserva (submitted)'));
    expect(c.rendererErrors, isEmpty);
    await tearDownDisplay(tester, c);
  });

  testWidgets('streamPartial renders truncated JSON progressively', (
    tester,
  ) async {
    final c = await pumpDisplay(tester);
    final String full = jsonEncode({
      'title': 'Viaje a Lisboa',
      'body': [
        {'type': 'heading', 'text': 'Itinerario'},
        {
          'type': 'cards',
          'items': [
            {'title': 'Torre de Belém', 'subtitle': 'Día 1'},
            {'title': 'Alfama', 'subtitle': 'Día 2'},
            {'title': 'Sintra', 'subtitle': 'Día 3'},
          ],
        },
        {
          'type': 'image',
          'url': 'https://example.com/lisboa.jpg',
          'caption': 'Vista del Tajo',
        },
      ],
    });

    // Cut in the middle of the third card's title.
    final int cut = full.indexOf('Sintra') + 3;
    c.streamPartial('show', full.substring(0, cut));
    await tester.pump(const Duration(milliseconds: 100));
    await settle(tester);

    expect(c.isEmpty, isFalse);
    expect(find.text('Viaje a Lisboa'), findsOneWidget);
    expect(find.text('Itinerario'), findsOneWidget);
    expect(find.text('Torre de Belém'), findsOneWidget);
    expect(find.text('Alfama'), findsOneWidget);
    expect(find.text('Sin'), findsOneWidget);
    expect(c.getState(), contains('still rendering'));

    // Every prefix is accepted without throwing.
    for (var i = 0; i <= full.length; i += 5) {
      c.streamPartial('show', full.substring(0, i));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);

    // The final call reuses the streamed view instead of adding another.
    final String result = c.callTool(
      'show',
      jsonDecode(full) as Map<String, dynamic>,
    );
    await settle(tester);
    expect(result, contains('cards1 [1-3]'));
    expect(c.timeline, hasLength(1));
    expect(find.text('Sintra'), findsOneWidget);
    expect(c.getState(), isNot(contains('still rendering')));

    // A cancelled stream disappears and the previous view comes back.
    c.streamPartial('show', '{"title": "Borrador", "body": [{"type": "te');
    await tester.pump(const Duration(milliseconds: 100));
    await settle(tester);
    expect(find.text('Borrador'), findsWidgets);
    c.cancelPartial();
    await settle(tester);
    expect(find.text('Borrador'), findsNothing);
    expect(find.text('Viaje a Lisboa'), findsOneWidget);
    expect(c.timeline, hasLength(1));

    expect(c.rendererErrors, isEmpty);
    await tearDownDisplay(tester, c);
  });

  testWidgets('streamPartial works for forms', (tester) async {
    final c = await pumpDisplay(tester);
    c.streamPartial(
      'form',
      '{"title": "Encuesta", "fields": [{"name": "nota", "label": "Nota", '
          '"type": "slider", "min": 0, "max": 10}, {"name": "comen',
    );
    await tester.pump(const Duration(milliseconds: 100));
    await settle(tester);
    expect(find.text('Encuesta'), findsOneWidget);
    expect(find.text('Nota'), findsOneWidget);
    expect(tester.takeException(), isNull);
    c.cancelPartial();
    await settle(tester);
    expect(c.isEmpty, isTrue);
    await tearDownDisplay(tester, c);
  });

  testWidgets('video rejects YouTube and accepts direct files', (tester) async {
    final c = await pumpDisplay(tester);
    expect(
      c.callTool('video', {'url': 'https://www.youtube.com/watch?v=abc'}),
      startsWith('error:'),
    );
    expect(c.callTool('video', {'control': 'pause'}), startsWith('error:'));
    expect(c.isEmpty, isTrue);

    final String ok = c.callTool('video', {
      'url': 'https://example.com/paseo.mp4',
      'title': 'Paseo por el Retiro',
    });
    expect(ok, startsWith('ok:'));
    await settle(tester);
    expect(find.text('Paseo por el Retiro'), findsWidgets);
    expect(
      c.getState(),
      contains('video video1 https://example.com/paseo.mp4'),
    );
    expect(c.callTool('video', {'control': 'pause'}), 'ok: pause');
    await tearDownDisplay(tester, c);
  });

  testWidgets('timeline: clear, back, strip navigation and cap', (
    tester,
  ) async {
    final c = await pumpDisplay(tester);
    c.callTool('show', {
      'title': 'Primera',
      'body': [
        {'type': 'text', 'text': 'Uno'},
      ],
    });
    c.callTool('show', {
      'title': 'Segunda',
      'body': [
        {'type': 'text', 'text': 'Dos'},
      ],
    });
    await settle(tester);
    expect(find.text('Dos'), findsOneWidget);
    // Strip shows both entries.
    expect(find.byKey(const ValueKey('timeline-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('timeline-1')), findsOneWidget);

    c.back();
    await settle(tester);
    expect(find.text('Uno'), findsOneWidget);
    expect(c.getState(), contains('view 1/2 "Primera"'));

    await tester.tap(find.byKey(const ValueKey('timeline-1')));
    await settle(tester);
    expect(find.text('Dos'), findsOneWidget);

    expect(c.callTool('clear', {}), startsWith('ok:'));
    await settle(tester);
    expect(c.isEmpty, isTrue);
    expect(find.text('Dos'), findsNothing);
    expect(c.getState(), contains('display empty'));

    expect(c.callTool('back', {}), contains('"Segunda"'));
    await settle(tester);
    expect(find.text('Dos'), findsOneWidget);

    expect(c.callTool('no_existe', {}), startsWith('error:'));

    for (var i = 0; i < 25; i++) {
      c.callTool('show', {
        'title': 'Vista $i',
        'body': [
          {'type': 'text', 'text': 'Texto $i'},
        ],
      });
    }
    await settle(tester);
    expect(c.timeline, hasLength(DisplayController.maxTimeline));
    expect(find.text('Texto 24'), findsOneWidget);
    expect(c.rendererErrors, isEmpty);
    await tearDownDisplay(tester, c);
  });

  testWidgets('looks fine on a big monitor', (tester) async {
    tester.view.physicalSize = const Size(3840, 2160);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = DisplayController();
    await tester.pumpWidget(MaterialApp(home: DisplayView(controller: c)));
    c.callTool('show', recipesView);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Pizza margarita'), findsOneWidget);
    await tearDownDisplay(tester, c);
  });
}
