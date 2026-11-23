import 'dart:io';

import '../mcp/display_mcp_server.dart';
import 'tool_provider.dart';

/// Reusable procedures the brain writes for itself and loads when it needs them.
///
/// Each skill is `<dir>/<name>/SKILL.md`: a front matter with name and description, then the steps.
/// Only the index (name: description) goes in the system prompt.
class SkillTools extends ToolProvider {
  SkillTools(this.dir, {this.readOnly = false});

  final String dir;
  final bool readOnly;

  static const _read = McpTool(
    'read_skill',
    'Load a saved skill (a reusable procedure) by name before doing that kind of task.',
    {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
      },
      'required': ['name'],
    },
  );

  static const _save = McpTool(
    'save_skill',
    'Create or replace a skill: a reusable procedure for a kind of task (generic steps, no one-off '
        'details or secrets). Save one when the user asks, or after working out a procedure worth '
        'repeating.',
    {
      'type': 'object',
      'properties': {
        'name': {'type': 'string', 'description': 'Short kebab-case name.'},
        'description': {'type': 'string', 'description': 'One sentence: what it does and when to use it.'},
        'body': {'type': 'string', 'description': 'The procedure, in markdown.'},
      },
      'required': ['name', 'description', 'body'],
    },
  );

  static const _delete = McpTool(
    'delete_skill',
    'Delete a saved skill by name (confirmed by the user automatically).',
    {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
      },
      'required': ['name'],
    },
  );

  @override
  List<McpTool> get tools => readOnly ? const [_read] : const [_read, _save, _delete];

  static String slug(String name) => name
      .toLowerCase()
      .trim()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  File _file(String name) => File('$dir/${slug(name)}/SKILL.md');

  @override
  Future<ToolResult> call(String name, Map<String, dynamic> args, ConfirmAction confirm) async {
    final skill = (args['name'] as String? ?? '').trim();
    if (slug(skill).isEmpty) return const ToolResult.error('error: name is required');
    final f = _file(skill);
    switch (name) {
      case 'read_skill':
        if (!f.existsSync()) {
          return ToolResult.error('error: no skill "$skill". Saved skills: '
              '${list(dir).map((s) => s.name).join(', ')}');
        }
        return ToolResult(await f.readAsString());
      case 'save_skill':
        final description = (args['description'] as String? ?? '').replaceAll('\n', ' ').trim();
        final body = (args['body'] as String? ?? '').trim();
        if (description.isEmpty || body.isEmpty) {
          return const ToolResult.error('error: description and body are required');
        }
        final existed = f.existsSync();
        await f.parent.create(recursive: true);
        await f.writeAsString('---\nname: ${slug(skill)}\ndescription: $description\n---\n\n$body\n');
        return ToolResult('${existed ? 'replaced' : 'saved'} skill ${slug(skill)}');
      case 'delete_skill':
        if (!f.existsSync()) return ToolResult.error('error: no skill "$skill"');
        if (!await confirm('Borrar la skill «${slug(skill)}»')) return declined;
        await f.parent.delete(recursive: true);
        return ToolResult('deleted skill ${slug(skill)}');
    }
    return ToolResult.error('error: unknown tool $name');
  }

  /// Saved skills, sorted by name.
  static List<({String name, String description})> list(String dir) {
    final d = Directory(dir);
    if (!d.existsSync()) return const [];
    final out = <({String name, String description})>[];
    for (final e in d.listSync().whereType<Directory>()) {
      final f = File('${e.path}/SKILL.md');
      if (!f.existsSync()) continue;
      final text = f.readAsStringSync();
      final desc = RegExp(r'^description:\s*(.+)$', multiLine: true).firstMatch(text)?.group(1)?.trim() ?? '';
      out.add((name: e.uri.pathSegments.where((s) => s.isNotEmpty).last, description: desc));
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  /// The skills index as a system-prompt section (empty when there are none).
  static String promptSection(String dir) {
    final skills = list(dir);
    if (skills.isEmpty) return '';
    return 'Saved skills (load one with read_skill before that kind of task):\n'
        '${skills.map((s) => '- ${s.name}: ${s.description}').join('\n')}';
  }
}
