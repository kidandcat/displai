import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

/// Something the listener heard.
sealed class HeardEvent {}

/// The user has been talking continuously for [bargeInSeconds]: enough to interrupt the assistant.
class SpeechStarted extends HeardEvent {}

/// A finished utterance (end of turn after [endSilence] of silence) and its transcript.
class Utterance extends HeardEvent {
  Utterance(this.text, this.seconds, this.speechEnd, this.sttDone);

  final String text;
  final double seconds;

  /// Estimated real end of speech (VAD close minus the end silence) and when STT finished.
  final DateTime speechEnd;
  final DateTime sttDone;
}

/// Voice activity detection + speech recognition (Silero VAD + Parakeet v3) in a background isolate.
///
/// Feed it echo-cancelled 16 kHz mic audio with [add]; it emits [SpeechStarted] and [Utterance].
class Listener {
  Listener._(this._isolate, this._send, this.events);

  static const double endSilence = 0.4;
  static const double bargeInSeconds = 0.3;

  final Isolate _isolate;
  final SendPort _send;
  final Stream<HeardEvent> events;

  static Future<Listener> start({
    required String vadModel,
    required String parakeetDir,
  }) async {
    final rx = ReceivePort();
    final isolate = await Isolate.spawn(_main, [
      rx.sendPort,
      vadModel,
      parakeetDir,
    ]);
    final ready = Completer<SendPort>();
    final ctrl = StreamController<HeardEvent>.broadcast();
    rx.listen((m) {
      if (m is SendPort) {
        ready.complete(m);
      } else if (m is String && m.startsWith('error:')) {
        if (!ready.isCompleted) ready.completeError(m);
      } else if (m == 'speech') {
        ctrl.add(SpeechStarted());
      } else if (m is List) {
        ctrl.add(
          Utterance(
            m[0] as String,
            m[1] as double,
            DateTime.fromMicrosecondsSinceEpoch(m[2] as int),
            DateTime.fromMicrosecondsSinceEpoch(m[3] as int),
          ),
        );
      }
    });
    return Listener._(isolate, await ready.future, ctrl.stream);
  }

  void add(Float32List samples) =>
      _send.send(TransferableTypedData.fromList([samples]));

  /// Drop buffered audio and any half-detected speech (used when the mic is muted).
  void reset() => _send.send('reset');

  /// Ends the utterance in progress now (as if silence followed) so it is still transcribed.
  void flush() => _send.send('flush');

  void dispose() => _isolate.kill(priority: Isolate.immediate);

  static void _main(List<Object> args) {
    final out = args[0] as SendPort;
    final vadModel = args[1] as String;
    final dir = args[2] as String;
    try {
      so.initBindings();
      final vadConfig = so.VadModelConfig(
        sileroVad: so.SileroVadModelConfig(
          model: vadModel,
          threshold: 0.5,
          minSilenceDuration: endSilence,
          minSpeechDuration: 0.25,
          maxSpeechDuration: 30,
        ),
        sampleRate: 16000,
        numThreads: 1,
        debug: false,
      );
      final vad = so.VoiceActivityDetector(
        config: vadConfig,
        bufferSizeInSeconds: 60,
      );
      final asr = so.OfflineRecognizer(
        so.OfflineRecognizerConfig(
          model: so.OfflineModelConfig(
            transducer: so.OfflineTransducerModelConfig(
              encoder: '$dir/encoder.int8.onnx',
              decoder: '$dir/decoder.int8.onnx',
              joiner: '$dir/joiner.int8.onnx',
            ),
            tokens: '$dir/tokens.txt',
            numThreads: 4,
            modelType: 'nemo_transducer',
            debug: false,
          ),
        ),
      );
      const win = 512;
      var buf = Float32List(0);
      var speechRun = 0;
      var announced = false;
      void drain() {
        while (!vad.isEmpty()) {
          final closedAt = DateTime.now();
          final seg = vad.front().samples;
          vad.pop();
          announced = false;
          final stream = asr.createStream();
          stream.acceptWaveform(samples: seg, sampleRate: 16000);
          asr.decode(stream);
          final text = asr.getResult(stream).text.trim();
          stream.free();
          final speechEnd = closedAt.subtract(
            Duration(milliseconds: (endSilence * 1000).round()),
          );
          out.send([
            text,
            seg.length / 16000,
            speechEnd.microsecondsSinceEpoch,
            DateTime.now().microsecondsSinceEpoch,
          ]);
        }
      }

      final rx = ReceivePort();
      out.send(rx.sendPort);
      rx.listen((m) {
        if (m == 'flush') {
          vad.flush();
          drain();
          buf = Float32List(0);
          vad.reset();
          speechRun = 0;
          announced = false;
          return;
        }
        if (m == 'reset') {
          buf = Float32List(0);
          vad.reset();
          speechRun = 0;
          announced = false;
          return;
        }
        final chunk = (m as TransferableTypedData)
            .materialize()
            .asFloat32List();
        final merged = Float32List(buf.length + chunk.length)
          ..setAll(0, buf)
          ..setAll(buf.length, chunk);
        var i = 0;
        while (merged.length - i >= win) {
          vad.acceptWaveform(Float32List.sublistView(merged, i, i + win));
          i += win;
          if (vad.isDetected()) {
            speechRun++;
            if (!announced && speechRun * win / 16000 >= bargeInSeconds) {
              announced = true;
              out.send('speech');
            }
          } else {
            speechRun = 0;
          }
          drain();
        }
        buf = Float32List.fromList(Float32List.sublistView(merged, i));
      });
    } catch (e) {
      out.send('error: $e');
    }
  }
}
