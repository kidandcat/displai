import 'dart:math' as math;
import 'dart:typed_data';

import 'package:minerva/presence/presence.dart';
import 'package:flutter_test/flutter_test.dart';

const int _rate = 16000;
const int _chunk = 512; // 32 ms at 16 kHz

class _FakeClock {
  Duration now = Duration.zero;
  Duration call() => now;
}

Float32List _sine(double freq, double amp, int offset) {
  final out = Float32List(_chunk);
  for (var i = 0; i < _chunk; i++) {
    out[i] = amp * math.sin(2 * math.pi * freq * (offset + i) / _rate);
  }
  return out;
}

/// Feeds [chunks] chunks, advancing the fake clock and ticking like a view.
void _feed(
  PresenceSignal s,
  _FakeClock clock,
  int chunks,
  Float32List Function(int offset) gen,
) {
  for (var c = 0; c < chunks; c++) {
    clock.now += const Duration(milliseconds: 32);
    s.addAudio(gen(c * _chunk), _rate);
    s.tick();
  }
}

void main() {
  test('silence keeps level and bands near zero', () {
    final clock = _FakeClock();
    final s = PresenceSignal(clock: clock.call);
    _feed(s, clock, 30, (_) => Float32List(_chunk));
    expect(s.level, lessThan(0.01));
    for (final b in s.bands) {
      expect(b, lessThan(0.01));
    }
  });

  test('1 kHz sine at 0.5 amplitude: high level, energy in the 1 kHz band', () {
    final clock = _FakeClock();
    final s = PresenceSignal(clock: clock.call);
    _feed(s, clock, 30, (o) => _sine(1000, 0.5, o));
    expect(s.level, greaterThan(0.85));
    expect(s.bands.length, PresenceSignal.bandCount);

    // Bands are log-spaced 100 Hz..8 kHz: 1 kHz falls in band 4.
    var maxIndex = 0;
    for (var i = 1; i < s.bands.length; i++) {
      if (s.bands[i] > s.bands[maxIndex]) maxIndex = i;
    }
    expect(maxIndex, 4);
    expect(s.bands[4], greaterThan(0.8));
    for (var i = 0; i < s.bands.length; i++) {
      if (i != 4) expect(s.bands[i], lessThan(0.3), reason: 'band $i');
    }
  });

  test('works at 48 kHz too (different bin mapping)', () {
    final clock = _FakeClock();
    final s = PresenceSignal(clock: clock.call);
    for (var c = 0; c < 40; c++) {
      clock.now += const Duration(milliseconds: 32);
      final chunk = Float32List(1536);
      for (var i = 0; i < chunk.length; i++) {
        chunk[i] = 0.5 * math.sin(2 * math.pi * 1000 * (c * 1536 + i) / 48000);
      }
      s.addAudio(chunk, 48000);
    }
    var maxIndex = 0;
    for (var i = 1; i < s.bands.length; i++) {
      if (s.bands[i] > s.bands[maxIndex]) maxIndex = i;
    }
    expect(maxIndex, 4);
  });

  test('decays toward zero when audio stops', () {
    final clock = _FakeClock();
    final s = PresenceSignal(clock: clock.call);
    _feed(s, clock, 30, (o) => _sine(1000, 0.5, o));
    final lit = s.level;
    expect(lit, greaterThan(0.85));

    // A frame shortly after the last chunk: still within the stale window.
    clock.now += const Duration(milliseconds: 16);
    s.tick();
    expect(s.level, closeTo(lit, 1e-9));

    // Two seconds of frames with no audio.
    for (var i = 0; i < 120; i++) {
      clock.now += const Duration(milliseconds: 16);
      s.tick();
    }
    expect(s.level, lessThan(0.01));
    for (final b in s.bands) {
      expect(b, lessThan(0.01));
    }
  });

  test('mode setter notifies only on change', () {
    final s = PresenceSignal();
    var calls = 0;
    s.addListener(() => calls++);
    s.mode = PresenceMode.listening;
    s.mode = PresenceMode.listening;
    s.mode = PresenceMode.speaking;
    expect(calls, 2);
    expect(s.mode, PresenceMode.speaking);
  });

  test('activity bumps and decays', () {
    final clock = _FakeClock();
    final s = PresenceSignal(clock: clock.call);
    s.bumpActivity(0.5);
    expect(s.activity, 0.5);
    clock.now += const Duration(seconds: 5);
    s.tick();
    expect(s.activity, lessThan(0.01));
  });
}
