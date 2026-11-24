import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/brain/claude_models.dart';
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
  final catalog = ClaudeCatalog.fromInfo(_info);

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

    expect(ClaudeCatalog.load(store), isNull);
    catalog.save(store);
    final back = ClaudeCatalog.load(store)!;
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
}
