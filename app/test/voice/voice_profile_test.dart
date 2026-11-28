import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/voice/audio_file.dart';
import 'package:minerva/voice/listener.dart';
import 'package:minerva/voice/model_store.dart';
import 'package:minerva/voice/voice_profile.dart';

/// A voice: [base] plus a little noise, as embeddings of one speaker vary.
Float32List voiceLike(List<double> base, Random r, {double noise = 0.3}) =>
    Float32List.fromList([for (final v in base) v + noise * (r.nextDouble() - 0.5)]);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('minerva-voice-test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  final r = Random(7);
  final owner = [for (var i = 0; i < 192; i++) r.nextDouble() - 0.5];
  final other = [for (var i = 0; i < 192; i++) r.nextDouble() - 0.5];

  test('enrolls the first long utterances, then tells the owner from other voices', () async {
    final p = VoiceProfile('${tmp.path}/voice_profile.json', model: 'm');
    // Nothing is judged while enrolling, and short utterances teach nothing.
    expect(p.hear(voiceLike(owner, r), 1.2), VoiceMatch.unsure);
    expect(p.samples, 0);
    for (var i = 0; i < VoiceProfile.enrollSamples; i++) {
      expect(p.ready, isFalse);
      expect(p.hear(voiceLike(other, r), 0.5), VoiceMatch.unsure);
      expect(p.hear(voiceLike(owner, r), 2), VoiceMatch.unsure);
    }
    expect(p.ready, isTrue);
    expect(p.samples, VoiceProfile.enrollSamples);

    expect(p.hear(voiceLike(owner, r), 2), VoiceMatch.owner);
    expect(p.samples, VoiceProfile.enrollSamples + 1);
    // Another voice is not learned from.
    expect(p.hear(voiceLike(other, r), 2), VoiceMatch.foreign);
    expect(p.samples, VoiceProfile.enrollSamples + 1);
    // Too short to tell.
    expect(p.hear(voiceLike(other, r), 0.8), VoiceMatch.unsure);
  });

  test('a voice unlike the first ones does not enroll', () {
    final p = VoiceProfile('${tmp.path}/voice_profile.json', model: 'm');
    p.hear(voiceLike(owner, r), 2);
    p.hear(voiceLike(other, r), 2);
    expect(p.samples, 1);
  });

  test('is saved on disk only for its model, and forgotten on reset', () async {
    final path = '${tmp.path}/voice_profile.json';
    final p = VoiceProfile(path, model: 'm');
    for (var i = 0; i < VoiceProfile.enrollSamples; i++) {
      p.hear(voiceLike(owner, r), 2);
    }
    await p.saved;
    expect((await Process.run('stat', ['-f', '%Lp', path])).stdout.toString().trim(), '600');

    final again = VoiceProfile(path, model: 'm');
    await again.load();
    expect(again.ready, isTrue);
    expect(again.hear(voiceLike(other, r), 2), VoiceMatch.foreign);

    final otherModel = VoiceProfile(path, model: 'n');
    await otherModel.load();
    expect(otherModel.samples, 0);

    await again.reset();
    expect(again.ready, isFalse);
    expect(File(path).existsSync(), isFalse);
  });

  // The real speaker-embedding model, on voices spoken by macOS `say`. Runs only where the model is
  // installed (automatic wake word mode downloads it) and the app was built once.
  group('with the speaker model', () {
    final models = Platform.environment['MINERVA_MODELS_DIR'] ??
        '${Platform.environment['HOME']}/Library/Application Support/com.kidandcat.minerva/models';
    final ready = Platform.isMacOS &&
        File('$models/silero_vad_v5.onnx').existsSync() &&
        File('$models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/tokens.txt').existsSync() &&
        File('$models/$speakerFile').existsSync();

    test('another voice is told apart from the enrolled one', () async {
      final lib = [
        for (final mode in ['Debug', 'Release']) 'build/macos/Build/Products/$mode/libsherpa-onnx-c-api.dylib',
      ].where((f) => File(f).existsSync());
      if (lib.isEmpty) {
        markTestSkipped('build the macOS app first (no libsherpa-onnx-c-api.dylib)');
        return;
      }
      DynamicLibrary.open(lib.first);
      final listener = await Listener.start(
        vadModel: '$models/silero_vad_v5.onnx',
        parakeetDir: '$models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8',
      );
      addTearDown(listener.dispose);
      await listener.identifySpeakers('$models/$speakerFile');
      final utterances = StreamIterator(listener.events.where((e) => e is Utterance).cast<Utterance>());

      Future<Utterance> say(String voice, String text) async {
        final aiff = '${tmp.path}/say.aiff';
        final res = await Process.run('say', ['-v', voice, '-o', aiff, text]);
        expect(res.exitCode, 0, reason: '${res.stderr}');
        final samples = await AudioFile.decode(aiff);
        for (var i = 0; i < samples.length; i += 1600) {
          listener.add(Float32List.sublistView(samples, i, min(i + 1600, samples.length)));
        }
        listener.add(Float32List(16000));
        expect(await utterances.moveNext(), isTrue);
        return utterances.current;
      }

      final p = VoiceProfile('${tmp.path}/voice_profile.json', model: speakerFile);
      for (final text in [
        'Ponme la lista de la compra en la pantalla, por favor.',
        'Ayer estuve hablando con mi hermano sobre las vacaciones.',
        'Recuérdame mañana a las nueve que tengo que llamar al médico.',
        '¿Qué tiempo va a hacer este fin de semana en Madrid?',
        'Busca un restaurante italiano cerca de casa para esta noche.',
      ]) {
        final u = await say('Mónica', text);
        expect(u.voice, isNotNull);
        p.hear(u.voice!, u.seconds);
      }
      expect(p.ready, isTrue);
      final me = await say('Mónica', 'Apunta que el viernes tengo cena con mis amigos.');
      expect(p.hear(me.voice!, me.seconds), isNot(VoiceMatch.foreign));
      final other = await say('Grandpa (Spanish (Spain))', 'Apunta que el viernes tengo cena con mis amigos.');
      expect(p.hear(other.voice!, other.seconds), VoiceMatch.foreign);
      // Off again: no voice.
      await listener.identifySpeakers(null);
      expect((await say('Mónica', 'Ponme la lista de la compra, por favor.')).voice, isNull);
    }, skip: ready ? false : 'speaker model not installed', timeout: const Timeout(Duration(minutes: 3)));
  });
}
