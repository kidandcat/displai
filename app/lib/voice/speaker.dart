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
///
/// Supertonic speaks 31 languages but does not detect them: each sentence is read as [language]
/// (an ISO 639-1 code, see `speechLanguages` in l10n.dart) unless [say] is given another one.
class Speaker {
  Speaker._(this._isolate, this._send, this.sampleRate, this.speech, this.language);

  final Isolate _isolate;
  final SendPort _send;
  final int sampleRate;
  final Stream<Speech> speech;

  /// The language [say] reads sentences in by default; it can change while the voice runs.
  String language;

  static Future<Speaker> start({
    required String modelDir,
    int voice = 6,
    double speed = 1.2,
    String language = 'en',
  }) async {
    final rx = ReceivePort();
    final isolate = await Isolate.spawn(_main, [rx.sendPort, modelDir, voice, speed, language]);
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
    return Speaker._(isolate, port, rate, ctrl.stream, language);
  }

  /// Queue a sentence, read as [lang] (default [language]). [generation] lets the caller drop
  /// audio from an interrupted turn.
  void say(int generation, String text, {String? lang}) {
    final clean = cleanForSpeech(text);
    if (clean.isNotEmpty) _send.send([generation, clean, lang ?? language]);
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
    final language = args[4] as String;
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
      final configs = <String, so.OfflineTtsGenerationConfig>{};
      so.OfflineTtsGenerationConfig config(String lang) => configs[lang] ??=
          so.OfflineTtsGenerationConfig(sid: voice, speed: speed, numSteps: 5, extra: {'lang': lang});
      tts.generateWithConfig(text: 'OK.', config: config(language)); // warm-up
      final rx = ReceivePort();
      out.send([rx.sendPort, tts.sampleRate]);
      rx.listen((m) {
        final gen = (m as List)[0] as int;
        final text = m[1] as String;
        final audio = tts.generateWithConfig(text: text, config: config(m[2] as String));
        out.send([gen, text, TransferableTypedData.fromList([audio.samples])]);
      });
    } catch (e) {
      out.send('error: $e');
    }
  }
}
