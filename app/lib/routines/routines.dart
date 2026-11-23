import 'dart:async';
import 'dart:convert';

import '../mcp/display_mcp_server.dart';
import '../store/store.dart';
import '../tools/history_tools.dart' show formatStamp;
import '../tools/tool_provider.dart';

/// Routines and reminders: a prompt that Minerva hands to the brain at a set time ("recuérdame
/// a las cinco…", "cada mañana a las ocho…"). They run while the app is open; a one-time
/// reminder missed while it was closed fires late at the next start.
class Routines extends ToolProvider {
  Routines({required this.store, required this.notify, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final Store store;

  /// Hands the routine's prompt to the main brain (queued until it is free).
  final void Function(String text) notify;
  final DateTime Function() _clock;
  Timer? _timer;

  /// Recurring runs missed by more than this (app closed) are skipped, not run late.
  static const lateLimit = Duration(hours: 2);

  static const _scheduleSchema = {
    'type': 'object',
    'description': 'One of: {"type":"once","at":"2026-11-24T08:30"} (local time); '
        '{"type":"daily","time":"08:30","days":[1,2,3,4,5]} (days 1=Monday … 7=Sunday, omit for '
        'every day); {"type":"interval","minutes":60}.',
    'properties': {
      'type': {
        'type': 'string',
        'enum': ['once', 'daily', 'interval'],
      },
      'at': {'type': 'string'},
      'time': {'type': 'string'},
      'days': {
        'type': 'array',
        'items': {'type': 'integer'},
      },
      'minutes': {'type': 'integer'},
    },
    'required': ['type'],
  };

  @override
  final List<McpTool> tools = const [
    McpTool(
      'create_routine',
      'Create a reminder or a routine: at the scheduled time you receive a "[routine" message with '
          'the prompt and act on it (say a reminder aloud, check something, start a worker...). '
          'Write the prompt as an instruction to yourself, with everything needed.',
      {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': 'A few words, in Spanish, for the user.'},
          'prompt': {'type': 'string'},
          'schedule': _scheduleSchema,
        },
        'required': ['name', 'prompt', 'schedule'],
      },
    ),
    McpTool(
      'list_routines',
      'List routines and reminders with their schedule and next run.',
      {'type': 'object', 'properties': {}},
    ),
    McpTool(
      'update_routine',
      'Change a routine: name, prompt, schedule, or enabled (false pauses it).',
      {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
          'name': {'type': 'string'},
          'prompt': {'type': 'string'},
          'schedule': _scheduleSchema,
          'enabled': {'type': 'boolean'},
        },
        'required': ['id'],
      },
    ),
    McpTool(
      'delete_routine',
      'Delete a routine or reminder.',
      {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
        },
        'required': ['id'],
      },
    ),
  ];

  void start() {
    tick();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => tick());
  }

  void dispose() => _timer?.cancel();

  @override
  Future<ToolResult> call(String name, Map<String, dynamic> args) async {
    final id = (args['id'] as num?)?.toInt();
    switch (name) {
      case 'create_routine':
        final routineName = (args['name'] as String? ?? '').trim();
        final prompt = (args['prompt'] as String? ?? '').trim();
        if (routineName.isEmpty || prompt.isEmpty) {
          return const ToolResult.error('error: name and prompt are required');
        }
        final schedule = _schedule(args['schedule']);
        if (schedule is String) return ToolResult.error('error: $schedule');
        final next = nextRun(schedule as Map<String, dynamic>, _clock());
        if (next == null) return const ToolResult.error('error: that time is already past');
        store.db.execute(
          'INSERT INTO routines(name, prompt, schedule, next_run, created) VALUES (?, ?, ?, ?, ?)',
          [routineName, prompt, jsonEncode(schedule), next.millisecondsSinceEpoch, Store.now()],
        );
        return ToolResult('created routine ${store.db.lastInsertRowId}; next run ${formatStamp(next)}');
      case 'list_routines':
        return ToolResult(_list());
      case 'update_routine':
        if (id == null) return const ToolResult.error('error: id is required');
        return _update(id, args);
      case 'delete_routine':
        if (id == null) return const ToolResult.error('error: id is required');
        store.db.execute('DELETE FROM routines WHERE id = ?', [id]);
        return store.db.updatedRows > 0
            ? ToolResult('deleted routine $id')
            : ToolResult.error('error: no routine $id');
    }
    return ToolResult.error('error: unknown tool $name');
  }

  ToolResult _update(int id, Map<String, dynamic> args) {
    final rows = store.db.select('SELECT * FROM routines WHERE id = ?', [id]);
    if (rows.isEmpty) return ToolResult.error('error: no routine $id');
    final r = rows.first;
    var schedule = jsonDecode(r['schedule'] as String) as Map<String, dynamic>;
    if (args['schedule'] != null) {
      final s = _schedule(args['schedule']);
      if (s is String) return ToolResult.error('error: $s');
      schedule = s as Map<String, dynamic>;
    }
    final enabled = (args['enabled'] as bool?) ?? r['enabled'] == 1;
    final next = enabled ? nextRun(schedule, _clock()) : null;
    if (enabled && next == null) return const ToolResult.error('error: that time is already past');
    store.db.execute(
      'UPDATE routines SET name = ?, prompt = ?, schedule = ?, enabled = ?, next_run = ? WHERE id = ?',
      [
        (args['name'] as String?)?.trim() ?? r['name'],
        (args['prompt'] as String?)?.trim() ?? r['prompt'],
        jsonEncode(schedule),
        enabled ? 1 : 0,
        next?.millisecondsSinceEpoch,
        id,
      ],
    );
    return ToolResult('updated routine $id${next == null ? ' (paused)' : '; next run ${formatStamp(next)}'}');
  }

  String _list() {
    final rows = store.db.select('SELECT * FROM routines ORDER BY enabled DESC, next_run');
    if (rows.isEmpty) return 'no routines';
    return rows.map((r) {
      final next = r['next_run'] as int?;
      return '${r['id']} «${r['name']}» ${describe(jsonDecode(r['schedule'] as String) as Map<String, dynamic>)}'
          '${r['enabled'] == 1 && next != null ? ', next ${formatStamp(DateTime.fromMillisecondsSinceEpoch(next))}' : ', paused'}'
          '\n  prompt: ${r['prompt']}';
    }).join('\n');
  }

  /// Fires every due routine and schedules its next run.
  void tick() {
    final now = _clock();
    final due = store.db.select(
      'SELECT * FROM routines WHERE enabled = 1 AND next_run IS NOT NULL AND next_run <= ? ORDER BY next_run',
      [now.millisecondsSinceEpoch],
    );
    for (final r in due) {
      final id = r['id'] as int;
      final schedule = jsonDecode(r['schedule'] as String) as Map<String, dynamic>;
      final dueAt = DateTime.fromMillisecondsSinceEpoch(r['next_run'] as int);
      final once = schedule['type'] == 'once';
      final late = now.difference(dueAt);
      final next = once ? null : nextRun(schedule, now);
      store.db.execute('UPDATE routines SET next_run = ?, enabled = ?, last_run = ? WHERE id = ?',
          [next?.millisecondsSinceEpoch, once ? 0 : 1, now.millisecondsSinceEpoch, id]);
      if (!once && late > lateLimit) continue; // missed while the app was closed
      notify('[routine $id «${r['name']}», due ${formatStamp(dueAt)}'
          '${late > const Duration(minutes: 2) ? ', running late because Minerva was closed' : ''}]\n'
          '${r['prompt']}');
    }
  }

  /// Validates a schedule; returns the normalised map, or an error message.
  static Object _schedule(Object? raw) {
    if (raw is! Map) return 'schedule is required';
    final s = Map<String, dynamic>.from(raw);
    switch (s['type']) {
      case 'once':
        final at = DateTime.tryParse('${s['at']}');
        if (at == null) return 'once needs "at" like 2026-11-24T08:30';
        return {'type': 'once', 'at': at.toIso8601String()};
      case 'daily':
        final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch('${s['time']}');
        if (m == null || int.parse(m.group(1)!) > 23 || int.parse(m.group(2)!) > 59) {
          return 'daily needs "time" like 08:30';
        }
        final days = (s['days'] as List?)?.map((d) => (d as num).toInt()).where((d) => d >= 1 && d <= 7).toSet().toList()
          ?..sort();
        return {
          'type': 'daily',
          'time': '${m.group(1)!.padLeft(2, '0')}:${m.group(2)}',
          if (days != null && days.isNotEmpty && days.length < 7) 'days': days,
        };
      case 'interval':
        final minutes = (s['minutes'] as num?)?.toInt();
        if (minutes == null || minutes < 1) return 'interval needs "minutes" ≥ 1';
        return {'type': 'interval', 'minutes': minutes};
    }
    return 'schedule type must be once, daily or interval';
  }

  /// The first run strictly after [from], or null when there is none.
  static DateTime? nextRun(Map<String, dynamic> s, DateTime from) {
    switch (s['type']) {
      case 'once':
        final at = DateTime.parse(s['at'] as String);
        return at.isAfter(from) ? at : null;
      case 'daily':
        final parts = (s['time'] as String).split(':').map(int.parse).toList();
        final days = (s['days'] as List?)?.cast<int>();
        for (var i = 0; i <= 7; i++) {
          final d = DateTime(from.year, from.month, from.day + i, parts[0], parts[1]);
          if (!d.isAfter(from)) continue;
          if (days == null || days.contains(d.weekday)) return d;
        }
        return null;
      case 'interval':
        return from.add(Duration(minutes: s['minutes'] as int));
    }
    return null;
  }

  static String describe(Map<String, dynamic> s) => switch (s['type']) {
        'once' => 'once at ${formatStamp(DateTime.parse(s['at'] as String))}',
        'daily' => 'daily at ${s['time']}${s['days'] == null ? '' : ' on days ${(s['days'] as List).join(',')}'}',
        'interval' => 'every ${s['minutes']} min',
        _ => '?',
      };
}
