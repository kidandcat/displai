import 'dart:io';

import '../mcp/display_mcp_server.dart';
import '../tools/tool_provider.dart';
import 'telegram.dart';

/// The Telegram channel's brain tool: send the user files and photos in their chat with the bot
/// (the same chat their written messages come from).
class TelegramTools extends ToolProvider {
  TelegramTools(this.telegram, {String? home}) : home = home ?? Platform.environment['HOME'] ?? '/';

  final Telegram telegram;
  final String home;

  @override
  final List<McpTool> tools = const [_sendFileTool];

  static const _sendFileTool = McpTool(
    'telegram_send_file',
    'Send the user a file or photo on Telegram (their chat with Minerva\'s bot). Images (jpg, png, '
        'webp, heic) go as photos, anything else (or images over 10 MB) as documents; at most 50 MB '
        'each. Several paths are sent as albums of up to 10.',
    {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'The file (absolute or relative to home).'},
        'more_paths': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'More files, sent together with path as an album.',
        },
        'caption': {'type': 'string', 'description': 'Text shown under the file (plain text).'},
        'as': {
          'type': 'string',
          'enum': ['photo', 'document'],
          'description': 'photo (compressed, shown inline) or document (the original file). Default: by type.',
        },
      },
      'required': ['path'],
    },
  );

  String _path(String p) {
    if (p.startsWith('~/')) return '$home/${p.substring(2)}';
    return p.startsWith('/') ? p : '$home/$p';
  }

  @override
  Future<ToolResult> call(String name, Map<String, dynamic> args) async {
    if (name != _sendFileTool.name) return ToolResult.error('error: unknown tool $name');
    final paths = [
      '${args['path'] ?? ''}'.trim(),
      if (args['more_paths'] is List) for (final p in args['more_paths'] as List) '$p'.trim(),
    ].where((p) => p.isNotEmpty).map(_path).toList();
    if (paths.isEmpty) return const ToolResult.error('error: path is required');
    final as = args['as'] as String?;
    if (as != null && as != 'photo' && as != 'document') {
      return const ToolResult.error('error: as must be "photo" or "document"');
    }
    try {
      final sent = await telegram.sendFiles(paths, caption: args['caption'] as String?, as: as);
      return ToolResult('sent to the user on Telegram: ${sent.join('; ')}');
    } on TelegramException catch (e) {
      return ToolResult.error('error: not sent: ${e.message}');
    }
  }
}
