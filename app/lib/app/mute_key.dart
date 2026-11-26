import 'package:flutter/foundation.dart';

import '../l10n/l10n.dart';

/// The key that mutes and unmutes the Mac's mic: a macOS virtual key code with modifiers, or
/// Caps Lock (the native side is MuteKey in macos/Runner/MainFlutterWindow.swift). A key that
/// types works while Minerva is on screen and the user is not typing; Caps Lock and combos with
/// ⌘ or ⌃ work in any app ([global]).
@immutable
class MuteKey {
  const MuteKey(this.code, {this.modifiers = 0, this.char = ''});

  /// The default.
  static const space = MuteKey(49);
  static const capsLock = MuteKey(57);

  static const cmd = 1, ctrl = 2, alt = 4, shift = 8;

  /// macOS virtual key code (kVK_*).
  final int code;

  /// [cmd], [ctrl], [alt] and [shift].
  final int modifiers;

  /// What the key types on the user's keyboard layout, for its label ('' when nothing visible).
  final String char;

  bool get global => code == capsLock.code || modifiers & (cmd | ctrl) != 0;

  /// How Minerva's store keeps it.
  String encode() => '$code:$modifiers:$char';

  static MuteKey? decode(String? s) {
    if (s == null) return null;
    final parts = s.split(':');
    final code = int.tryParse(parts.first);
    if (code == null || parts.length < 2) return null;
    return MuteKey(code, modifiers: int.tryParse(parts[1]) ?? 0, char: parts.skip(2).join(':'));
  }

  /// As macOS writes shortcuts: ⌃⌥⇧⌘ and the key.
  String label(AppLocalizations l) {
    final mods = [
      if (modifiers & ctrl != 0) '⌃',
      if (modifiers & alt != 0) '⌥',
      if (modifiers & shift != 0) '⇧',
      if (modifiers & cmd != 0) '⌘',
    ].join();
    return '$mods${_name(l)}';
  }

  String _name(AppLocalizations l) {
    if (code == space.code) return l.keySpace;
    if (code == capsLock.code) return l.keyCapsLock;
    final named = _names[code];
    if (named != null) return named;
    final f = _functionKeys[code];
    if (f != null) return 'F$f';
    return char.isNotEmpty ? char.toUpperCase() : '#$code';
  }

  static const _names = {
    36: '↩', 76: '⌤', 48: '⇥', 51: '⌫', 117: '⌦', 53: 'Esc', 114: 'Help', //
    115: '↖', 119: '↘', 116: '⇞', 121: '⇟', 123: '←', 124: '→', 125: '↓', 126: '↑',
  };

  static const _functionKeys = {
    122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10, 103: 11, 111: 12, //
    105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20,
  };

  @override
  bool operator ==(Object other) => other is MuteKey && other.code == code && other.modifiers == modifiers;

  @override
  int get hashCode => Object.hash(code, modifiers);
}
