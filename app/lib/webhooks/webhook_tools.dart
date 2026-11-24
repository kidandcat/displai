import '../mcp/display_mcp_server.dart';
import '../tools/tool_provider.dart';
import 'webhooks.dart';

/// The webhooks' brain tools: create one (a fresh secret URL for one sender), list and delete
/// (revoke) them. The registry stays on this Mac (see [Webhooks]).
class WebhookTools extends ToolProvider {
  WebhookTools(this.webhooks);

  final Webhooks webhooks;

  @override
  final List<McpTool> tools = const [_createTool, _listTool, _deleteTool];

  static const _createTool = McpTool(
    'webhook_create',
    'Create a new webhook for one sender (a service, a device, an automation): a fresh secret URL '
        'that only it uses. Use it whenever the user wants to add or connect a webhook; never hand '
        'out another webhook\'s URL. Returns the URL to set in the sender (any path after it works). '
        'Requests to it reach you as "[webhook <name>] …"; others are rejected before they reach you.',
    {
      'type': 'object',
      'properties': {
        'name': {'type': 'string', 'description': 'Slug for the sender, e.g. github or stripe-shop.'},
        'description': {
          'type': 'string',
          'description': 'Who sends to it and what to do with its requests; shown with each one.',
        },
      },
      'required': ['name'],
    },
  );

  static const _listTool = McpTool('webhook_list', 'Registered webhooks: name, description, created date and URL.', {
    'type': 'object',
    'properties': {},
  });

  static const _deleteTool = McpTool(
    'webhook_delete',
    'Delete (revoke) a webhook: its URL stops working at once and its requests are rejected.',
    {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
      },
      'required': ['name'],
    },
  );

  @override
  Future<ToolResult> call(String name, Map<String, dynamic> args) async {
    final n = '${args['name'] ?? ''}';
    try {
      switch (name) {
        case 'webhook_create':
          final h = await webhooks.create(n, description: '${args['description'] ?? ''}');
          return ToolResult(
            'created webhook ${h.name}: ${webhooks.urlOf(h)}\n'
            'Status: ${webhooks.status}. Requests to it arrive as "[webhook ${h.name}] …".',
          );
        case 'webhook_list':
          return ToolResult(describe(webhooks));
        case 'webhook_delete':
          return await webhooks.delete(n)
              ? ToolResult('deleted webhook ${Webhooks.normalizeName(n)}: its URL no longer works')
              : ToolResult.error('error: no webhook "$n"');
      }
    } on WebhookException catch (e) {
      return ToolResult.error('error: $e');
    }
    return ToolResult.error('error: unknown tool $name');
  }

  /// The webhooks for the brain, one per line.
  static String describe(Webhooks webhooks) {
    final items = webhooks.hooks;
    final status = 'Status: ${webhooks.status}.';
    if (items.isEmpty) return 'no webhooks\n$status';
    return [
      for (final h in items)
        '${h.name}${h.description.isEmpty ? '' : ' — ${h.description}'}'
            '${h.created == null ? '' : ' (created ${h.created!.toLocal().toIso8601String().substring(0, 10)})'}: '
            '${webhooks.urlOf(h) ?? 'URL unknown until webhooks start'}',
      status,
    ].join('\n');
  }
}
