import 'dart:math' as math;
import 'dart:typed_data';

import 'package:minerva/presence/presence.dart';
import 'package:minerva/presence/presence_fallback_painter.dart';
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

  group('frame loop', () {
    setUp(() {
      PresenceView.debugResetProgramCache();
      PresenceView.debugProgramLoader = () async =>
          throw Exception('no shader in tests');
    });

    /// Frames the view draws in half a second of 5 ms display refreshes.
    Future<int> framesInHalfSecond(WidgetTester tester) async {
      final painter =
          tester
                  .widget<CustomPaint>(
                    find.descendant(
                      of: find.byType(PresenceView),
                      matching: find.byType(CustomPaint),
                    ),
                  )
                  .painter!
              as PresenceFallbackPainter;
      var frames = 0;
      void count() => frames++;
      painter.frame.addListener(count);
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 5));
      }
      painter.frame.removeListener(count);
      return frames;
    }

    testWidgets('draws at the calm rate at rest and the active rate when busy', (
      tester,
    ) async {
      final signal = PresenceSignal();
      await tester.pumpWidget(_host(signal, compact: false));
      await tester.pump();

      // Idle and settled: about calmFps, whatever the display's refresh rate.
      final calm = await framesInHalfSecond(tester);
      expect(calm, inInclusiveRange(13, PresenceView.calmFps ~/ 2 + 2));

      signal.mode = PresenceMode.thinking;
      final busy = await framesInHalfSecond(tester);
      expect(busy, inInclusiveRange(26, PresenceView.activeFps ~/ 2 + 4));

      await tester.pumpWidget(const SizedBox());
      signal.dispose();
    });

    testWidgets('stops while tickers are muted and resumes after', (
      tester,
    ) async {
      final signal = PresenceSignal();
      final enabled = ValueNotifier(false);
      await tester.pumpWidget(
        ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (context, value, _) => TickerMode(
            enabled: value,
            child: _host(signal, compact: false),
          ),
        ),
      );
      await tester.pump();
      expect(await framesInHalfSecond(tester), 0);
      expect(tester.binding.transientCallbackCount, 0);

      enabled.value = true;
      await tester.pump();
      expect(await framesInHalfSecond(tester), greaterThan(10));

      enabled.value = false;
      await tester.pump();
      expect(await framesInHalfSecond(tester), 0);

      await tester.pumpWidget(const SizedBox());
      signal.dispose();
      enabled.dispose();
    });
  });

  group('PresenceFrame', () {
    test('keeps every plane a valid projection as time and spin advance', () {
      final frame = PresenceFrame();
      for (var step = 0; step < 400; step++) {
        frame.advance(0.37, 1 + (step % 17).toDouble());
        final r = frame.rotation;
        // The shell's rotation stays orthonormal.
        for (var a = 0; a < 3; a++) {
          for (var b = 0; b < 3; b++) {
            var dot = 0.0;
            for (var k = 0; k < 3; k++) {
              dot += r[a * 3 + k] * r[b * 3 + k];
            }
            expect(dot, closeTo(a == b ? 1 : 0, 1e-9));
          }
        }
        for (var i = 0; i < PresenceFrame.ringCount; i++) {
          final ux = frame.ringBasis[i * 6], uy = frame.ringBasis[i * 6 + 1];
          final vx = frame.ringBasis[i * 6 + 3], vy = frame.ringBasis[i * 6 + 4];
          final m = frame.ringInverse;
          // A point (a, b) of the orbit's plane lands on screen at a*u + b*v;
          // the inverse must bring it back.
          const a = 0.3, b = -0.8;
          final x = a * ux + b * vx, y = a * uy + b * vy;
          expect(m[i * 4] * x + m[i * 4 + 1] * y, closeTo(a, 1e-9));
          expect(m[i * 4 + 2] * x + m[i * 4 + 3] * y, closeTo(b, 1e-9));
        }
        for (final v in frame.hudInverse) {
          expect(v.isFinite, isTrue);
        }
        expect(frame.time, inInclusiveRange(0, PresenceFrame.wrap));
        expect(frame.spin, inInclusiveRange(0, PresenceFrame.wrap));
      }
      frame.dispose();
    });

    test('the full orb is painted in a centered square, the compact one fills', () {
      const size = Size(800, 500);
      final full = PresenceView.orbRect(size, compact: false);
      expect(full.center, const Offset(400, 250));
      expect(full.width, 500 * PresenceView.fullExtent);
      expect(full.height, full.width);
      expect(
        PresenceView.orbRect(const Size(122, 122), compact: true),
        const Rect.fromLTWH(0, 0, 122, 122),
      );
    });
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
