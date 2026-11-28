import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/app/auto_mute.dart';

void main() {
  test('mutes while the output is silent and unmutes when it comes back', () {
    final m = AutoMute();
    expect(m.output(silent: true, muted: false), isTrue);
    expect(m.active, isTrue);
    expect(m.output(silent: false, muted: true), isFalse);
    expect(m.active, isFalse);
  });

  test('stays muted when the user had muted it by hand', () {
    final m = AutoMute();
    expect(m.output(silent: true, muted: true), isTrue);
    expect(m.output(silent: false, muted: true), isTrue);
  });

  test('the user muting or unmuting while silent keeps their choice', () {
    final m = AutoMute();
    m.output(silent: true, muted: false);
    m.manual();
    expect(m.active, isFalse);
    expect(m.output(silent: false, muted: false), isNull);

    m.output(silent: true, muted: false);
    m.manual();
    expect(m.output(silent: false, muted: true), isNull);
  });

  test('only a change of the output does something', () {
    final m = AutoMute();
    expect(m.output(silent: false, muted: false), isNull);
    expect(m.output(silent: true, muted: false), isTrue);
    m.manual();
    // Still silent (another device, the phone's state…): the user's unmute stays.
    expect(m.output(silent: true, muted: false), isNull);
    expect(m.output(silent: false, muted: false), isNull);
    expect(m.output(silent: true, muted: false), isTrue);
  });
}
