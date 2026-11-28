import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/voice/wake_word.dart';

void main() {
  group('strip', () {
    test('takes what follows the wake word', () {
      expect(WakeWord.strip('Minerva, ¿qué hora es?'), '¿qué hora es?');
      expect(WakeWord.strip('minerva pon música'), 'pon música');
      expect(WakeWord.strip('MINERVA. Apaga la luz.'), 'Apaga la luz.');
      expect(WakeWord.strip('Minerva: ¡para!'), '¡para!');
    });

    test('accepts common mis-hearings and a greeting before it', () {
      for (final said in [
        'Mi nerva, qué tiempo hace',
        'Minerba, qué tiempo hace',
        'Menerva qué tiempo hace',
        'Minelva, qué tiempo hace',
        'Miner va, qué tiempo hace',
        'Oye Minerva, qué tiempo hace',
        'oye, minerva, qué tiempo hace',
        'Hey Minerva qué tiempo hace',
        'Hola, Minerva. Qué tiempo hace',
        '¿Minerva, qué tiempo hace',
        '  "Minerva" qué tiempo hace',
        '¡Mínerva! qué tiempo hace',
      ]) {
        expect(WakeWord.strip(said)?.toLowerCase(), startsWith('qué tiempo hace'), reason: said);
      }
    });

    test('the wake word alone leaves nothing', () {
      expect(WakeWord.strip('Minerva'), '');
      expect(WakeWord.strip('Minerva.'), '');
      expect(WakeWord.strip('¿Minerva?'), '');
      expect(WakeWord.strip('Oye, Minerva…'), '');
    });

    test('other utterances are not for Minerva', () {
      for (final said in [
        '',
        'qué tiempo hace',
        'le dije a Minerva que no',
        'mi nueva casa es grande',
        'Minervas hay muchas',
        'oye, ¿vienes a comer?',
        'mineral',
        'Mi novia viene luego',
        'nerva',
      ]) {
        expect(WakeWord.strip(said), isNull, reason: said);
      }
    });
  });

  group('take', () {
    final t0 = DateTime(2026, 11, 28, 10);

    test('only what begins with the wake word', () {
      final w = WakeWord();
      expect(w.take('Minerva, apaga la luz', t0), 'apaga la luz');
      expect(w.take('apaga la luz', t0), isNull);
    });

    test('after the wake word alone the next utterance is for Minerva, within the window', () {
      final w = WakeWord();
      expect(w.take('Minerva', t0), '');
      expect(w.take('apaga la luz', t0.add(const Duration(seconds: 7))), 'apaga la luz');
      // Only that one.
      expect(w.take('y la de la cocina', t0.add(const Duration(seconds: 9))), isNull);

      expect(w.take('Oye Minerva', t0), '');
      expect(w.take('apaga la luz', t0.add(const Duration(seconds: 9))), isNull);

      expect(w.take('Minerva.', t0), '');
      w.reset();
      expect(w.take('apaga la luz', t0.add(const Duration(seconds: 1))), isNull);
    });
  });
}
