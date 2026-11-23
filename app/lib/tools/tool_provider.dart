import '../mcp/display_mcp_server.dart';

/// A group of host tools served from DisplAI's own MCP server (commands, computer use, files).
///
/// Tools are DisplAI's, not the brain's, so any MCP-capable brain can use them.
abstract class ToolProvider {
  List<McpTool> get tools;

  bool handles(String name) => tools.any((t) => t.name == name);

  /// Runs [name] at once. Nothing asks the user for confirmation: the brain's prompt decides
  /// when a dangerous action is clear enough to do (design §3.5).
  Future<ToolResult> call(String name, Map<String, dynamic> args);
}
