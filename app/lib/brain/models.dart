import 'dart:convert';

import '../store/store.dart';

/// The agent a brain runs on, each on the user's own subscription: Claude Code, Google
/// Antigravity's CLI (`agy`, signed in with their Google account) or OpenAI's Codex CLI (`codex`,
/// signed in with their ChatGPT account).
enum BrainProvider {
  claude('Claude', 'Claude Code'),
  antigravity('Antigravity', 'Antigravity CLI'),
  codex('Codex', 'Codex CLI');

  const BrainProvider(this.label, this.agent);

  /// The name the pickers show, and the agent's own name (next to its version).
  final String label;
  final String agent;

  /// From [name] (the store, or the settings sent between the desktop and the phone); Claude for
  /// anything else, so settings saved before there was a choice keep running on Claude.
  static BrainProvider parse(Object? id) =>
      values.firstWhere((p) => p.name == id, orElse: () => BrainProvider.claude);
}

/// One model a brain offers (from Claude Code's initialize answer, Antigravity's or Codex's model
/// list; see [ModelCatalog]).
class BrainModel {
  BrainModel({
    required this.value,
    required this.resolved,
    required this.name,
    this.description = '',
    this.efforts = const [],
    this.fast = false,
  });

  factory BrainModel.fromJson(Map<String, dynamic> j) => BrainModel(
        value: j['value'] as String,
        resolved: (j['resolvedModel'] as String?) ?? j['value'] as String,
        name: (j['displayName'] as String?) ?? j['value'] as String,
        description: (j['description'] as String?) ?? '',
        efforts: j['supportsEffort'] == true
            ? [for (final e in (j['supportedEffortLevels'] as List? ?? const [])) '$e']
            : const [],
        fast: j['supportsFastMode'] == true,
      );

  /// What `--model` takes: an alias (`opus`) or a full id (`claude-fable-5-2`). For Antigravity,
  /// the model without its thinking level (`gemini-4-neon`; see [ModelChoice.resolve]).
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

/// The models of a brain's installed agent, as it lists them. Claude Code's: the newest of each
/// family first (like Claude Code's own picker), the rest as previous models. Antigravity's and
/// Codex's: all of them, in their order. Never a hard-coded list, so it stays current as the
/// agents update.
class ModelCatalog {
  ModelCatalog({required this.version, required List<BrainModel> models, this.provider = BrainProvider.claude}) {
    final seen = <String>{};
    final all = [
      for (final m in models)
        if (m.value != 'default' && seen.add(m.value)) m,
    ];
    if (provider != BrainProvider.claude) {
      latest = all;
      previous = const [];
      return;
    }
    final newest = <String, BrainModel>{};
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
    int rank(BrainModel m) {
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
  factory ModelCatalog.fromInfo(Map<String, dynamic> info) => ModelCatalog(
        version: (info['claude_code_version'] as String?) ?? '',
        models: [
          for (final m in (info['models'] as List? ?? const []))
            if (m is Map && m['value'] is String) BrainModel.fromJson(m.cast<String, dynamic>()),
        ],
      );

  /// From Antigravity's model list (`agy models`, or an ACP session's `availableModels`): ids
  /// such as `gemini-4-neon-high` carry the thinking level, so each model is listed once with
  /// the levels it has.
  factory ModelCatalog.antigravity({required String version, required List<(String, String)> models}) {
    final order = <String>[];
    final names = <String, String>{};
    final efforts = <String, Set<String>>{};
    for (final (id, name) in models) {
      final m = _level.firstMatch(id);
      final base = m == null ? id : id.substring(0, m.start);
      if (!names.containsKey(base)) {
        order.add(base);
        names[base] = m == null ? name : name.replaceFirst(RegExp(r'\s*\([^)]*\)$'), '');
      }
      if (m != null) (efforts[base] ??= {}).add(m[1]!);
    }
    return ModelCatalog(
      version: version,
      provider: BrainProvider.antigravity,
      models: [
        for (final base in order)
          BrainModel(
            value: base,
            resolved: base,
            name: names[base]!,
            efforts: [for (final e in effortLevels) if (efforts[base]?.contains(e) ?? false) e],
          ),
      ],
    );
  }

  /// From Codex's model list (the app server's `model/list`): its default model first, the
  /// hidden ones left out. Each lists its reasoning efforts; fast mode is the `priority` service
  /// tier.
  factory ModelCatalog.codex({required String version, required List<Object?> models}) {
    final shown = [
      for (final m in models)
        if (m is Map && m['id'] is String && m['hidden'] != true) m,
    ];
    final listed = [...shown.where((m) => m['isDefault'] == true), ...shown.where((m) => m['isDefault'] != true)];
    return ModelCatalog(
      version: version,
      provider: BrainProvider.codex,
      models: [
        for (final m in listed)
          BrainModel(
            value: m['id'] as String,
            resolved: '${m['model'] ?? m['id']}',
            name: '${m['displayName'] ?? m['id']}',
            description: '${m['description'] ?? ''}',
            efforts: [
              for (final e in m['supportedReasoningEfforts'] as List? ?? const [])
                if (e is Map && e['reasoningEffort'] is String) e['reasoningEffort'] as String,
            ],
            fast: [
              for (final t in m['serviceTiers'] as List? ?? const [])
                if (t is Map) t['id'],
            ].contains('priority'),
          ),
      ],
    );
  }

  static final _level = RegExp(r'-(low|medium|high|xhigh|max)$');

  static const _families = ['opus', 'sonnet', 'haiku', 'fable'];

  final BrainProvider provider;

  /// The agent's version, e.g. `2.1.302`.
  final String version;
  late final List<BrainModel> latest;
  late final List<BrainModel> previous;

  List<BrainModel> get all => [...latest, ...previous];

  /// The model [value] names: by its value, else by the id it resolves to (`claude-opus-5-5`
  /// finds `opus`).
  BrainModel? find(String value) {
    for (final m in all) {
      if (m.value == value) return m;
    }
    for (final m in all) {
      if (m.resolved == value) return m;
    }
    return null;
  }

  static String _storeKey(BrainProvider p) => '${p.name}_catalog';

  /// The catalog the agent last reported, so the picker works before the next start.
  static ModelCatalog? load(Store store, [BrainProvider provider = BrainProvider.claude]) {
    final raw = store.get(_storeKey(provider));
    if (raw == null) return null;
    try {
      return fromJson(jsonDecode(raw), provider);
    } catch (_) {
      return null;
    }
  }

  void save(Store store) => store.set(_storeKey(provider), jsonEncode(toJson()));

  Map<String, Object?> toJson() =>
      {'provider': provider.name, 'version': version, 'models': [for (final m in all) m.toJson()]};

  /// From [toJson] (the store, or the desktop's settings sent to the phone); null if malformed.
  /// [provider] when the JSON does not say (catalogs saved before there was a choice).
  static ModelCatalog? fromJson(Object? j, [BrainProvider provider = BrainProvider.claude]) {
    if (j is! Map || j['models'] is! List) return null;
    return ModelCatalog(
      version: j['version'] as String? ?? '',
      provider: j['provider'] == null ? provider : BrainProvider.parse(j['provider']),
      models: [
        for (final m in j['models'] as List)
          if (m is Map && m['value'] is String) BrainModel.fromJson(m.cast<String, dynamic>()),
      ],
    );
  }
}

/// Effort levels from lowest to highest, as Claude Code names them (Antigravity's thinking
/// levels and Codex's reasoning efforts use the same names; Codex has `ultra` above `max`).
const effortLevels = ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'];

/// The effort to run [model] with when [wanted] is chosen: null when the model has no effort
/// levels, else [wanted] or the nearest level below it that the model supports.
String? effortFor(BrainModel? model, String wanted) {
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

/// The same on Antigravity: its default model (the one a new `agy` session starts with).
const antigravityBrainModel = ModelChoice(provider: BrainProvider.antigravity, model: 'gemini-4-neon', effort: 'low');
const antigravityWorkerModel =
    ModelChoice(provider: BrainProvider.antigravity, model: 'gemini-4-neon', effort: 'medium');

/// The same on Codex: the model its CLI starts with (the catalog lists its current default first).
const codexBrainModel = ModelChoice(provider: BrainProvider.codex, model: 'gpt-6-astra', effort: 'low');
const codexWorkerModel = ModelChoice(provider: BrainProvider.codex, model: 'gpt-6-astra', effort: 'medium');

/// The default choice on [provider], for the conversation or the [workers]; when [catalog] no
/// longer lists its model, the catalog's first one.
ModelChoice defaultModel(BrainProvider provider, {required bool workers, ModelCatalog? catalog}) {
  final d = switch (provider) {
    BrainProvider.claude => workers ? defaultWorkerModel : defaultBrainModel,
    BrainProvider.antigravity => workers ? antigravityWorkerModel : antigravityBrainModel,
    BrainProvider.codex => workers ? codexWorkerModel : codexBrainModel,
  };
  if (catalog == null || catalog.all.isEmpty || catalog.find(d.model) != null) return d;
  return d.copyWith(model: catalog.all.first.value);
}

/// The provider, model, effort and speed one kind of brain session runs with (the conversation,
/// or the workers), saved in the store under `<prefix>.provider`, `.model`, `.effort` and `.fast`.
class ModelChoice {
  const ModelChoice({
    this.provider = BrainProvider.claude,
    required this.model,
    required this.effort,
    this.fast = false,
  });

  final BrainProvider provider;
  final String model;
  final String effort;
  final bool fast;

  static ModelChoice load(Store store, String prefix, ModelChoice defaults) => ModelChoice(
        provider: BrainProvider.parse(store.get('$prefix.provider') ?? defaults.provider.name),
        model: store.get('$prefix.model') ?? defaults.model,
        effort: store.get('$prefix.effort') ?? defaults.effort,
        fast: store.get('$prefix.fast') == '1',
      );

  void save(Store store, String prefix) {
    store
      ..set('$prefix.provider', provider == BrainProvider.claude ? null : provider.name)
      ..set('$prefix.model', model)
      ..set('$prefix.effort', effort)
      ..set('$prefix.fast', fast ? '1' : null);
  }

  Map<String, Object?> toJson() => {'provider': provider.name, 'model': model, 'effort': effort, 'fast': fast};

  /// From [toJson] (a choice sent between the desktop and the phone); null if malformed. A choice
  /// without a provider (from an older app) is Claude's.
  static ModelChoice? fromJson(Object? j) {
    if (j is! Map || j['model'] is! String || j['effort'] is! String) return null;
    return ModelChoice(
      provider: BrainProvider.parse(j['provider']),
      model: j['model'] as String,
      effort: j['effort'] as String,
      fast: j['fast'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ModelChoice &&
      other.provider == provider &&
      other.model == model &&
      other.effort == effort &&
      other.fast == fast;

  @override
  int get hashCode => Object.hash(provider, model, effort, fast);

  ModelChoice copyWith({BrainProvider? provider, String? model, String? effort, bool? fast}) => ModelChoice(
        provider: provider ?? this.provider,
        model: model ?? this.model,
        effort: effort ?? this.effort,
        fast: fast ?? this.fast,
      );

  /// The session settings for this choice: the effort fitted to the model, fast mode only where
  /// the model has it. Antigravity's model ids carry the thinking level (`gemini-4-neon-low`),
  /// and it has no fast mode; Codex's fast mode is its `priority` service tier.
  ({String model, String? effort, bool fast}) resolve(ModelCatalog? catalog) {
    final m = catalog?.find(model);
    final e = effortFor(m, effort);
    return switch (provider) {
      BrainProvider.claude => (model: model, effort: e, fast: fast && (m?.fast ?? true)),
      BrainProvider.antigravity => (model: e == null ? model : '$model-$e', effort: null, fast: false),
      BrainProvider.codex => (model: model, effort: e, fast: fast && (m?.fast ?? false)),
    };
  }
}
