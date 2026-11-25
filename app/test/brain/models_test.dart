import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/brain/models.dart';
import 'package:minerva/store/store.dart';

const _all = ['low', 'medium', 'high', 'xhigh', 'max'];

Map<String, Object?> _m(String value, String resolved, String name,
        {List<String>? efforts = _all, bool? fast}) =>
    {
      'value': value,
      'resolvedModel': resolved,
      'displayName': name,
      'description': '',
      'supportsEffort': efforts == null ? null : true,
      'supportedEffortLevels': efforts,
      'supportsFastMode': fast,
    };

/// Claude Code 2.1.302's initialize answer (trimmed to the fields Minerva reads).
final _info = <String, dynamic>{
  'claude_code_version': '2.1.302',
  'fast_mode_state': 'off',
  'fast_mode_disabled_reason': 'sdk_opt_in_required',
  'models': [
    _m('default', 'claude-opus-5-5', 'Default (recommended)', fast: true),
    _m('opus', 'claude-opus-5-5', 'Opus 5.5', fast: true),
    _m('claude-fable-5-2', 'claude-fable-5-2', 'Fable 5.2'),
    _m('sonnet', 'claude-sonnet-5-5', 'Sonnet 5.5'),
    _m('haiku', 'claude-haiku-5-5', 'Haiku 5.5'),
    _m('fable', 'claude-fable-5-1', 'Fable 5.1'),
    _m('claude-haiku-4-5-20251001', 'claude-haiku-4-5-20251001', 'Haiku 4.5', efforts: null),
    _m('claude-sonnet-5', 'claude-sonnet-5', 'Sonnet 5'),
    _m('claude-opus-5', 'claude-opus-5', 'Opus 5', fast: true),
    _m('claude-fable-5', 'claude-fable-5', 'Fable 5'),
    _m('claude-opus-4-8', 'claude-opus-4-8', 'Opus 4.8', fast: true),
    _m('claude-opus-4-7', 'claude-opus-4-7', 'Opus 4.7'),
    _m('claude-opus-4-6', 'claude-opus-4-6', 'Opus 4.6', efforts: ['low', 'medium', 'high', 'max']),
    _m('claude-sonnet-4-6', 'claude-sonnet-4-6', 'Sonnet 4.6', efforts: ['low', 'medium', 'high', 'max']),
  ],
};

void main() {
  final catalog = ModelCatalog.fromInfo(_info);

  test('the newest model of each family comes first, aliases preferred', () {
    expect(catalog.version, '2.1.302');
    expect([for (final m in catalog.latest) m.value], ['opus', 'sonnet', 'haiku', 'claude-fable-5-2']);
  });

  test('the rest are previous models, newest first per family, without "default"', () {
    expect([for (final m in catalog.previous) m.value], [
      'claude-opus-5',
      'claude-opus-4-8',
      'claude-opus-4-7',
      'claude-opus-4-6',
      'claude-sonnet-5',
      'claude-sonnet-4-6',
      'claude-haiku-4-5-20251001',
      'fable',
      'claude-fable-5',
    ]);
    expect(catalog.find('default'), isNull);
    expect(catalog.all, hasLength(13));
  });

  test('effort fits the model', () {
    expect(effortFor(catalog.find('opus'), 'xhigh'), 'xhigh');
    expect(effortFor(catalog.find('claude-sonnet-4-6'), 'xhigh'), 'high');
    expect(effortFor(catalog.find('claude-haiku-4-5-20251001'), 'high'), isNull);
    expect(effortFor(null, 'medium'), 'medium');
  });

  test('a choice resolves to what the session runs with', () {
    const c = ModelChoice(model: 'sonnet', effort: 'max', fast: true);
    expect(c.resolve(catalog), (model: 'sonnet', effort: 'max', fast: false));
    expect(c.copyWith(model: 'opus').resolve(catalog), (model: 'opus', effort: 'max', fast: true));
    expect(c.resolve(null), (model: 'sonnet', effort: 'max', fast: true));
  });

  test('catalog and choices survive a restart', () {
    final dir = Directory.systemTemp.createTempSync('minerva_models');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.memory(dir.path);
    addTearDown(store.close);

    expect(ModelCatalog.load(store), isNull);
    catalog.save(store);
    final back = ModelCatalog.load(store)!;
    expect(back.version, catalog.version);
    expect([for (final m in back.all) m.value], [for (final m in catalog.all) m.value]);
    expect(back.find('claude-opus-4-6')!.efforts, ['low', 'medium', 'high', 'max']);
    expect(back.find('opus')!.fast, isTrue);

    const defaults = ModelChoice(model: 'opus', effort: 'low');
    final first = ModelChoice.load(store, 'brain', defaults);
    expect((first.model, first.effort, first.fast), ('opus', 'low', false));
    const ModelChoice(model: 'haiku', effort: 'high', fast: true).save(store, 'brain');
    final again = ModelChoice.load(store, 'brain', defaults);
    expect((again.model, again.effort, again.fast), ('haiku', 'high', true));
  });

  test('catalog and choices travel as JSON between the desktop and the phone', () {
    final back = ModelCatalog.fromJson(jsonDecode(jsonEncode(catalog.toJson())))!;
    expect([for (final m in back.all) m.value], [for (final m in catalog.all) m.value]);
    expect(back.find('opus')!.fast, isTrue);
    expect(ModelCatalog.fromJson(null), isNull);

    const c = ModelChoice(model: 'sonnet', effort: 'max', fast: true);
    expect(ModelChoice.fromJson(jsonDecode(jsonEncode(c.toJson()))), c);
    expect(ModelChoice.fromJson({'model': 'opus'}), isNull);
    // From an app without providers: Claude's.
    expect(ModelChoice.fromJson({'model': 'opus', 'effort': 'low'})!.provider, BrainProvider.claude);
  });

  // As `agy models` lists them: the thinking level is part of the id.
  final agy = ModelCatalog.antigravity(version: '1.5.16', models: [
    ('gemini-4-neon-low', 'Gemini 4 Neon (Low)'),
    ('gemini-4-neon-high', 'Gemini 4 Neon (High)'),
    ('gemini-4-neon-medium', 'Gemini 4 Neon (Medium)'),
    ('gemini-pro-orchestrator', 'Gemini Pro Orchestrator'),
    ('claude-opus-5-5-high', 'Claude Opus 5.5 (High)'),
    ('gpt-oss-120b-medium', 'GPT-OSS 120B (Medium)'),
  ]);

  test("Antigravity's models are listed once each, with their thinking levels", () {
    expect([for (final m in agy.all) m.value],
        ['gemini-4-neon', 'gemini-pro-orchestrator', 'claude-opus-5-5', 'gpt-oss-120b']);
    expect(agy.previous, isEmpty);
    expect(agy.find('gemini-4-neon')!.name, 'Gemini 4 Neon');
    expect(agy.find('gemini-4-neon')!.efforts, ['low', 'medium', 'high']);
    expect(agy.find('gemini-pro-orchestrator')!.efforts, isEmpty);
    expect(agy.provider, BrainProvider.antigravity);
  });

  test('an Antigravity choice resolves to the model id with its level', () {
    const c = ModelChoice(provider: BrainProvider.antigravity, model: 'gemini-4-neon', effort: 'max', fast: true);
    expect(c.resolve(agy), (model: 'gemini-4-neon-high', effort: null, fast: false));
    expect(c.copyWith(model: 'gemini-pro-orchestrator').resolve(agy),
        (model: 'gemini-pro-orchestrator', effort: null, fast: false));
    expect(c.copyWith(effort: 'low').resolve(null), (model: 'gemini-4-neon-low', effort: null, fast: false));
    expect(defaultModel(BrainProvider.antigravity, workers: false, catalog: agy).model, 'gemini-4-neon');
  });

  test('each provider keeps its catalog, and the choice its provider', () {
    final dir = Directory.systemTemp.createTempSync('minerva_models');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.memory(dir.path);
    addTearDown(store.close);

    catalog.save(store);
    agy.save(store);
    expect(ModelCatalog.load(store)!.find('opus'), isNotNull);
    final back = ModelCatalog.load(store, BrainProvider.antigravity)!;
    expect(back.provider, BrainProvider.antigravity);
    expect(back.find('gemini-4-neon')!.efforts, ['low', 'medium', 'high']);
    expect(ModelCatalog.fromJson(jsonDecode(jsonEncode(agy.toJson())))!.provider, BrainProvider.antigravity);

    const c = ModelChoice(provider: BrainProvider.antigravity, model: 'gemini-4-neon', effort: 'medium');
    c.save(store, 'workers');
    expect(ModelChoice.load(store, 'workers', defaultWorkerModel), c);
    expect(ModelChoice.fromJson(jsonDecode(jsonEncode(c.toJson()))), c);
    defaultWorkerModel.save(store, 'workers');
    expect(ModelChoice.load(store, 'workers', defaultWorkerModel), defaultWorkerModel);
  });

  test("Codex's catalog: its default first, hidden models out, efforts and fast mode as listed", () {
    Map<String, Object?> model(String id, {bool isDefault = false, bool hidden = false, bool priority = false}) => {
          'id': id,
          'model': id,
          'displayName': id.toUpperCase(),
          'description': 'about $id',
          'hidden': hidden,
          'isDefault': isDefault,
          'supportedReasoningEfforts': [
            for (final e in ['low', 'medium', 'high', 'ultra']) {'reasoningEffort': e, 'description': e},
          ],
          'serviceTiers': [if (priority) {'id': 'priority', 'name': 'Fast'}],
        };
    final codex = ModelCatalog.codex(version: '0.154.0', models: [
      model('gpt-5.5'),
      model('gpt-6-astra', isDefault: true, priority: true),
      model('codex-auto-review', hidden: true),
      'junk',
    ]);
    expect(codex.provider, BrainProvider.codex);
    expect([for (final m in codex.all) m.value], ['gpt-6-astra', 'gpt-5.5']);
    expect(codex.previous, isEmpty);
    final astra = codex.find('gpt-6-astra')!;
    expect((astra.name, astra.fast), ('GPT-6-ASTRA', true));
    expect(astra.efforts, ['low', 'medium', 'high', 'ultra']);
    expect(codex.find('gpt-5.5')!.fast, isFalse);

    expect(codexBrainModel.resolve(codex), (model: 'gpt-6-astra', effort: 'low', fast: false));
    expect(codexBrainModel.copyWith(effort: 'max', fast: true).resolve(codex),
        (model: 'gpt-6-astra', effort: 'high', fast: true));
    expect(codexBrainModel.copyWith(model: 'gpt-5.5', fast: true).resolve(codex),
        (model: 'gpt-5.5', effort: 'low', fast: false));
    expect(defaultModel(BrainProvider.codex, workers: true), codexWorkerModel);
    final other = ModelCatalog.codex(version: '1', models: [model('gpt-7')]);
    expect(defaultModel(BrainProvider.codex, workers: false, catalog: other).model, 'gpt-7');
    expect(ModelCatalog.fromJson(jsonDecode(jsonEncode(codex.toJson())))!.find('gpt-6-astra')!.fast, isTrue);
    expect(BrainProvider.parse('codex'), BrainProvider.codex);
  });
}
