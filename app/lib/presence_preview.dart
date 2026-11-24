// Preview of the presence orb, outside the assistant: every state with synthetic audio, in every
// layout the app shows it in. For working on the shader and for measuring its cost.
//
//   flutter run -d macos -t lib/presence_preview.dart          (hot restart after a shader change)
//   flutter build macos --release -t lib/presence_preview.dart
//
// Keys: 1 idle, 2 listening, 3 thinking, 4 speaking, M mute, 0 cycle through all, L next layout.
// Or start it in a given state with the environment:
//   MINERVA_PREVIEW_STATE   idle | listening | silence | thinking | speaking | muted | cycle
//                           (silence = listening with nobody talking, the all-day state)
//   MINERVA_PREVIEW_LAYOUT  full | corner | overlay | sheet
//                           (sheet = every state side by side at the three compact sizes)

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'presence/presence.dart';

enum PreviewState { idle, listening, silence, thinking, speaking, muted, cycle }

enum PreviewLayout { full, corner, overlay, sheet }

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  runApp(PresencePreview(
    state: PreviewState.values.asNameMap()[env['MINERVA_PREVIEW_STATE']] ?? PreviewState.cycle,
    layout: PreviewLayout.values.asNameMap()[env['MINERVA_PREVIEW_LAYOUT']] ?? PreviewLayout.full,
  ));
}

/// Drives a [PresenceSignal] the way the assistant would, with a synthetic voice instead of the
/// microphone and the TTS.
class PresenceDemo {
  PresenceDemo(PreviewState state) {
    this.state = state;
    _timer = Timer.periodic(const Duration(milliseconds: _chunkMs), _tick);
  }

  static const int _rate = 16000;
  static const int _chunkMs = 32;
  static const List<PreviewState> _cycle = [
    PreviewState.silence,
    PreviewState.listening,
    PreviewState.thinking,
    PreviewState.speaking,
    PreviewState.muted,
  ];

  final PresenceSignal signal = PresenceSignal();
  final math.Random _random = math.Random(7);
  late final Timer _timer;
  PreviewState _state = PreviewState.cycle;
  double _t = 0;
  double _phase = 0;

  PreviewState get state => _state;
  set state(PreviewState value) {
    _state = value;
    _apply(value == PreviewState.cycle ? _cycle.first : value);
  }

  void _apply(PreviewState s) {
    signal
      ..muted = s == PreviewState.muted
      ..mode = switch (s) {
        PreviewState.listening || PreviewState.silence => PresenceMode.listening,
        PreviewState.thinking => PresenceMode.thinking,
        PreviewState.speaking => PresenceMode.speaking,
        _ => PresenceMode.idle,
      };
  }

  void _tick(Timer _) {
    _t += _chunkMs / 1000;
    var s = _state;
    if (s == PreviewState.cycle) {
      s = _cycle[(_t / 6).floor() % _cycle.length];
      _apply(s);
    }
    switch (s) {
      case PreviewState.listening || PreviewState.speaking:
        signal.addAudio(_voice(_rate * _chunkMs ~/ 1000, s == PreviewState.speaking ? 105 : 150), _rate);
      case PreviewState.thinking:
        // Text and tool deltas arrive in bursts.
        if (math.sin(_t * 1.3) > -0.2 && _random.nextDouble() < 0.35) signal.bumpActivity(0.1);
      default:
    }
  }

  /// A voice-like signal: a pitched source through two moving formants, in syllables and phrases.
  Float32List _voice(int n, double pitch) {
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      final t = _t + i / _rate;
      final phrase = math.sin(t * 2 * math.pi * 0.21) > -0.55 ? 1.0 : 0.0;
      final syllable = math.pow(math.max(0, math.sin(t * 2 * math.pi * 3.3 + math.sin(t * 1.7))), 0.7);
      final f0 = pitch * (1 + 0.12 * math.sin(t * 2.3));
      _phase += 2 * math.pi * f0 / _rate;
      final f1 = 520 + 260 * math.sin(t * 5.1), f2 = 1650 + 600 * math.sin(t * 3.7 + 1);
      var v = 0.0;
      for (var h = 1; h <= 40; h++) {
        final f = f0 * h;
        final gain = 1 / (1 + math.pow((f - f1) / 140, 2)) + 0.6 / (1 + math.pow((f - f2) / 220, 2)) + 0.02;
        v += gain * math.sin(_phase * h);
      }
      final hiss = (_random.nextDouble() - 0.5) * 0.25 * math.max(0, math.sin(t * 2 * math.pi * 1.1));
      out[i] = (0.09 * v + hiss) * phrase * syllable;
    }
    return out;
  }

  void dispose() {
    _timer.cancel();
    signal.dispose();
  }
}

class PresencePreview extends StatefulWidget {
  const PresencePreview({super.key, required this.state, required this.layout});

  final PreviewState state;
  final PreviewLayout layout;

  @override
  State<PresencePreview> createState() => _PresencePreviewState();
}

class _PresencePreviewState extends State<PresencePreview> {
  static const List<PreviewState> _sheetStates = [
    PreviewState.idle,
    PreviewState.silence,
    PreviewState.listening,
    PreviewState.thinking,
    PreviewState.speaking,
    PreviewState.muted,
  ];

  late final PresenceDemo _demo = PresenceDemo(widget.state);
  late final List<PresenceDemo> _sheet = [for (final s in _sheetStates) PresenceDemo(s)];
  late PreviewLayout _layout = widget.layout;

  // Frames drawn since the last report, and the time their raster took.
  int _frames = 0;
  int _rasterMicros = 0;
  Timer? _report;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    // What the frame-rate cap actually does, in the log: frames per second and raster time.
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _report = Timer.periodic(const Duration(seconds: 2), (_) {
      final ms = _frames == 0 ? 0 : _rasterMicros / _frames / 1000;
      debugPrint('preview: ${(_frames / 2).toStringAsFixed(1)} fps, raster ${ms.toStringAsFixed(2)} ms');
      _frames = 0;
      _rasterMicros = 0;
    });
  }

  void _onTimings(List<FrameTiming> timings) {
    _frames += timings.length;
    for (final t in timings) {
      _rasterMicros += t.rasterDuration.inMicroseconds;
    }
  }

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    final state = switch (e.logicalKey) {
      LogicalKeyboardKey.digit1 => PreviewState.idle,
      LogicalKeyboardKey.digit2 => PreviewState.listening,
      LogicalKeyboardKey.digit3 => PreviewState.thinking,
      LogicalKeyboardKey.digit4 => PreviewState.speaking,
      LogicalKeyboardKey.keyM => PreviewState.muted,
      LogicalKeyboardKey.digit0 => PreviewState.cycle,
      _ => null,
    };
    if (state != null) {
      _demo.state = state;
    } else if (e.logicalKey == LogicalKeyboardKey.keyL) {
      setState(() => _layout = PreviewLayout.values[(_layout.index + 1) % PreviewLayout.values.length]);
    } else {
      return false;
    }
    return true;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _report?.cancel();
    _demo.dispose();
    for (final d in _sheet) {
      d.dispose();
    }
    super.dispose();
  }

  /// The always-on-top orb of main.dart: a dark disc with the orb in it.
  Widget _disc(PresenceSignal signal, double size) => Container(
        width: size + 2,
        height: size + 2,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF07050A).withValues(alpha: 0.88),
          border: Border.all(color: kPresenceAccent.withValues(alpha: 0.25)),
        ),
        child: ClipOval(child: PresenceView(signal: signal, compact: true, compactSize: size)),
      );

  @override
  Widget build(BuildContext context) {
    final signal = _demo.signal;
    return MaterialApp(
      title: 'Minerva presence preview',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, scaffoldBackgroundColor: const Color(0xFF07050A)),
      home: Scaffold(
        body: switch (_layout) {
          PreviewLayout.full => PresenceView(signal: signal),
          // As in MainView while a view is on screen.
          PreviewLayout.corner => Stack(children: [
              Positioned(top: 12, right: 12, child: PresenceView(signal: signal, compact: true, compactSize: 180)),
            ]),
          PreviewLayout.overlay => ColoredBox(color: const Color(0xFF3A4450), child: Center(child: _disc(signal, 122))),
          PreviewLayout.sheet => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final size in const [180.0, 122.0, 96.0])
                    Padding(
                      padding: const EdgeInsets.all(10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final d in _sheet)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: size == 122
                                  ? _disc(d.signal, size)
                                  : PresenceView(signal: d.signal, compact: true, compactSize: size),
                            ),
                        ],
                      ),
                    ),
                  const Text('idle   ·   silence   ·   listening   ·   thinking   ·   speaking   ·   muted',
                      style: TextStyle(color: Colors.white38, fontSize: 12)),
                ],
              ),
            ),
        },
      ),
    );
  }
}
