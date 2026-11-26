import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/app/mute_key.dart';
import 'package:minerva/l10n/l10n.dart';

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final es = lookupAppLocalizations(const Locale('es'));

  test('labels keys as macOS writes shortcuts', () {
    expect(MuteKey.space.label(en), 'Space');
    expect(MuteKey.space.label(es), 'Espacio');
    expect(MuteKey.capsLock.label(es), 'Bloq Mayús');
    expect(const MuteKey(46, modifiers: MuteKey.cmd | MuteKey.shift, char: 'm').label(en), '⇧⌘M');
    expect(const MuteKey(49, modifiers: MuteKey.ctrl | MuteKey.alt).label(en), '⌃⌥Space');
    expect(const MuteKey(111).label(en), 'F12');
    expect(const MuteKey(126, modifiers: MuteKey.alt).label(en), '⌥↑');
  });

  test('Caps Lock and combos with cmd or ctrl are global', () {
    expect(MuteKey.space.global, isFalse);
    expect(const MuteKey(49, modifiers: MuteKey.alt).global, isFalse);
    expect(MuteKey.capsLock.global, isTrue);
    expect(const MuteKey(46, modifiers: MuteKey.ctrl).global, isTrue);
  });

  test('round-trips through the store', () {
    const k = MuteKey(41, modifiers: MuteKey.cmd, char: ':');
    final back = MuteKey.decode(k.encode())!;
    expect(back, k);
    expect(back.char, ':');
    expect(MuteKey.decode(null), isNull);
    expect(MuteKey.decode('x'), isNull);
  });
}
