import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The phone's side of the brain's phone tools (see lib/remote/phone_tools.dart on the desktop):
/// they arrive over the link as display-like tool calls named phone_*, and run natively
/// (android/.../PhoneControl.kt with the accessibility service). Also the setup's status and the
/// floating orb's state.
class PhoneControl extends ChangeNotifier {
  static const _channel = MethodChannel('minerva/phone');

  /// Phone control exists on this platform (Android).
  static bool get supported => Platform.isAndroid;

  /// The accessibility service is enabled in the phone's settings.
  bool accessibility = false;

  /// It is enabled and the system has started it.
  bool running = false;

  /// The app may draw over other apps.
  bool overlay = false;

  /// How screenshots are taken: accessibility (Android 11+), projection (allowed this run) or
  /// ask (the phone asks the first time).
  String screenshots = 'ask';

  int sdk = 0;

  /// The status as the desktop gets it in the hello and in `control` messages.
  Map<String, Object?> get status => {
        'accessibility': running,
        'overlay': overlay,
        'screenshots': screenshots,
        'sdk': sdk,
      };

  /// Reads the setup's status; true when it changed.
  Future<bool> refresh() async {
    if (!supported) return false;
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('status') ?? const {};
      final before = jsonEncode(status);
      accessibility = m['accessibility'] == true;
      running = m['running'] == true;
      overlay = m['overlay'] == true;
      screenshots = '${m['screenshots'] ?? 'ask'}';
      sdk = (m['sdk'] as num?)?.toInt() ?? 0;
      final changed = jsonEncode(status) != before;
      notifyListeners();
      return changed;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> openAccessibilitySettings() => _channel.invokeMethod('openAccessibilitySettings');

  Future<void> openOverlaySettings() => _channel.invokeMethod('openOverlaySettings');

  Future<void> openAppInfo() => _channel.invokeMethod('openAppInfo');

  /// Brings Minerva's app back to the front (after the brain used other apps).
  Future<void> front() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod('front');
    } catch (e) {
      debugPrint('phone front failed: $e');
    }
  }

  /// Runs a phone tool: (text, error, png).
  Future<(String, bool, Uint8List?)> run(String name, Map<String, dynamic> args) async {
    if (!supported) return ('error: phone control needs the Android app', true, null);
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('run', {'name': name, 'args': args}) ?? const {};
      final text = '${m['text'] ?? ''}';
      return (text, m['error'] == true, m['png'] as Uint8List?);
    } on PlatformException catch (e) {
      return ('error: ${e.message ?? e.code}', true, null);
    }
  }

  /// The floating orb's state: shown while [connected] and Minerva is not in front.
  Future<void> orb({
    required bool connected,
    required String mode,
    required bool muted,
    required List<int> workers,
  }) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod('orb', {'connected': connected, 'mode': mode, 'muted': muted, 'workers': workers});
    } on MissingPluginException {
      // Not on Android.
    }
  }
}
