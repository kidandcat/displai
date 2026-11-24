import '../mcp/display_mcp_server.dart';
import '../tools/tool_provider.dart';
import 'vault.dart';
import 'vault_strings.dart';

/// The vault's brain tools: list and delete saved credentials. [requestTool] (ask the user for
/// one on the display) is run by the assistant, because it shows a form; [requestForm] builds it.
///
/// No tool ever returns a value.
class VaultTools extends ToolProvider {
  VaultTools(this.vault, {bool readOnly = false})
      : tools = [_listTool, if (!readOnly) _deleteTool];

  final Vault vault;

  @override
  final List<McpTool> tools;

  static const _listTool = McpTool(
    'vault_list',
    'Saved credentials (logins, tokens, keys): names, descriptions and field names, never values. '
        'Write {{vault:name.field}} where a value goes in run_command, write_file or type_text; '
        'Minerva fills it in and scrubs it from results.',
    {'type': 'object', 'properties': {}},
  );

  static const _deleteTool = McpTool(
    'vault_delete',
    'Delete a saved credential.',
    {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
      },
      'required': ['name'],
    },
  );

  static const requestTool = McpTool(
    'vault_request',
    'Ask the user for a credential with a form on the display; it goes straight into Minerva\'s '
        'encrypted vault and you never see the values. Returns at once; then you get "[display] '
        'saved credential <name>" or "[display] credential request <name> cancelled". Asking again '
        'for an existing name updates the fields given.',
    {
      'type': 'object',
      'properties': {
        'name': {'type': 'string', 'description': 'Slug, e.g. github.'},
        'description': {'type': 'string', 'description': 'What it is for, shown to the user.'},
        'fields': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'name': {'type': 'string', 'description': 'e.g. username, password, token.'},
              'label': {'type': 'string'},
              'secret': {'type': 'boolean', 'description': 'Hidden while typed and scrubbed from results.'},
            },
            'required': ['name'],
          },
        },
      },
      'required': ['name', 'description', 'fields'],
    },
  );

  /// The `form` display call for a [requestTool] call, or an error text.
  static Object requestForm(Map<String, dynamic> args) {
    final name = Vault.normalizeName('${args['name'] ?? ''}');
    if (!Vault.validName(name)) return 'error: name must be a slug like github (a-z, 0-9, - and _)';
    final description = '${args['description'] ?? ''}'.trim();
    final raw = args['fields'];
    if (raw is! List || raw.isEmpty) return 'error: fields are required';
    final fields = <Map<String, Object?>>[];
    for (final f in raw) {
      if (f is! Map) return 'error: each field is {name, label, secret}';
      final fname = '${f['name'] ?? ''}'.trim();
      if (!Vault.validFieldName(fname)) return 'error: invalid field name "$fname" (a-z, 0-9, - and _)';
      fields.add({
        'name': fname,
        'label': '${f['label'] ?? fname}',
        'type': f['secret'] == false ? 'text' : 'secret',
        'required': true,
      });
    }
    return <String, dynamic>{
      'title': VaultStrings.formTitle(name),
      'id': 'vault-$name',
      'intro': [if (description.isNotEmpty) description, VaultStrings.formNote].join('\n\n'),
      'submit': VaultStrings.save,
      'cancel': VaultStrings.cancel,
      'vault': name,
      'vaultDescription': description,
      'fields': fields,
    };
  }

  @override
  Future<ToolResult> call(String name, Map<String, dynamic> args) async {
    if (vault.loadError != null) return ToolResult.error('error: ${vault.loadError}');
    switch (name) {
      case 'vault_list':
        return ToolResult(describe(vault));
      case 'vault_delete':
        final n = '${args['name'] ?? ''}';
        try {
          return await vault.delete(n)
              ? ToolResult('deleted credential ${Vault.normalizeName(n)}')
              : ToolResult.error('error: no credential "$n"');
        } on VaultException catch (e) {
          return ToolResult.error('error: $e');
        }
    }
    return ToolResult.error('error: unknown tool $name');
  }

  /// The credentials for the brain: names, descriptions and field names only.
  static String describe(Vault vault) {
    final items = vault.credentials;
    if (items.isEmpty) return 'no saved credentials';
    return [
      for (final c in items)
        '${c.name}${c.description.isEmpty ? '' : ' — ${c.description}'}: '
            '${c.fields.map((f) => '{{vault:${c.name}.${f.name}}}${f.secret ? '' : ' (not secret)'}').join(', ')}',
    ].join('\n');
  }
}
