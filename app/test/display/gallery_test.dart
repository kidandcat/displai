// Renders display views to PNG files at desktop and phone sizes, to review how the widgets look.
// Skipped unless GALLERY_OUT is set:
//   GALLERY_OUT=/tmp/gallery GALLERY_VIEWS=views.json flutter test test/display/gallery_test.dart
// views.json: [{"name": "01-text", "tool": "show", "args": {...}}, ...]. Without GALLERY_VIEWS a
// built-in sample of every node type is used. Images must be file:// URLs (no network in tests).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/display/display.dart';
import 'package:minerva/display/theme.dart' show DisplayText;

final String? _out = Platform.environment['GALLERY_OUT'];

const _sizes = {'desktop': Size(1352, 764), 'phone': Size(360, 588)};

/// Size of the corner orb at each size (MainView's compactOrb on the desktop and the phone).
const _orbs = {'desktop': 180.0, 'phone': 96.0};

void main() {
  setUpAll(() async {
    if (_out == null) return;
    // Real glyphs instead of the test font, so the text takes the room it takes on a device.
    final flutterRoot = File(Platform.resolvedExecutable)
        .parent
        .parent
        .parent
        .parent
        .parent
        .parent
        .path;
    final fonts = '$flutterRoot/bin/cache/artifacts/material_fonts';
    final roboto = FontLoader('Roboto');
    for (final w in [
      'Regular',
      'Italic',
      'Medium',
      'Bold',
      'BoldItalic',
      'Light',
    ]) {
      final f = File('$fonts/Roboto-$w.ttf');
      if (f.existsSync()) {
        roboto.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
      }
    }
    await roboto.load();
    DisplayText.family = 'Roboto';
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            File('$fonts/MaterialIcons-Regular.otf').readAsBytesSync(),
          ),
        ),
      );
    await icons.load();
  });

  testWidgets('gallery', (tester) async {
    final out = Directory(_out!)..createSync(recursive: true);
    final viewsFile = Platform.environment['GALLERY_VIEWS'];
    final views = (jsonDecode(
      viewsFile != null ? File(viewsFile).readAsStringSync() : _sample,
    ) as List).cast<Map<String, dynamic>>();
    // A first unsaved pass loads the images into the cache (decoding them in a test is slow).
    final passes = [
      (_sizes.keys.first, false),
      for (final k in _sizes.keys) (k, true),
    ];
    for (final (sizeName, save) in passes) {
      final size = _sizes[sizeName]!;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final controller = DisplayController();
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              backgroundColor: Colors.black,
              body: Stack(
                fit: StackFit.expand,
                children: [
                  DisplayView(
                    controller: controller,
                    cornerReserve: Size.square(12 + _orbs[sizeName]!),
                  ),
                  // Where the corner orb is drawn, to spot overlaps.
                  Positioned(
                    top: 12 + _orbs[sizeName]! * 0.05,
                    right: 12 + _orbs[sizeName]! * 0.05,
                    child: Container(
                      width: _orbs[sizeName]! * 0.9,
                      height: _orbs[sizeName]! * 0.9,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0x88FF4081),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      for (final v in views) {
        controller.callTool(
          v['tool'] as String,
          (v['args'] as Map).cast<String, dynamic>(),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        // Let file images decode.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 400)),
        );
        await tester.pump(const Duration(milliseconds: 600));
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final png = await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          return data!.buffer.asUint8List();
        });
        if (save) {
          File('${out.path}/${v['name']}-$sizeName.png').writeAsBytesSync(png!);
        }
      }
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    }
    tester.view.reset();
  }, skip: _out == null);
}

const _sample = '''[
 {"name": "sample", "tool": "show", "args": {"title": "Sample", "body": [
  {"type": "heading", "text": "Heading"}, {"type": "text", "text": "Some **bold** text."},
  {"type": "stats", "items": [{"label": "A", "value": "1", "delta": "+2%"}]},
  {"type": "chips", "items": ["one", "two"]}, {"type": "buttons", "items": ["OK", "Cancel"]}]}}
]''';
