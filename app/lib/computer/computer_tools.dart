import 'package:flutter/services.dart';

import '../mcp/display_mcp_server.dart';
import '../tools/tool_provider.dart';
import 'computer.dart';

/// Computer use: see the screen, read the accessibility tree, click, type, press keys, scroll,
/// open and activate apps.
///
/// Coordinates the model passes (x, y) are pixels of the LAST `screen` image; they are converted
/// to screen points here, so the model never deals with scale or origin. Elements from `ui_tree`
/// are targeted by index, which is more robust than pixels.
///
/// Reading, opening, activating, scrolling and ordinary clicks/typing run directly; clicks on
/// elements labelled send/buy/pay/delete/publish…, destructive key combos and anything the model
/// flags with `risky: true` are confirmed by the user first.
class ComputerTools extends ToolProvider {
  ComputerTools({Computer? computer, this.settle = const Duration(milliseconds: 300)})
      : computer = computer ?? Computer();

  final Computer computer;

  /// Wait after an action so the UI reacts before the model looks again.
  final Duration settle;

  Screenshot? _shot;
  AxTree? _tree;
  bool _askedPermissions = false;

  static const _risky = {
    'type': 'boolean',
    'description': 'true if this action sends, buys, pays, deletes or publishes something.',
  };
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
          'image. Dangerous clicks are confirmed by the user automatically; do not ask first.',
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
          'risky': _risky,
        },
      },
    ),
    McpTool(
      'type_text',
      'Type text at the keyboard focus, or into element index after focusing it. "\\n" presses '
          'Return.',
      {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
          'index': _index,
          'risky': _risky,
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
          'risky': _risky,
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
          'risky': _risky,
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
  Future<ToolResult> call(String name, Map<String, dynamic> args, ConfirmAction confirm) async {
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
          return await _click(args, confirm);
        case 'type_text':
          return await _type(args, confirm);
        case 'press_key':
          return await _key(args, confirm);
        case 'scroll':
          return await _scroll(args);
        case 'open':
          return await _open(args, confirm);
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

  Future<ToolResult> _click(Map<String, dynamic> args, ConfirmAction confirm) async {
    final index = _int(args['index']);
    final button = args['button'] == 'right' ? 'right' : 'left';
    final count = args['double'] == true ? 2 : 1;
    final verb = count == 2 ? 'Doble clic en' : (button == 'right' ? 'Clic derecho en' : 'Pulsar');

    if (index != null) {
      final tree = _tree;
      final line = tree?.line(index);
      if (tree == null || line == null) {
        return ToolResult.error('Unknown element [$index]: call ui_tree first.');
      }
      final label = AxTree.labelOf(line);
      if (_isRisky(args) || isRiskyTarget(line)) {
        final what = label != null && label.isNotEmpty ? '"$label"' : 'el elemento [$index]';
        if (!await confirm('$verb $what en ${tree.app}')) return declined;
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
    final label = AxTree.labelOf(hit?.line);
    if (_isRisky(args) || isRiskyTarget(hit?.line)) {
      final what = label != null && label.isNotEmpty ? '"$label"' : 'la posición (${p.px}, ${p.py})';
      final where = hit != null && hit.app.isNotEmpty ? ' en ${hit.app}' : '';
      if (!await confirm('$verb $what$where')) return declined;
    }
    await computer.click(x: p.x, y: p.y, button: button, count: count);
    await Future<void>.delayed(settle);
    final on = hit == null ? '' : ' on ${hit.line} in ${hit.app}';
    return ToolResult('${count == 2 ? 'double-' : ''}${button == 'right' ? 'right-' : ''}clicked '
        'image (${p.px},${p.py})$on');
  }

  Future<ToolResult> _type(Map<String, dynamic> args, ConfirmAction confirm) async {
    final text = args['text'];
    if (text is! String || text.isEmpty) throw const _ArgError('text is required');
    final index = _int(args['index']);
    if (index != null && _tree?.line(index) == null) {
      return ToolResult.error('Unknown element [$index]: call ui_tree first.');
    }
    if (_isRisky(args)) {
      final where = index != null ? ' en ${_tree!.app}' : '';
      if (!await confirm('Escribir "${_short(text)}"$where')) return declined;
    }
    final r = await computer.type(text, index: index);
    await Future<void>.delayed(settle);
    return ToolResult(r);
  }

  Future<ToolResult> _key(Map<String, dynamic> args, ConfirmAction confirm) async {
    final combo = (args['combo'] as String?)?.trim() ?? '';
    if (combo.isEmpty) throw const _ArgError('combo is required');
    if (_isRisky(args) || isDestructiveCombo(combo)) {
      if (!await confirm('Pulsar las teclas $combo')) return declined;
    }
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

  Future<ToolResult> _open(Map<String, dynamic> args, ConfirmAction confirm) async {
    final target = (args['target'] as String?)?.trim() ?? '';
    if (target.isEmpty) throw const _ArgError('target is required');
    if (_isRisky(args) && !await confirm('Abrir ${_short(target)}')) return declined;
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

  static bool _isRisky(Map<String, dynamic> args) => args['risky'] == true || args['risky'] == 'true';

  static String _short(String s) => s.length > 40 ? '${s.substring(0, 39)}…' : s;

  static final _riskyWords = RegExp(
    r'\b('
    // English.
    r'send|submit|buy|purchase|pay|checkout|check out|place (your )?order|order now|'
    r'confirm (order|purchase|payment)|delete|remove|erase|move to trash|empty trash|publish|post|'
    r'tweet|transfer|donate|subscribe|'
    // Spanish (accents stripped).
    r'enviar|envia|comprar|compra|pagar|paga|pedir|(realizar|tramitar|hacer|confirmar) (el )?pedido|'
    r'confirmar (la )?(compra|pago)|eliminar|elimina|borrar|borra|suprimir|mover a la papelera|'
    r'vaciar (la )?papelera|publicar|publica|transferir|transfiere|(hacer|realizar) (una )?transferencia|'
    r'donar|suscribir(se|me)?'
    r')\b',
  );

  /// Whether a UI label looks like an action that sends, buys, pays, deletes or publishes.
  static bool isRiskyLabel(String? label) {
    if (label == null || label.isEmpty) return false;
    return _riskyWords.hasMatch(_fold(label));
  }

  static const _textInputs = {'AXTextField', 'AXTextArea', 'AXSearchField', 'AXComboBox'};

  /// Whether clicking the element of a tree line (`AXButton "Send" (…)`) may be dangerous. Text
  /// inputs are never: their label is often a placeholder such as "Send a message".
  static bool isRiskyTarget(String? line) {
    if (_textInputs.contains(AxTree.roleOf(line))) return false;
    return isRiskyLabel(AxTree.labelOf(line));
  }

  static String _fold(String s) {
    const from = 'áàäâéèëêíìïîóòöôúùüû';
    const to = 'aaaaeeeeiiiioooouuuu';
    final lower = s.toLowerCase();
    final b = StringBuffer();
    for (final ch in lower.split('')) {
      final i = from.indexOf(ch);
      b.write(i < 0 ? ch : to[i]);
    }
    return b.toString();
  }

  /// cmd+delete style combos (move to trash, delete line/message…).
  static bool isDestructiveCombo(String combo) {
    final parts = combo.toLowerCase().split('+').map((p) => p.trim()).toList();
    final hasCmd = parts.any((p) => p == 'cmd' || p == 'command' || p == '⌘');
    final deletes = parts.any((p) => const {'delete', 'backspace', 'forwarddelete', 'del'}.contains(p));
    return hasCmd && deletes;
  }
}

class _ArgError implements Exception {
  const _ArgError(this.message);

  final String message;
}
