import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

/// One synthesized sentence.
class Speech {
  Speech(this.generation, this.text, this.samples);

  final int generation;
  final String text;
  final Float32List samples;
}

/// Supertonic 3 text-to-speech in a background isolate. Sentences come back in order.
class Speaker {
  Speaker._(this._isolate, this._send, this.sampleRate, this.speech);

  final Isolate _isolate;
  final SendPort _send;
  final int sampleRate;
  final Stream<Speech> speech;

  static Future<Speaker> start({required String modelDir, int voice = 6, double speed = 1.2}) async {
    final rx = ReceivePort();
    final isolate = await Isolate.spawn(_main, [rx.sendPort, modelDir, voice, speed]);
    final ready = Completer<(SendPort, int)>();
    final ctrl = StreamController<Speech>.broadcast();
    rx.listen((m) {
      if (m is List && m.length == 2 && m[0] is SendPort) {
        ready.complete((m[0] as SendPort, m[1] as int));
      } else if (m is String && m.startsWith('error:')) {
        if (!ready.isCompleted) ready.completeError(m);
      } else if (m is List) {
        ctrl.add(Speech(m[0] as int, m[1] as String,
            (m[2] as TransferableTypedData).materialize().asFloat32List()));
      }
    });
    final (port, rate) = await ready.future;
    return Speaker._(isolate, port, rate, ctrl.stream);
  }

  /// Queue a sentence. [generation] lets the caller drop audio from an interrupted turn.
  void say(int generation, String text) {
    final clean = cleanForSpeech(text);
    if (clean.isNotEmpty) _send.send([generation, clean]);
  }

  void dispose() => _isolate.kill(priority: Isolate.immediate);

  /// Remove markdown and symbols the voice would read out literally.
  static String cleanForSpeech(String text) => text
      .replaceAll(RegExp(r'[*_`#>|~]'), '')
      .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!)
      .replaceAll(RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static void _main(List<Object> args) {
    final out = args[0] as SendPort;
    final d = args[1] as String;
    final voice = args[2] as int;
    final speed = args[3] as double;
    try {
      so.initBindings();
      final tts = so.OfflineTts(so.OfflineTtsConfig(
        model: so.OfflineTtsModelConfig(
          supertonic: so.OfflineTtsSupertonicModelConfig(
            durationPredictor: '$d/duration_predictor.int8.onnx',
            textEncoder: '$d/text_encoder.int8.onnx',
            vectorEstimator: '$d/vector_estimator.int8.onnx',
            vocoder: '$d/vocoder.int8.onnx',
            ttsJson: '$d/tts.json',
            unicodeIndexer: '$d/unicode_indexer.bin',
            voiceStyle: '$d/voice.bin',
          ),
          numThreads: 4,
        ),
      ));
      final config = so.OfflineTtsGenerationConfig(sid: voice, speed: speed, numSteps: 5, extra: const {'lang': 'es'});
      tts.generateWithConfig(text: 'Hola.', config: config); // warm-up
      final rx = ReceivePort();
      out.send([rx.sendPort, tts.sampleRate]);
      rx.listen((m) {
        final gen = (m as List)[0] as int;
        final text = m[1] as String;
        final audio = tts.generateWithConfig(text: text, config: config);
        out.send([gen, text, TransferableTypedData.fromList([audio.samples])]);
      });
    } catch (e) {
      out.send('error: $e');
    }
  }
}
