import 'package:flutter/services.dart';

/// A screenshot from [Computer.screenshot].
///
/// Image pixels map to global screen points (origin at the top-left of the main display) as
/// `point = origin + px * scale`.
class Screenshot {
  const Screenshot({
    required this.png,
    required this.width,
    required this.height,
    required this.originX,
    required this.originY,
    required this.scale,
    this.windowId,
  });

  factory Screenshot.fromMap(Map<Object?, Object?> m, {int? windowId}) => Screenshot(
        png: m['png'] as Uint8List,
        width: (m['width'] as num).toInt(),
        height: (m['height'] as num).toInt(),
        originX: (m['originX'] as num).toDouble(),
        originY: (m['originY'] as num).toDouble(),
        scale: (m['scale'] as num).toDouble(),
        windowId: windowId,
      );

  final Uint8List png;
  final int width;
  final int height;
  final double originX;
  final double originY;

  /// Screen points per image pixel.
  final double scale;

  /// The captured window, or null for the whole main display.
  final int? windowId;

  bool contains(num x, num y) => x >= 0 && y >= 0 && x <= width && y <= height;

  /// Image pixel -> screen point.
  ({double x, double y}) toScreen(num x, num y) => (x: originX + x * scale, y: originY + y * scale);
}

/// The accessibility tree of one window, from [Computer.tree].
class AxTree {
  AxTree({required this.text, required this.count, required this.app, required this.pid});

  factory AxTree.fromMap(Map<Object?, Object?> m) => AxTree(
        text: m['text'] as String? ?? '',
        count: (m['count'] as num?)?.toInt() ?? 0,
        app: m['app'] as String? ?? '',
        pid: (m['pid'] as num?)?.toInt() ?? 0,
      );

  /// One element per line: `  [12] AXButton "Send" = "value" (x,y w×h)`.
  final String text;
  final int count;
  final String app;
  final int pid;

  late final Map<int, String> _lines = {
    for (final m in RegExp(r'^\s*\[(\d+)\] (.*)$', multiLine: true).allMatches(text))
      int.parse(m.group(1)!): m.group(2)!,
  };

  /// The line of element [index] without the index, e.g. `AXButton "Send" (10,20 30×40)`.
  String? line(int index) => _lines[index];

  /// The quoted label of element [index] (title or description), or null.
  String? label(int index) => labelOf(_lines[index]);

  /// The first quoted string of an element line, e.g. `Send` in `AXButton "Send" = "x" (…)`.
  static String? labelOf(String? line) {
    if (line == null) return null;
    return RegExp(r'^\S+ "([^"]*)"').firstMatch(line)?.group(1);
  }

  /// The role of an element line, e.g. `AXButton`.
  static String? roleOf(String? line) => line == null ? null : RegExp(r'^\S+').stringMatch(line);
}

/// The element under a screen point, from [Computer.elementAt].
typedef HitElement = ({String line, String app, int pid});

/// Dart side of the `displai/computer` method channel (macos/Runner/ComputerControl.swift).
///
/// Coordinates are global screen points. Errors arrive as [PlatformException] with codes such as
/// `no_accessibility`, `no_screen`, `bad_index`, `bad_args`, `not_found`.
class Computer {
  Computer({MethodChannel? channel}) : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'displai/computer';

  final MethodChannel _channel;

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) => _channel.invokeMethod<T>(
        method,
        args == null ? null : (Map<String, Object?>.of(args)..removeWhere((_, v) => v == null)),
      );

  Future<({bool accessibility, bool screen})> permissions() async => _perms(await _call<Map>('permissions'));

  /// Shows the system prompts for missing permissions and returns the current state.
  Future<({bool accessibility, bool screen})> requestPermissions() async =>
      _perms(await _call<Map>('requestPermissions'));

  static ({bool accessibility, bool screen}) _perms(Map? m) =>
      (accessibility: m?['accessibility'] == true, screen: m?['screen'] == true);

  /// Running regular apps: `{name, pid, bundleId, active}`.
  Future<List<Map<String, Object?>>> apps() async => _list(await _call<List>('apps'));

  /// On-screen app windows, front to back: `{id, pid, app, title, x, y, w, h}` (points).
  Future<List<Map<String, Object?>>> windows() async => _list(await _call<List>('windows'));

  static List<Map<String, Object?>> _list(List? l) =>
      [for (final e in l ?? const []) Map<String, Object?>.from(e as Map)];

  Future<Screenshot> screenshot({int? windowId}) async =>
      Screenshot.fromMap((await _call<Map>('screenshot', {'windowId': windowId}))!, windowId: windowId);

  /// Accessibility tree of the focused window of [pid] (the app in front when null).
  Future<AxTree> tree({int? pid, int maxNodes = 300}) async =>
      AxTree.fromMap((await _call<Map>('tree', {'pid': pid, 'maxNodes': maxNodes}))!);

  /// The element under a screen point, or null.
  Future<HitElement?> elementAt(double x, double y) async {
    final m = await _call<Map>('elementAt', {'x': x, 'y': y});
    if (m == null) return null;
    return (line: m['line'] as String? ?? '', app: m['app'] as String? ?? '', pid: (m['pid'] as num?)?.toInt() ?? 0);
  }

  /// Clicks element [index] of the last [tree], or the screen point [x],[y].
  Future<String> click({int? index, double? x, double? y, String button = 'left', int count = 1}) async =>
      await _call<String>('click', {'index': index, 'x': x, 'y': y, 'button': button, 'count': count}) ?? '';

  /// Types [text] (newlines press Return), focusing element [index] of the last [tree] first.
  Future<String> type(String text, {int? index}) async =>
      await _call<String>('type', {'text': text, 'index': index}) ?? '';

  /// Presses a key combo such as `cmd+t`, `return`, `cmd+shift+4`.
  Future<String> key(String combo) async => await _call<String>('key', {'combo': combo}) ?? '';

  /// Scrolls by lines (dy > 0 down, dx > 0 right), at screen point [x],[y] when given.
  Future<String> scroll({int dx = 0, int dy = 0, double? x, double? y}) async =>
      await _call<String>('scroll', {'dx': dx, 'dy': dy, 'x': x, 'y': y}) ?? '';

  /// Opens an app (name or bundle id), a URL or a file path.
  Future<String> open(String target) async => await _call<String>('open', {'target': target}) ?? '';

  /// Brings the app [pid] to the front.
  Future<String> activate(int pid) async => await _call<String>('activate', {'pid': pid}) ?? '';
}
