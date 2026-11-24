import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart side of the desktop window's states (macos/Runner/MainFlutterWindow.swift).
///
/// Minerva runs as a service: the window can be [open] (the Mac listens and speaks) or closed
/// (the app keeps running without the Mac's mic). While a phone is connected, or while Minerva
/// works in other apps of the Mac, the window becomes an [overlay]: a small orb, always on top in
/// a corner of the screen.
class DesktopWindow extends ChangeNotifier {
  static const _channel = MethodChannel('minerva/window');

  bool _open = true;
  bool _overlay = false;

  /// The user has the window open (not closed or minimized).
  bool get open => _open;

  /// The window is the corner orb shown while a phone is connected.
  bool get overlay => _overlay;

  /// The overlay orb was clicked.
  VoidCallback? onTap;

  /// The user asked for the window (menu bar, Spotlight, Finder) while it is the orb because
  /// Minerva works in other apps.
  VoidCallback? onOpenRequested;

  Future<void> init() async {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'state':
          _apply(call.arguments as Map);
        case 'tap':
          onTap?.call();
        case 'openRequested':
          onOpenRequested?.call();
      }
      return null;
    });
    try {
      final state = await _channel.invokeMethod<Map<Object?, Object?>>('state');
      if (state != null) _apply(state);
    } on MissingPluginException {
      // Not the macOS runner (e.g. a test): behave as an always open window.
    }
  }

  void _apply(Map<Object?, Object?> state) {
    final open = state['open'] == true, overlay = state['overlay'] == true;
    if (open == _open && overlay == _overlay) return;
    _open = open;
    _overlay = overlay;
    debugPrint('window: open=$open overlay=$overlay');
    notifyListeners();
  }

  /// Turns the window into the corner orb, or back. [reason] is 'phone' or 'computer'.
  Future<void> setOverlay(bool on, {String reason = 'phone'}) async {
    // Switch the view first, so the full screen is never squeezed into the small orb window.
    if (on != _overlay) {
      _overlay = on;
      notifyListeners();
    }
    try {
      await _channel.invokeMethod('setOverlay', {'on': on, 'reason': reason});
    } on MissingPluginException {
      return;
    }
  }

  /// Opens the normal window.
  Future<void> show() async {
    try {
      await _channel.invokeMethod('show');
    } on MissingPluginException {
      return;
    }
  }
}
