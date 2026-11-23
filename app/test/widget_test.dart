import 'package:displai/voice/speaker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cleanForSpeech strips markdown, links and emoji', () {
    expect(Speaker.cleanForSpeech('**Hola** [mundo](https://x.y) 🚀  ya'), 'Hola mundo ya');
  });
}
