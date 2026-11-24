import 'package:flutter/services.dart';

import '../mcp/display_mcp_server.dart';
import '../tools/tool_provider.dart';
import '../vault/vault.dart';
import 'computer.dart';

/// Computer use: see the screen, read the accessibility tree, click, type, press keys, scroll,
/// open and activate apps.
///
/// Coordinates the model passes (x, y) are pixels of the LAST `screen` image; they are converted
/// to screen points here, so the model never deals with scale or origin. Elements from `ui_tree`
/// are targeted by index, which is more robust than pixels.
///
/// Every action runs at once; nothing is confirmed by the user (design §3.5).
class ComputerTools extends ToolProvider {
  ComputerTools({Computer? computer, this.settle = const Duration(milliseconds: 300), this.vault})
      : computer = computer ?? Computer();

  final Computer computer;

  /// Fills `{{vault:name.field}}` placeholders in type_text (design §3.9).
  final Vault? vault;

  /// Wait after an action so the UI reacts before the model looks again.
  final Duration settle;

  /// Tools that act on (or look at) the whole screen of the Mac: Minerva's window gets out of
  /// the way first (it shrinks to the corner orb), so it neither covers the apps nor takes their
  /// keyboard. `screen` of one window does not need it.
  static bool needsScreen(String name, Map<String, dynamic> args) => switch (name) {
        'click' || 'type_text' || 'press_key' || 'scroll' || 'open' || 'activate' => true,
        'screen' => args['window_id'] == null,
        _ => false,
      };

  Screenshot? _shot;
  AxTree? _tree;
  bool _askedPermissions = false;

  static const _index = {'type': 'integer', 'description': 'Element [n] from the last ui_tree.'};
  static const _px = {'type': 'number', 'description': 'Pixel in the last screen image.'};

  @override
  final List<McpTool> tools = const [
    McpTool(
      'screen',
      'Screenshot of the main display, or of one window (window_id from windows). x,y you pass to '
          'click/scroll are pixels of the LAST screenshot.',
      {
        'type': 'object',
        'properties': {
          'window_id': {'type': 'integer'},
        },
      },
    ),
    McpTool('apps', 'Running apps: name, pid, bundle id, which is active.', {'type': 'object', 'properties': {}}),
    McpTool(
      'windows',
      'On-screen app windows, front to back: id, app, pid, title, frame.',
      {'type': 'object', 'properties': {}},
    ),
    McpTool(
      'ui_tree',
      'Accessibility tree of the focused window of the app in front (or pid): lines '
          '`[n] Role "label" = "value" (x,y w×h)`. Target elements by index n in click/type_text '
          '(preferred over pixels). Indexes are valid until the next ui_tree.',
      {
        'type': 'object',
        'properties': {
          'pid': {'type': 'integer'},
        },
      },
    ),
    McpTool(
      'click',
      'Click element index (buttons/links are pressed directly), or pixel x,y of the last screen '
          'image.',
      {
        'type': 'object',
        'properties': {
          'index': _index,
          'x': _px,
          'y': _px,
          'button': {
            'type': 'string',
            'enum': ['left', 'right'],
          },
          'double': {'type': 'boolean'},
        },
      },
    ),
    McpTool(
      'type_text',
      'Type text at the keyboard focus, or into element index after focusing it. "\\n" presses '
          'Return. {{vault:name.field}} placeholders are filled in.',
      {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
          'index': _index,
        },
        'required': ['text'],
      },
    ),
    McpTool(
      'press_key',
      'Press a key or combo in the app in front, e.g. return, escape, tab, space, delete, down, '
          'pagedown, cmd+t, cmd+l, cmd+shift+4.',
      {
        'type': 'object',
        'properties': {
          'combo': {'type': 'string'},
        },
        'required': ['combo'],
      },
    ),
    McpTool(
      'scroll',
      'Scroll by lines: dy>0 down, dx>0 right. x,y: pixel of the last screen image to scroll over '
          '(default: where the pointer is).',
      {
        'type': 'object',
        'properties': {
          'dy': {'type': 'integer'},
          'dx': {'type': 'integer'},
          'x': _px,
          'y': _px,
        },
      },
    ),
    McpTool(
      'open',
      'Open an app (name or bundle id), a URL or a file path, and bring it to the front.',
      {
        'type': 'object',
        'properties': {
          'target': {'type': 'string'},
        },
        'required': ['target'],
      },
    ),
    McpTool(
      'activate',
      'Bring an app to the front (pid from apps or windows).',
      {
        'type': 'object',
        'properties': {
          'pid': {'type': 'integer'},
        },
        'required': ['pid'],
      },
    ),
  ];

  @override
  Future<ToolResult> call(String name, Map<String, dynamic> args) async {
    try {
      switch (name) {
        case 'screen':
          return await _screen(args);
        case 'apps':
          return await _apps();
        case 'windows':
          return await _windows();
        case 'ui_tree':
          return await _uiTree(args);
        case 'click':
          return await _click(args);
        case 'type_text':
          return await _type(args);
        case 'press_key':
          return await _key(args);
        case 'scroll':
          return await _scroll(args);
        case 'open':
          return await _open(args);
        case 'activate':
          final pid = _int(args['pid']);
          if (pid == null) return const ToolResult.error('pid is required');
          return ToolResult(await computer.activate(pid));
      }
      return ToolResult.error('unknown tool $name');
    } on PlatformException catch (e) {
      return _platformError(e);
    } on _ArgError catch (e) {
      return ToolResult.error(e.message);
    }
  }

  Future<ToolResult> _platformError(PlatformException e) async {
    if (e.code == 'no_accessibility' || e.code == 'no_screen') {
      if (!_askedPermissions) {
        _askedPermissions = true;
        try {
          await computer.requestPermissions();
        } on PlatformException {
          // The error below is what matters.
        }
      }
      return ToolResult.error('${e.message}. Ask the user to grant it in System Settings, then retry.');
    }
    return ToolResult.error(e.message ?? e.code);
  }

  // Reading.

  Future<ToolResult> _screen(Map<String, dynamic> args) async {
    final windowId = _int(args['window_id']);
    final shot = await computer.screenshot(windowId: windowId);
    _shot = shot;
    final what = windowId == null ? 'main display' : 'window $windowId';
    return ToolResult(
      'Screenshot of the $what, ${shot.width}×${shot.height} px. Pass x,y in these pixels to click/scroll.',
      png: shot.png,
    );
  }

  Future<ToolResult> _apps() async {
    final apps = await computer.apps();
    return ToolResult([
      for (final a in apps)
        '${a['name']} pid=${a['pid']} ${a['bundleId']}${a['active'] == true ? ' (active)' : ''}',
    ].join('\n'));
  }

  Future<ToolResult> _windows() async {
    final windows = await computer.windows();
    if (windows.isEmpty) return const ToolResult('no windows on screen');
    return ToolResult([
      for (final w in windows)
        'id=${w['id']} ${w['app']} pid=${w['pid']} "${w['title']}" (${w['x']},${w['y']} ${w['w']}×${w['h']})',
    ].join('\n'));
  }

  Future<ToolResult> _uiTree(Map<String, dynamic> args) async {
    final tree = await computer.tree(pid: _int(args['pid']));
    _tree = tree;
    final hint = tree.count < 5 ? '\n(few accessible elements: use screen and pixel clicks)' : '';
    return ToolResult('${tree.text}$hint');
  }

  // Actions.

  Future<ToolResult> _click(Map<String, dynamic> args) async {
    final index = _int(args['index']);
    final button = args['button'] == 'right' ? 'right' : 'left';
    final count = args['double'] == true ? 2 : 1;

    if (index != null) {
      if (_tree?.line(index) == null) {
        return ToolResult.error('Unknown element [$index]: call ui_tree first.');
      }
      final r = await computer.click(index: index, button: button, count: count);
      await Future<void>.delayed(settle);
      return ToolResult(r);
    }

    final p = _point(args);
    if (p == null) throw const _ArgError('Give index (from ui_tree) or x,y (pixels of the last screen image).');
    HitElement? hit;
    try {
      hit = await computer.elementAt(p.x, p.y);
    } on PlatformException {
      hit = null; // Best effort: only used to describe the target.
    }
    await computer.click(x: p.x, y: p.y, button: button, count: count);
    await Future<void>.delayed(settle);
    final on = hit == null ? '' : ' on ${hit.line} in ${hit.app}';
    return ToolResult('${count == 2 ? 'double-' : ''}${button == 'right' ? 'right-' : ''}clicked '
        'image (${p.px},${p.py})$on');
  }

  Future<ToolResult> _type(Map<String, dynamic> args) async {
    final text = args['text'];
    if (text is! String || text.isEmpty) throw const _ArgError('text is required');
    final index = _int(args['index']);
    if (index != null && _tree?.line(index) == null) {
      return ToolResult.error('Unknown element [$index]: call ui_tree first.');
    }
    String typed;
    try {
      typed = vault?.substitute(text) ?? text;
    } on VaultException catch (e) {
      return ToolResult.error('error: $e');
    }
    var r = await computer.type(typed, index: index);
    await Future<void>.delayed(settle);
    // Not even the length of a credential goes back.
    if (typed != text) r = r.replaceFirst(RegExp(r'typed \d+ characters'), 'typed the text with its vault values');
    return ToolResult(r);
  }

  Future<ToolResult> _key(Map<String, dynamic> args) async {
    final combo = (args['combo'] as String?)?.trim() ?? '';
    if (combo.isEmpty) throw const _ArgError('combo is required');
    final r = await computer.key(combo);
    await Future<void>.delayed(settle);
    return ToolResult(r);
  }

  Future<ToolResult> _scroll(Map<String, dynamic> args) async {
    final dx = _int(args['dx']) ?? 0;
    final dy = _int(args['dy']) ?? 0;
    if (dx == 0 && dy == 0) throw const _ArgError('Give dy and/or dx (lines).');
    final p = (args['x'] != null || args['y'] != null) ? _point(args) : null;
    final r = await computer.scroll(dx: dx, dy: dy, x: p?.x, y: p?.y);
    await Future<void>.delayed(settle);
    return ToolResult(p == null ? r : 'scrolled dx=$dx dy=$dy at image (${p.px},${p.py})');
  }

  Future<ToolResult> _open(Map<String, dynamic> args) async {
    final target = (args['target'] as String?)?.trim() ?? '';
    if (target.isEmpty) throw const _ArgError('target is required');
    return ToolResult(await computer.open(target));
  }

  // Helpers.

  /// x,y pixels of the last screenshot -> screen points. Throws [_ArgError] when unusable.
  ({double x, double y, num px, num py})? _point(Map<String, dynamic> args) {
    final px = args['x'], py = args['y'];
    if (px is! num || py is! num) return null;
    final shot = _shot;
    if (shot == null) throw const _ArgError('x,y are pixels of the last screen image: call screen first.');
    if (!shot.contains(px, py)) {
      throw _ArgError('x,y outside the last screen image (${shot.width}×${shot.height}).');
    }
    final p = shot.toScreen(px, py);
    return (x: p.x, y: p.y, px: px.round(), py: py.round());
  }

  static int? _int(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
}

class _ArgError implements Exception {
  const _ArgError(this.message);

  final String message;
}
