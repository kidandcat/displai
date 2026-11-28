import 'dart:async';
import 'dart:ui' show Locale, Offset, Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import 'mute_key.dart';

/// Dart side of the desktop window's states (macos/Runner/MainFlutterWindow.swift).
///
/// Minerva runs as a service: the window can be [open] (the Mac listens and speaks) or closed
/// (the app keeps running without the Mac's mic). On screen, the window covers the whole main
/// screen, transparent and click-through: the full view is a [panel] on it (see OverlayShell).
/// While a phone is connected, while Minerva works in other apps of the Mac, or while the user is
/// in another app (the native side turns the full view into the orb when they go to one), it is
/// the [overlay]: just the orb on the right edge of the screen, and the widgets Minerva pops.
class DesktopWindow extends ChangeNotifier {
  static const _channel = MethodChannel('minerva/window');

  bool _open = true;
  bool _overlay = false;
  String _reason = 'phone';
  EdgeInsets _insets = EdgeInsets.zero;
  Rect? _panel;
  Offset? _orb;

  /// The user has the window open (not closed).
  bool get open => _open;

  /// The window is the orb shown while a phone is connected, Minerva uses the Mac or the
  /// user is in another app.
  bool get overlay => _overlay;

  /// Why it is the orb: 'phone', 'computer' or 'away' (the user went to another app).
  String get reason => _reason;

  /// What the menu bar and the Dock cover of the screen.
  EdgeInsets get insets => _insets;

  /// Where the user left the full view's panel (null: not known yet); only its width is kept, the
  /// panel goes back to the left edge of the screen.
  Rect? get panel => _panel;

  /// Where the user dragged the orb (null: the right edge, centred vertically).
  Offset? get orb => _orb;

  /// The full view's panel is on screen (false once it has become the orb), set by the shell.
  /// The display is drawn in the panel only while it is; else in Minerva's widgets.
  final panelShown = ValueNotifier(true);

  /// The user asked for the window (menu bar, Spotlight, Finder) while it is the orb because
  /// Minerva works in other apps.
  VoidCallback? onOpenRequested;

  /// The mute key was pressed, in Minerva's window or in another app (see [MuteKey]).
  VoidCallback? onMuteKey;

  bool _keyAccess = true;
  bool _keyActive = false;

  /// Minerva has the Accessibility permission, which the mute key needs in other apps.
  bool get keyAccess => _keyAccess;

  /// The mute key works in other apps too (the native keyboard tap is in place).
  bool get keyActive => _keyActive;

  bool _typing = false;

  bool _outputSilent = false;

  /// Nobody can hear the Mac: its output is muted or at volume 0 (the native side watches it).
  bool get outputSilent => _outputSilent;

  Future<void>? _connected;

  /// Connects to the native window; again later (the assistant, once its language is known),
  /// only gives the native menus the language setting.
  Future<void> init() async {
    await (_connected ??= _connect());
    await setLanguage(languageSetting.value, save: false);
  }

  Future<void> _connect() async {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'state':
          _apply(call.arguments as Map);
        case 'openRequested':
          onOpenRequested?.call();
        case 'muteKey':
          onMuteKey?.call();
        case 'muteKeyStatus':
          _applyKeyStatus(call.arguments);
        case 'outputSilent':
          _applyOutputSilent(call.arguments);
      }
      return null;
    });
    try {
      final state = await _channel.invokeMethod<Map<Object?, Object?>>('state');
      if (state != null) _apply(state);
      _applyOutputSilent(await _channel.invokeMethod<bool>('outputSilent'));
    } on MissingPluginException {
      // Not the macOS runner (e.g. a test): behave as an always open window.
    }
  }

  void _apply(Map<Object?, Object?> state) {
    final open = state['open'] == true, overlay = state['overlay'] == true;
    final reason = state['reason'] as String? ?? _reason;
    final i = _numbers(state['insets']), p = _numbers(state['panel']), o = _numbers(state['orb']);
    final insets = i.length == 4 ? EdgeInsets.fromLTRB(i[0], i[1], i[2], i[3]) : _insets;
    final panel = p.length == 4 ? Rect.fromLTWH(p[0], p[1], p[2], p[3]) : _panel;
    final orb = o.length == 2 ? Offset(o[0], o[1]) : _orb;
    if (open == _open && overlay == _overlay && reason == _reason && insets == _insets &&
        (_panel != null || panel == null) && orb == _orb) {
      return;
    }
    if (open != _open || overlay != _overlay) debugPrint('window: open=$open overlay=$overlay');
    _open = open;
    _overlay = overlay;
    _reason = reason;
    _insets = insets;
    // The panel the user is moving is the shell's; only the first one comes from here.
    _panel ??= panel;
    _orb = orb;
    notifyListeners();
  }

  static List<double> _numbers(Object? v) =>
      v is List ? [for (final n in v) if (n is num) n.toDouble()] : const [];

  /// Turns the window into the orb, or back. [reason] is 'phone' or 'computer'.
  Future<void> setOverlay(bool on, {String reason = 'phone'}) async {
    if (on != _overlay || (on && reason != _reason)) {
      _overlay = on;
      if (on) _reason = reason;
      notifyListeners();
    }
    await _invoke('setOverlay', {'on': on, 'reason': reason});
  }

  /// Where the window takes clicks (everything Minerva draws on it); the rest goes through to
  /// the apps below.
  Future<void> setHitRects(List<Rect> rects) =>
      _invoke('setHitRects', [for (final r in rects) _list(r)]);

  /// The user moved or resized the full view's panel: remember it.
  void setPanel(Rect r) {
    _panel = r;
    unawaited(_invoke('setPanel', _list(r)));
  }

  /// The user dragged the orb: remember where.
  void setOrb(Offset p) {
    _orb = p;
    unawaited(_invoke('setOrb', [p.dx, p.dy]));
  }

  /// Minerva's menu (open, quit), at the mouse.
  Future<void> contextMenu() => _invoke('contextMenu');

  static List<double> _list(Rect r) => [r.left, r.top, r.width, r.height];

  Future<void> _invoke(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod(method, args);
    } on MissingPluginException {
      return;
    }
  }

  /// Gives the native menus Minerva's language setting (null: the system's). [save] (the user
  /// changed it): also make it the app's own macOS language, for the menu bar and the system
  /// dialogs from the next launch, and read the user's languages for all apps (see
  /// [systemLocales]), which the app's own no longer tell.
  Future<void> setLanguage(String? code, {bool save = true}) async {
    try {
      await _channel.invokeMethod('setLanguage', {'code': code, 'save': save});
      if (!save) return;
      final langs = await _channel.invokeListMethod<String>('systemLanguages');
      if (langs != null && langs.isNotEmpty) systemLocales = [for (final l in langs) _parseLocale(l)];
    } on MissingPluginException {
      return;
    }
  }

  static Locale _parseLocale(String tag) {
    final parts = tag.split(RegExp('[-_]'));
    return Locale(parts.first, parts.length > 1 && parts[1].length == 2 ? parts[1] : null);
  }

  /// Makes [key] the mute key.
  Future<void> setMuteKey(MuteKey key) async {
    try {
      _applyKeyStatus(await _channel.invokeMethod('setMuteKey', {'code': key.code, 'modifiers': key.modifiers}));
    } on MissingPluginException {
      return;
    }
  }

  /// The next key or combo the user presses in Minerva's window, which the window does not get
  /// (null: Escape, or [cancelMuteKeyRecord]).
  Future<MuteKey?> recordMuteKey() async {
    try {
      final r = await _channel.invokeMapMethod<String, Object?>('recordMuteKey');
      if (r == null) return null;
      return MuteKey(r['code'] as int, modifiers: r['modifiers'] as int? ?? 0, char: r['char'] as String? ?? '');
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> cancelMuteKeyRecord() => _invoke('cancelMuteKey');

  /// Asks macOS for the permissions the mute key needs in other apps.
  Future<void> requestKeyAccess() async {
    try {
      _applyKeyStatus(await _channel.invokeMethod('requestKeyAccess'));
    } on MissingPluginException {
      return;
    }
  }

  /// A text field of Minerva's has the keyboard: the mute key types there (unless it is global).
  void setTyping(bool typing) {
    if (typing == _typing) return;
    _typing = typing;
    unawaited(_invoke('setTyping', typing));
  }

  void _applyKeyStatus(Object? status) {
    if (status is! Map) return;
    final access = status['accessibility'] == true, active = status['active'] == true;
    if (access == _keyAccess && active == _keyActive) return;
    _keyAccess = access;
    _keyActive = active;
    notifyListeners();
  }

  void _applyOutputSilent(Object? silent) {
    if (silent is! bool || silent == _outputSilent) return;
    debugPrint('window: output ${silent ? 'silent' : 'audible'}');
    _outputSilent = silent;
    notifyListeners();
  }

  /// Opens the normal window.
  Future<void> show() => _invoke('show');

  /// Closes it (the full view goes away; the Mac stops listening).
  Future<void> hide() => _invoke('hide');

  @override
  void dispose() {
    panelShown.dispose();
    super.dispose();
  }
}
