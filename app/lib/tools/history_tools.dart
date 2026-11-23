import '../mcp/display_mcp_server.dart';
import '../store/store.dart';
import 'tool_provider.dart';

/// Search the whole conversation history, including what the brain's context already compacted.
class HistoryTools extends ToolProvider {
  HistoryTools(this.store);

  final Store store;

  @override
  final List<McpTool> tools = const [
    McpTool(
      'search_history',
      'Search every past conversation with the user (also what was compacted out of your context). '
          'query: words to find (any word matches, best first); without query, the latest messages. '
          'around: a message id to read the conversation around it.',
      {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
          'around': {'type': 'integer'},
          'limit': {'type': 'integer'},
        },
      },
    ),
  ];

  @override
  Future<ToolResult> call(String name, Map<String, dynamic> args) async {
    final around = (args['around'] as num?)?.toInt();
    final rows = around != null
        ? store.messagesAround(around)
        : store.searchMessages(args['query'] as String? ?? '',
            limit: ((args['limit'] as num?)?.toInt() ?? 10).clamp(1, 50));
    if (rows.isEmpty) return const ToolResult('nothing found');
    return ToolResult(rows.map((r) {
      final ts = DateTime.fromMillisecondsSinceEpoch(r['ts'] as int);
      return '#${r['id']} ${formatStamp(ts)} ${r['role']}: ${r['text']}';
    }).join('\n'));
  }
}

/// "2026-11-23 17:05 (Mon)" in local time.
String formatStamp(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)} (${days[t.weekday - 1]})';
}
