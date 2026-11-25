import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/voice/audio_file.dart';
import 'package:minerva/voice/listener.dart';

/// A 16-bit PCM WAV of [frames] (one list of samples per channel, -1..1).
Uint8List wav(List<List<double>> channels, int rate, {int format = 1, bool unsizedData = false}) {
  final n = channels.first.length, ch = channels.length;
  final data = ByteData(n * ch * 2);
  for (var i = 0; i < n; i++) {
    for (var c = 0; c < ch; c++) {
      data.setInt16((i * ch + c) * 2, (channels[c][i] * 32767).round(), Endian.little);
    }
  }
  final h = ByteData(44);
  void tag(int at, String s) => s.codeUnits.asMap().forEach((i, c) => h.setUint8(at + i, c));
  tag(0, 'RIFF');
  h.setUint32(4, 36 + data.lengthInBytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, format, Endian.little);
  h.setUint16(22, ch, Endian.little);
  h.setUint32(24, rate, Endian.little);
  h.setUint32(28, rate * ch * 2, Endian.little);
  h.setUint16(32, ch * 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  h.setUint32(40, unsizedData ? 0 : data.lengthInBytes, Endian.little);
  return Uint8List.fromList([...h.buffer.asUint8List(), ...data.buffer.asUint8List()]);
}

void main() {
  group('parseWav', () {
    test('mono 16-bit samples', () {
      final s = AudioFile.parseWav(wav([[0, 0.5, -0.5, 1]], 16000));
      expect(s, hasLength(4));
      expect(s[1], closeTo(0.5, 1e-3));
      expect(s[2], closeTo(-0.5, 1e-3));
    });

    test('stereo keeps the first channel; an unset data size reads to the end', () {
      final s = AudioFile.parseWav(wav([[0.25, 0.25, 0.25], [-1, -1, -1]], 16000, unsizedData: true));
      expect(s, hasLength(3));
      expect(s.every((v) => (v - 0.25).abs() < 1e-3), isTrue);
    });

    test('rejects what is not 16-bit PCM WAV', () {
      expect(() => AudioFile.parseWav(Uint8List.fromList('OggS and more bytes'.codeUnits)), throwsA(isA<AudioFileException>()));
      expect(() => AudioFile.parseWav(wav([[0, 0]], 16000, format: 3)), throwsA(isA<AudioFileException>()));
    });
  });

  group('decode', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('minerva-audio-test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('resamples any file to 16 kHz mono', () async {
      // One second of a 440 Hz tone, 44.1 kHz stereo.
      final tone = [for (var i = 0; i < 44100; i++) 0.5 * sin(2 * pi * 440 * i / 44100)];
      final f = File('${tmp.path}/tone.wav')..writeAsBytesSync(wav([tone, tone], 44100));
      final s = await AudioFile.decode(f.path);
      expect(s.length, inInclusiveRange(15900, 16100));
      expect(s.map((v) => v.abs()).reduce(max), closeTo(0.5, 0.05));
    }, skip: Platform.isMacOS ? false : 'afconvert is macOS only');

    test('a file no converter reads is an error', () async {
      final f = File('${tmp.path}/voice.oga')..writeAsStringSync('not audio at all');
      await expectLater(AudioFile.decode(f.path), throwsA(isA<AudioFileException>()));
    }, skip: Platform.isMacOS ? false : 'afconvert is macOS only');
  });

  // The real recognizer, on a phrase spoken by macOS `say`. Runs only where the speech models are
  // installed (MINERVA_MODELS_DIR, else Minerva's default models folder) and the app was built once:
  // sherpa-onnx looks its library up in the process, so the test loads the built one first.
  group('transcribe with the speech models', () {
    final models = Platform.environment['MINERVA_MODELS_DIR'] ??
        '${Platform.environment['HOME']}/Library/Application Support/com.kidandcat.minerva/models';
    final ready = Platform.isMacOS &&
        File('$models/silero_vad_v5.onnx').existsSync() &&
        File('$models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/tokens.txt').existsSync();

    test('a spoken recording comes back as text', () async {
      final tmp = Directory.systemTemp.createTempSync('minerva-stt-test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final aiff = '${tmp.path}/say.aiff';
      final r = await Process.run('say', ['-o', aiff, 'Remind me to buy bread tomorrow morning.']);
      if (r.exitCode != 0) markTestSkipped('say failed: ${r.stderr}');
      final lib = [
        for (final mode in ['Debug', 'Release']) 'build/macos/Build/Products/$mode/libsherpa-onnx-c-api.dylib',
      ].where((f) => File(f).existsSync());
      if (lib.isEmpty) {
        markTestSkipped('build the macOS app first (no libsherpa-onnx-c-api.dylib)');
        return;
      }
      DynamicLibrary.open(lib.first);
      final Listener listener;
      try {
        listener = await Listener.start(
          vadModel: '$models/silero_vad_v5.onnx',
          parakeetDir: '$models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8',
        );
      } catch (e) {
        markTestSkipped('sherpa-onnx did not load here: $e');
        return;
      }
      addTearDown(listener.dispose);
      // Telegram voice notes are Ogg Opus: make one when ffmpeg is there to encode it.
      var audio = aiff;
      final ffmpeg = ['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg'].where((f) => File(f).existsSync());
      if (ffmpeg.isNotEmpty) {
        final oga = '${tmp.path}/voice.oga';
        final e = await Process.run(ffmpeg.first, ['-loglevel', 'error', '-i', aiff, '-c:a', 'libopus', '-b:a', '32k', oga]);
        if (e.exitCode == 0) audio = oga;
      }
      final samples = await AudioFile.decode(audio);
      final text = (await listener.transcribe(samples)).toLowerCase();
      expect(text, contains('bread'));
      expect(text, contains('tomorrow'));
      // Silence has no speech in it.
      expect(await listener.transcribe(Float32List(16000)), isEmpty);
    }, skip: ready ? false : 'speech models not installed', timeout: const Timeout(Duration(minutes: 2)));
  });
}
