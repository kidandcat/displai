import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Dart side of the native voice-processing audio engine (macos/Runner/MainFlutterWindow.swift).
///
/// One engine does echo-cancelled capture and playback, so the user can talk over the assistant.
class NativeAudio {
  static const _methods = MethodChannel('displai/audio');
  static const _events = EventChannel('displai/audio_events');

  final _mic = StreamController<Float32List>.broadcast();
  final _out = StreamController<(Float32List, int)>.broadcast();
  final _idle = StreamController<void>.broadcast();
  StreamSubscription<dynamic>? _sub;
  bool _playing = false;

  /// Echo-cancelled mic audio, 16 kHz mono.
  Stream<Float32List> get mic => _mic.stream;

  /// Audio being played right now (samples, sample rate), for the presence animation.
  Stream<(Float32List, int)> get output => _out.stream;

  /// Fires when the playback queue drains (or after [stop]).
  Stream<void> get idle => _idle.stream;

  bool get isPlaying => _playing;

  Future<String> start({required int playRate}) async {
    _sub ??= _events.receiveBroadcastStream().listen((e) {
      final m = e as Map;
      switch (m['t']) {
        case 'mic':
          _mic.add(m['d'] as Float32List);
        case 'out':
          _out.add((m['d'] as Float32List, m['sr'] as int));
        case 'idle':
          _playing = false;
          _idle.add(null);
      }
    });
    return (await _methods.invokeMethod<String>('start', {'playRate': playRate}))!;
  }

  Future<void> play(Float32List samples) async {
    if (samples.isEmpty) return;
    _playing = true;
    await _methods.invokeMethod('play', samples);
  }

  Future<void> stop() async {
    _playing = false;
    await _methods.invokeMethod('stop');
  }
}
