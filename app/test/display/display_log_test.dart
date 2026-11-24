import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/display/display_runner.dart';

void main() {
  List<String> replayed(DisplayLog log) {
    final names = <String>[];
    log.replay((name, args) => names.add('$name ${args['title'] ?? args['url'] ?? args['control'] ?? ''}'.trim()));
    return names;
  }

  test('keeps only the calls of the view on screen', () {
    final log = DisplayLog()
      ..record('show', {'title': 'A'})
      ..record('update', {'id': 'x'})
      ..record('show', {'title': 'B'})
      ..record('update', {'id': 'y'})
      ..record('get_state', {});
    expect(replayed(log), ['show B', 'update']);
  });

  test('clear drops everything', () {
    final log = DisplayLog()
      ..record('show', {'title': 'A'})
      ..record('clear', {});
    expect(replayed(log), isEmpty);
  });

  test('controlling a video keeps the video', () {
    final log = DisplayLog()
      ..record('video', {'url': 'https://example.com/a.mp4'})
      ..record('video', {'control': 'pause'});
    expect(replayed(log), ['video https://example.com/a.mp4', 'video pause']);
  });
}
