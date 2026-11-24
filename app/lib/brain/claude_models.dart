import 'dart:convert';

import '../store/store.dart';

/// One model Claude Code offers (from its initialize answer, see [ClaudeCatalog]).
class ClaudeModel {
  ClaudeModel({
    required this.value,
    required this.resolved,
    required this.name,
    this.description = '',
    this.efforts = const [],
    this.fast = false,
  });

  factory ClaudeModel.fromJson(Map<String, dynamic> j) => ClaudeModel(
        value: j['value'] as String,
        resolved: (j['resolvedModel'] as String?) ?? j['value'] as String,
        name: (j['displayName'] as String?) ?? j['value'] as String,
        description: (j['description'] as String?) ?? '',
        efforts: j['supportsEffort'] == true
            ? [for (final e in (j['supportedEffortLevels'] as List? ?? const [])) '$e']
            : const [],
        fast: j['supportsFastMode'] == true,
      );

  /// What `--model` takes: an alias (`opus`) or a full id (`claude-fable-5-2`).
  final String value;

  /// The model id [value] stands for today.
  final String resolved;
  final String name;
  final String description;

  /// Effort levels it supports, lowest first; empty when it has none.
  final List<String> efforts;

  /// Supports fast mode.
  final bool fast;

  Map<String, Object?> toJson() => {
        'value': value,
        'resolvedModel': resolved,
        'displayName': name,
        'description': description,
        'supportsEffort': efforts.isNotEmpty,
        'supportedEffortLevels': efforts,
        'supportsFastMode': fast,
      };

  static final _id = RegExp(r'^claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?$');

  /// Family (`opus`, `sonnet`…) and version of [resolved], or null for ids of another shape.
  (String, int)? get _parsed {
    final m = _id.firstMatch(resolved);
    if (m == null) return null;
    return (m[1]!, int.parse(m[2]!) * 100 + int.parse(m[3] ?? '0'));
  }

  String? get family => _parsed?.$1;
}

/// The models of the installed Claude Code, as it lists them: the newest of each family first
/// (like Claude Code's own picker), the rest as previous models. Never a hard-coded list, so it
/// stays current as Claude Code updates.
class ClaudeCatalog {
  ClaudeCatalog({required this.version, required List<ClaudeModel> models}) {
    final seen = <String>{};
    final all = [
      for (final m in models)
        if (m.value != 'default' && seen.add(m.value)) m,
    ];
    final newest = <String, ClaudeModel>{};
    for (final m in all) {
      final p = m._parsed;
      if (p == null) continue;
      final best = newest[p.$1];
      final bp = best?._parsed;
      // Same version: the alias (it follows new releases) wins over the full id.
      if (best == null || p.$2 > bp!.$2 || p.$2 == bp.$2 && !m.value.startsWith('claude-')) {
        newest[p.$1] = m;
      }
    }
    int rank(ClaudeModel m) {
      final i = _families.indexOf(m.family ?? '');
      return i < 0 ? _families.length : i;
    }

    latest = newest.values.toList()..sort((a, b) => rank(a).compareTo(rank(b)));
    previous = [
      for (final m in all)
        if (!latest.contains(m)) m,
    ]..sort((a, b) {
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : (b._parsed?.$2 ?? 0).compareTo(a._parsed?.$2 ?? 0);
      });
  }

  /// From Claude Code's initialize answer ([Described.info]).
  factory ClaudeCatalog.fromInfo(Map<String, dynamic> info) => ClaudeCatalog(
        version: (info['claude_code_version'] as String?) ?? '',
        models: [
          for (final m in (info['models'] as List? ?? const []))
            if (m is Map && m['value'] is String) ClaudeModel.fromJson(m.cast<String, dynamic>()),
        ],
      );

  static const _families = ['opus', 'sonnet', 'haiku', 'fable'];

  /// Claude Code version, e.g. `2.1.302`.
  final String version;
  late final List<ClaudeModel> latest;
  late final List<ClaudeModel> previous;

  List<ClaudeModel> get all => [...latest, ...previous];

  ClaudeModel? find(String value) {
    for (final m in all) {
      if (m.value == value) return m;
    }
    return null;
  }

  static const _storeKey = 'claude_catalog';

  /// The catalog the last Claude Code start reported, so the picker works before the next one.
  static ClaudeCatalog? load(Store store) {
    final raw = store.get(_storeKey);
    if (raw == null) return null;
    try {
      return fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  void save(Store store) => store.set(_storeKey, jsonEncode(toJson()));

  Map<String, Object?> toJson() => {'version': version, 'models': [for (final m in all) m.toJson()]};

  /// From [toJson] (the store, or the desktop's settings sent to the phone); null if malformed.
  static ClaudeCatalog? fromJson(Object? j) {
    if (j is! Map || j['models'] is! List) return null;
    return ClaudeCatalog(
      version: j['version'] as String? ?? '',
      models: [
        for (final m in j['models'] as List)
          if (m is Map && m['value'] is String) ClaudeModel.fromJson(m.cast<String, dynamic>()),
      ],
    );
  }
}

/// Effort levels from lowest to highest, as Claude Code names them.
const effortLevels = ['low', 'medium', 'high', 'xhigh', 'max'];

/// The effort to run [model] with when [wanted] is chosen: null when the model has no effort
/// levels, else [wanted] or the nearest level below it that the model supports.
String? effortFor(ClaudeModel? model, String wanted) {
  if (model == null) return wanted; // not in the catalog (yet): let Claude Code decide
  if (model.efforts.isEmpty) return null;
  if (model.efforts.contains(wanted)) return wanted;
  final w = effortLevels.indexOf(wanted);
  for (var i = w; i >= 0; i--) {
    if (model.efforts.contains(effortLevels[i])) return effortLevels[i];
  }
  return model.efforts.first;
}

/// What the conversation and the workers run on unless the user picks otherwise.
const defaultBrainModel = ModelChoice(model: 'opus', effort: 'low');
const defaultWorkerModel = ModelChoice(model: 'opus', effort: 'medium');

/// The model, effort and speed one kind of Claude session runs with (the conversation, or the
/// workers), saved in the store under `<prefix>.model`, `.effort` and `.fast`.
class ModelChoice {
  const ModelChoice({required this.model, required this.effort, this.fast = false});

  final String model;
  final String effort;
  final bool fast;

  static ModelChoice load(Store store, String prefix, ModelChoice defaults) => ModelChoice(
        model: store.get('$prefix.model') ?? defaults.model,
        effort: store.get('$prefix.effort') ?? defaults.effort,
        fast: store.get('$prefix.fast') == '1',
      );

  void save(Store store, String prefix) {
    store
      ..set('$prefix.model', model)
      ..set('$prefix.effort', effort)
      ..set('$prefix.fast', fast ? '1' : null);
  }

  Map<String, Object?> toJson() => {'model': model, 'effort': effort, 'fast': fast};

  /// From [toJson] (a choice sent between the desktop and the phone); null if malformed.
  static ModelChoice? fromJson(Object? j) {
    if (j is! Map || j['model'] is! String || j['effort'] is! String) return null;
    return ModelChoice(model: j['model'] as String, effort: j['effort'] as String, fast: j['fast'] == true);
  }

  @override
  bool operator ==(Object other) =>
      other is ModelChoice && other.model == model && other.effort == effort && other.fast == fast;

  @override
  int get hashCode => Object.hash(model, effort, fast);

  ModelChoice copyWith({String? model, String? effort, bool? fast}) =>
      ModelChoice(model: model ?? this.model, effort: effort ?? this.effort, fast: fast ?? this.fast);

  /// The session settings for this choice: the effort fitted to the model, fast mode only where
  /// the model has it.
  ({String model, String? effort, bool fast}) resolve(ClaudeCatalog? catalog) {
    final m = catalog?.find(model);
    return (model: model, effort: effortFor(m, effort), fast: fast && (m?.fast ?? true));
  }
}
