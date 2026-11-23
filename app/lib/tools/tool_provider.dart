import '../mcp/display_mcp_server.dart';

/// Asks the user to approve a risky action (shown on the display and asked by voice).
/// Resolves to true only on an explicit yes; a no, silence or a timeout is false.
typedef ConfirmAction = Future<bool> Function(String summary);

/// A group of host tools served from DisplAI's own MCP server (commands, computer use, files).
///
/// Tools are DisplAI's, not the brain's, so any MCP-capable brain can use them.
abstract class ToolProvider {
  List<McpTool> get tools;

  bool handles(String name) => tools.any((t) => t.name == name);

  /// Runs [name]. Risky actions must call [confirm] first and return a "declined" result when
  /// it resolves to false.
  Future<ToolResult> call(String name, Map<String, dynamic> args, ConfirmAction confirm);
}

/// Standard result for an action the user did not approve.
const declined = ToolResult('declined: the user did not approve this action. Do not retry it '
    'unless the user asks again.');
