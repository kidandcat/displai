import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The orb Minerva floats over the phone's other apps while it is linked to the desktop
/// (android/.../OrbOverlay.kt, lib/remote/phone_orb.dart), and bringing the app back to the front
/// to show a view. Both need Android's "display over other apps" permission.
class PhoneOverlay extends ChangeNotifier {
  static const _channel = MethodChannel('minerva/overlay');

  /// The overlay exists on this platform (Android).
  static bool get supported => Platform.isAndroid;

  /// The app may draw over other apps.
  bool allowed = false;

  /// Reads the permission again (the user may come back from the phone's settings).
  Future<void> refresh() async {
    if (!supported) return;
    try {
      final on = await _channel.invokeMethod<bool>('allowed') ?? false;
      if (on == allowed) return;
      allowed = on;
      notifyListeners();
    } on MissingPluginException {
      // Not on Android.
    }
  }

  Future<void> openSettings() => _channel.invokeMethod('openSettings');

  /// Brings Minerva's app back to the front (the user left it, and the brain shows a view).
  Future<void> front() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod('front');
    } catch (e) {
      debugPrint('phone front failed: $e');
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
