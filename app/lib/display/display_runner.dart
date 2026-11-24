import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart' show GlobalKey, WidgetsBinding;

import 'display_controller.dart';
import 'form_widgets.dart' show secretsHidden;
import 'html_widgets.dart' show capturePages;

/// Runs display tool calls against a [DisplayController] that is on screen, the same way on
/// the desktop and on the phone remote.
class DisplayRunner {
  /// The display tools whose call changes what is shown (replayed when the display moves).
  static const mutating = {'show', 'update', 'form', 'video', 'html', 'clear', 'back'};

  /// Runs [name] and, for calls that change the view, waits for it to lay out and adds a
  /// warning when it does not fit. Returns the result text (starting with "error:" on failure).
  static Future<String> run(DisplayController display, String name, Map<String, dynamic> args) async {
    final text = display.callTool(name, args);
    if (text.startsWith('error:')) return text;
    if (const {'show', 'update', 'form', 'back', 'html'}.contains(name)) {
      // Bounded: a hidden or minimised window produces no frames.
      await frame();
      await frame();
      var out = text;
      final cut = display.overflow;
      if (cut > 0) {
        out = '$out\nwarning: the view does not fit the screen; about ${cut.round()} px '
            'at the bottom are cut off (the display never scrolls). Update it to show less or split '
            'it into several views.';
      }
      // Custom pages: wait for them to load and report their JS errors.
      final pages = await display.settleHtml();
      if (pages.isNotEmpty) out = '$out\n$pages';
      return out;
    }
    return text;
  }

  /// Waits for the next frame. Forced, because Flutter stops drawing while the window is hidden
  /// behind others (lifecycle hidden), and the display must still lay out and be captured.
  static Future<void> frame() {
    WidgetsBinding.instance.scheduleForcedFrame();
    return WidgetsBinding.instance.endOfFrame.timeout(const Duration(milliseconds: 400), onTimeout: () {});
  }

  /// A PNG of what [screenKey] (a RepaintBoundary) shows, at most 1280 px on the long side,
  /// with its logical size; or null when it is not on screen. Secret form fields are drawn
  /// obscured in it even when the user revealed them.
  static Future<(Uint8List, ui.Size)?> capture(GlobalKey screenKey) async {
    secretsHidden.value++;
    try {
      return await _capture(screenKey);
    } finally {
      secretsHidden.value--;
    }
  }

  static Future<(Uint8List, ui.Size)?> _capture(GlobalKey screenKey) async {
    await frame();
    final boundary = screenKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return null;
    final size = boundary.size;
    final ratio = math.min(2.0, 1280 / math.max(size.width, size.height));
    var image = await boundary.toImage(pixelRatio: ratio);
    // Custom pages are platform views, blank in Flutter's capture: draw their snapshots over it.
    final pages = await capturePages();
    if (pages.isNotEmpty && boundary.attached) {
      final origin = boundary.localToGlobal(Offset.zero);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..drawImage(image, Offset.zero, Paint());
      canvas
        ..scale(ratio)
        ..clipRect(Offset.zero & size);
      for (final (rect, shot) in pages) {
        canvas.drawImageRect(
          shot,
          Offset.zero & Size(shot.width.toDouble(), shot.height.toDouble()),
          rect.shift(-origin),
          Paint()..filterQuality = FilterQuality.medium,
        );
        shot.dispose();
      }
      final composed = await recorder.endRecording().toImage(image.width, image.height);
      image.dispose();
      image = composed;
    }
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) return null;
    return (data.buffer.asUint8List(), size);
  }
}

/// The display calls that built what is shown, so the display can be rebuilt on another
/// screen (the phone remote when it joins, the desktop when it leaves).
class DisplayLog {
  final List<(String, Map<String, dynamic>)> _calls = [];

  /// As many views as the display's timeline keeps.
  static const maxViews = DisplayController.maxTimeline;

  /// Notes a display call that succeeded.
  void record(String name, Map<String, dynamic> args) {
    if (!DisplayRunner.mutating.contains(name)) return;
    _calls.add((name, args));
    var views = _calls.where((e) => _opensView(e.$1)).length;
    while (views > maxViews) {
      final first = _calls.removeAt(0);
      if (_opensView(first.$1)) views--;
      // Drop the calls that changed the view that just went away.
      while (_calls.isNotEmpty && !_opensView(_calls.first.$1)) {
        _calls.removeAt(0);
      }
    }
  }

  static bool _opensView(String name) => const {'show', 'form', 'video', 'html'}.contains(name);

  /// Replays the logged calls through [run] (after a reset of that display).
  void replay(void Function(String name, Map<String, dynamic> args) run) {
    for (final (name, args) in _calls) {
      run(name, args);
    }
  }
}
