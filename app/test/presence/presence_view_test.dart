import 'dart:math' as math;
import 'dart:typed_data';

import 'package:displai/presence/presence.dart';
import 'package:displai/presence/presence_fallback_painter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Float32List _tone(int n) => Float32List.fromList(
  List.generate(n, (i) => 0.4 * math.sin(2 * math.pi * 440 * i / 16000)),
);

Widget _host(PresenceSignal signal, {required bool compact}) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(
    child: SizedBox(
      width: 800,
      height: 500,
      child: compact
          ? Align(child: PresenceView(signal: signal, compact: true))
          : PresenceView(signal: signal),
    ),
  ),
);

/// Runs every mode with some audio for a handful of frames.
Future<void> _exercise(WidgetTester tester, PresenceSignal signal) async {
  for (final mode in PresenceMode.values) {
    signal.mode = mode;
    if (mode == PresenceMode.thinking) signal.bumpActivity();
    for (var i = 0; i < 6; i++) {
      signal.addAudio(_tone(512), 16000);
      await tester.pump(const Duration(milliseconds: 16));
    }
  }
}

void main() {
  tearDown(() {
    PresenceView.debugProgramLoader = null;
    PresenceView.debugResetProgramCache();
  });

  group('fallback (shader fails to load)', () {
    setUp(() {
      PresenceView.debugResetProgramCache();
      PresenceView.debugProgramLoader = () async =>
          throw Exception('no shader in tests');
    });

    for (final compact in [false, true]) {
      testWidgets('compact=$compact renders the Canvas fallback', (
        tester,
      ) async {
        final signal = PresenceSignal();
        await tester.pumpWidget(_host(signal, compact: compact));
        await tester.pump(); // let the failed load resolve
        final paint = tester.widget<CustomPaint>(
          find.descendant(
            of: find.byType(PresenceView),
            matching: find.byType(CustomPaint),
          ),
        );
        expect(paint.painter, isA<PresenceFallbackPainter>());
        await _exercise(tester, signal);
        if (compact) {
          expect(tester.getSize(find.byType(PresenceView)), const Size(36, 36));
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        signal.dispose();
      });
    }
  });

  group('default loader', () {
    for (final compact in [false, true]) {
      testWidgets('compact=$compact pumps without throwing', (tester) async {
        final signal = PresenceSignal();
        await tester.pumpWidget(_host(signal, compact: compact));
        // Give the real asset load a chance to finish (or fail) off the fake clock.
        await tester.runAsync(() async {
          try {
            await PresenceView.loadProgram();
          } catch (_) {}
        });
        await tester.pump();
        await _exercise(tester, signal);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        signal.dispose();
      });
    }
  });
}
