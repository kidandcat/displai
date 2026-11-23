import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:mcp_dart/mcp_dart.dart';

/// A tool exposed to the brain over MCP.
class McpTool {
  const McpTool(this.name, this.description, this.inputSchema);

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
}

/// What a tool returns: text, optionally a PNG image (screenshots), and an error flag.
class ToolResult {
  const ToolResult(this.text, {this.png, this.isError = false});

  const ToolResult.error(this.text)
      : png = null,
        isError = true;

  final String text;
  final Uint8List? png;
  final bool isError;
}

typedef ToolHandler = FutureOr<ToolResult> Function(String name, Map<String, dynamic> args);

/// The app's embedded MCP server (streamable HTTP on 127.0.0.1, random port and secret path).
///
/// Every capability the brain gets (display, commands, computer use, files) is served from here,
/// so any MCP-capable brain (Claude Code today, others later) can use the same tools.
class DisplayMcpServer {
  DisplayMcpServer({required this.tools, required this.handler, this.onCall});

  final List<McpTool> tools;
  final ToolHandler handler;

  /// Notified when a tool call arrives (for timing and the thinking strip).
  final void Function(String name)? onCall;

  StreamableMcpServer? _server;
  final String _secret = List.generate(16, (_) => Random.secure().nextInt(16).toRadixString(16)).join();

  String get url => 'http://127.0.0.1:${_server!.boundPort}/mcp/$_secret';

  Future<void> start() async {
    final server = StreamableMcpServer(
      serverFactory: (_) => _build(),
      host: '127.0.0.1',
      port: 0,
      path: '/mcp/$_secret',
      allowedHosts: const {'localhost', '127.0.0.1'},
    );
    await server.start();
    _server = server;
  }

  Future<void> stop() async => _server?.stop();

  McpServer _build() {
    final server = McpServer(
      const Implementation(name: 'minerva', version: '0.1.0'),
      options: const McpServerOptions(protocol: McpProtocol.stable),
    );
    for (final t in tools) {
      server.registerTool(
        t.name,
        description: t.description,
        // Round-trip through JSON: nested const maps are not Map<String, dynamic>.
        inputSchema: JsonObject.fromJson(jsonDecode(jsonEncode(t.inputSchema)) as Map<String, dynamic>),
        callback: (args, extra) async {
          onCall?.call(t.name);
          ToolResult r;
          try {
            r = await handler(t.name, Map<String, dynamic>.from(args));
          } catch (e) {
            r = ToolResult.error('error: $e');
          }
          final png = r.png;
          return CallToolResult(
            content: [
              TextContent(text: r.text),
              if (png != null) ImageContent(data: base64Encode(png), mimeType: 'image/png'),
            ],
            isError: r.isError,
          );
        },
      );
    }
    return server;
  }
}
