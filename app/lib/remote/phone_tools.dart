import 'dart:convert';

import '../mcp/display_mcp_server.dart';
import '../tools/tool_provider.dart';
import '../vault/vault.dart';
import 'phone_host.dart';

/// The brain's hands on the phone: the same as the Mac's computer tools, run on the connected
/// phone over the link (lib/remote/phone_control.dart there, with its accessibility service).
///
/// They only work while a phone is connected: otherwise they say so at once. x,y are pixels of
/// the last phone_screen image, and phone_ui_tree's bounds are in the same pixels.
class PhoneTools extends ToolProvider {
  PhoneTools({required this.phone, this.vault, this.settle = const Duration(milliseconds: 500)});

  /// The paired phone, if any.
  final PhoneHost? Function() phone;

  /// Fills `{{vault:name.field}}` placeholders in phone_type (design §3.9).
  final Vault? vault;

  /// Wait after an action so the phone's UI reacts before the brain looks again.
  final Duration settle;

  static const _actions = {'phone_click', 'phone_type', 'phone_key', 'phone_scroll', 'phone_swipe', 'phone_open'};

  static const _index = {'type': 'integer', 'description': 'Element [n] from the last phone_ui_tree.'};
  static const _px = {'type': 'number', 'description': 'Pixel of the phone_screen image (phone_ui_tree uses the same).'};

  @override
  final List<McpTool> tools = const [
    McpTool(
      'phone_ui_tree',
      'Phone only (while the user is on the phone): the UI of the app in front on the phone, lines '
          '`[n] Role "label" = "value" flags (x,y w×h)`. Target elements by index n in phone_click/'
          'phone_type/phone_scroll. all: every window on screen (keyboard, system bars, dialogs).',
      {
        'type': 'object',
        'properties': {
          'all': {'type': 'boolean'},
        },
      },
    ),
    McpTool(
      'phone_click',
      'Phone only: tap element index (preferred), or pixel x,y of the phone_screen image. long: '
          'long-press.',
      {
        'type': 'object',
        'properties': {
          'index': _index,
          'x': _px,
          'y': _px,
          'long': {'type': 'boolean'},
        },
      },
    ),
    McpTool(
      'phone_type',
      'Phone only: put text in element index, or in the focused field. It replaces the field\'s '
          'text unless append. A final "\\n" presses the keyboard\'s enter/search/send. '
          '{{vault:name.field}} placeholders are filled in.',
      {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
          'index': _index,
          'append': {'type': 'boolean'},
        },
        'required': ['text'],
      },
    ),
    McpTool(
      'phone_key',
      'Phone only: press back, home, recents, notifications, quick_settings, power, lock or enter.',
      {
        'type': 'object',
        'properties': {
          'key': {
            'type': 'string',
            'enum': ['back', 'home', 'recents', 'notifications', 'quick_settings', 'power', 'lock', 'enter'],
          },
        },
        'required': ['key'],
      },
    ),
    McpTool(
      'phone_scroll',
      'Phone only: scroll element index (or the list around it), or swipe the screen (around x,y). '
          'direction: the way to go, down shows what is below.',
      {
        'type': 'object',
        'properties': {
          'direction': {
            'type': 'string',
            'enum': ['up', 'down', 'left', 'right'],
          },
          'index': _index,
          'x': _px,
          'y': _px,
        },
        'required': ['direction'],
      },
    ),
    McpTool(
      'phone_swipe',
      'Phone only: swipe from x1,y1 to x2,y2 (pixels of the phone_screen image) in ms (default 300).',
      {
        'type': 'object',
        'properties': {
          'x1': _px,
          'y1': _px,
          'x2': _px,
          'y2': _px,
          'ms': {'type': 'integer'},
        },
        'required': ['x1', 'y1', 'x2', 'y2'],
      },
    ),
    McpTool(
      'phone_screen',
      'Phone only: screenshot of the phone. x,y you pass to the phone tools are pixels of it.',
      {'type': 'object', 'properties': {}},
    ),
    McpTool(
      'phone_open',
      'Phone only: open an app (name or package), a URL or URI (https:, tel:, mailto:, geo:, '
          'intent:...), or an intent (action such as VIEW, SEND or DIAL, data, package, extras).',
      {
        'type': 'object',
        'properties': {
          'target': {'type': 'string'},
          'action': {'type': 'string'},
          'data': {'type': 'string'},
          'package': {'type': 'string'},
          'extras': {'type': 'object'},
        },
      },
    ),
    McpTool(
      'phone_apps',
      'Phone only: the app in front, the recently used ones, and the installed apps (name, package).',
      {'type': 'object', 'properties': {}},
    ),
  ];

  @override
  Future<ToolResult> call(String name, Map<String, dynamic> args) async {
    final p = phone();
    if (p == null || !p.active) {
      return const ToolResult.error('error: no phone is connected. The phone tools work only while the user '
          'talks through the phone app ([phone WxH] in their message); use the Mac\'s tools.');
    }
    if (p.control == null) {
      return const ToolResult.error('error: the phone app is too old for phone control: the user needs '
          'the new Minerva APK on the phone.');
    }
    var sent = args;
    var secret = false;
    if (name == 'phone_type') {
      final text = args['text'];
      if (text is! String || text.isEmpty) return const ToolResult.error('error: text is required');
      try {
        final typed = vault?.substitute(text) ?? text;
        secret = typed != text;
        sent = {...args, 'text': typed};
      } on VaultException catch (e) {
        return ToolResult.error('error: $e');
      }
    }
    // A screenshot may wait for the user to allow screen capture on the phone (before Android 11).
    final m = await p.call(name, sent,
        timeout: name == 'phone_screen' ? const Duration(seconds: 75) : const Duration(seconds: 20));
    if (m == null) return const ToolResult.error('error: the phone did not answer (it may have disconnected).');
    var text = '${m['text'] ?? ''}';
    // Not even the length of a credential goes back.
    if (secret) text = text.replaceFirst(RegExp(r'typed \d+ characters'), 'typed the text with its vault values');
    if (m['error'] == true) return ToolResult.error(text);
    if (_actions.contains(name)) await Future<void>.delayed(settle);
    final png = m['png'];
    return ToolResult(text, png: png is String ? base64Decode(png) : null);
  }
}
