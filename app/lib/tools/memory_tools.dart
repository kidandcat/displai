import '../mcp/display_mcp_server.dart';
import '../store/store.dart';
import 'tool_provider.dart';

/// Lasting memories (preferences, facts, decisions) in DisplAI's store. Essential memories are
/// put in the brain's system prompt at every start; the rest are found with search_memories.
class MemoryTools extends ToolProvider {
  MemoryTools(this.store, {this.readOnly = false});

  final Store store;

  /// Workers can read memories but not change them.
  final bool readOnly;

  /// Total size of essential memories kept in the system prompt.
  static const essentialBudget = 4000;

  static const _remember = McpTool(
    'remember',
    'Save a lasting memory about the user or their world (a preference, a fact, a decision), in one '
        'short self-contained sentence. Pass id to correct an existing memory instead of adding a '
        'duplicate. essential: true only for facts needed in almost every conversation (they go in '
        'your system prompt; keep them few).',
    {
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
        'essential': {'type': 'boolean'},
        'id': {'type': 'integer', 'description': 'Memory to replace.'},
      },
      'required': ['text'],
    },
  );

  static const _search = McpTool(
    'search_memories',
    'Search saved memories by words (any word matches, best first). Without query, lists the '
        'latest. Use it before asking the user something they may have told you before.',
    {
      'type': 'object',
      'properties': {
        'query': {'type': 'string'},
        'limit': {'type': 'integer'},
      },
    },
  );

  static const _forget = McpTool(
    'forget_memory',
    'Delete a saved memory by id (when the user asks, or it is wrong or outdated).',
    {
      'type': 'object',
      'properties': {
        'id': {'type': 'integer'},
      },
      'required': ['id'],
    },
  );

  @override
  List<McpTool> get tools => readOnly ? const [_search] : const [_remember, _search, _forget];

  @override
  Future<ToolResult> call(String name, Map<String, dynamic> args, ConfirmAction confirm) async {
    switch (name) {
      case 'remember':
        final text = (args['text'] as String? ?? '').trim();
        if (text.isEmpty) return const ToolResult.error('error: empty memory');
        final essential = args['essential'] as bool?;
        if (essential == true && _essentialSize() + text.length > essentialBudget) {
          return const ToolResult.error('error: the essential memories are full; save it as '
              'non-essential, or merge or forget an essential one first');
        }
        final id = (args['id'] as num?)?.toInt();
        if (id != null) {
          return store.updateMemory(id, text: text, essential: essential)
              ? ToolResult('updated memory $id')
              : ToolResult.error('error: no memory $id');
        }
        return ToolResult('saved memory ${store.addMemory(text, essential: essential ?? false)}');
      case 'search_memories':
        final rows = store.searchMemories(args['query'] as String? ?? '',
            limit: ((args['limit'] as num?)?.toInt() ?? 20).clamp(1, 100));
        if (rows.isEmpty) return const ToolResult('no memories found');
        return ToolResult(rows
            .map((r) => '[${r['id']}]${r['essential'] == 1 ? ' (essential)' : ''} ${r['text']}')
            .join('\n'));
      case 'forget_memory':
        final id = (args['id'] as num?)?.toInt();
        if (id == null) return const ToolResult.error('error: id is required');
        return store.deleteMemory(id) ? ToolResult('forgot memory $id') : ToolResult.error('error: no memory $id');
    }
    return ToolResult.error('error: unknown tool $name');
  }

  int _essentialSize() => store.essentialMemories().fold(0, (n, r) => n + (r['text'] as String).length);

  /// The essential memories as a system-prompt section (empty when there are none).
  static String promptSection(Store store) {
    final rows = store.essentialMemories();
    if (rows.isEmpty) return '';
    return 'Essential memories (saved by you earlier; id in brackets):\n'
        '${rows.map((r) => '- [${r['id']}] ${r['text']}').join('\n')}';
  }
}
