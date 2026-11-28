import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/app/settings.dart';
import 'package:minerva/brain/fallback.dart';
import 'package:minerva/brain/models.dart';
import 'package:minerva/l10n/l10n.dart';
import 'package:minerva/remote/remote_assistant.dart';
import 'package:minerva/remote/remote_settings.dart';

Map<String, dynamic> _model(String value, String name, {bool fast = false}) => {
      'value': value,
      'resolvedModel': value == 'opus' ? 'claude-opus-5-5' : 'claude-sonnet-5-5',
      'displayName': name,
      'description': '',
      'supportsEffort': true,
      'supportedEffortLevels': ['low', 'medium', 'high', 'xhigh', 'max'],
      'supportsFastMode': fast,
    };

/// A settings message as the desktop sends it.
Map<String, dynamic> _settings() => {
      't': 'settings',
      'brain': {'model': 'opus', 'effort': 'low', 'fast': false},
      'workers': {'model': 'sonnet', 'effort': 'high', 'fast': false},
      'catalog': {
        'version': '2.1.302',
        'models': [_model('opus', 'Opus 5.5', fast: true), _model('sonnet', 'Sonnet 5.5')],
      },
      'fast_unavailable': null,
      'language': 'es',
      'voice': 6,
      'vault': {
        'error': null,
        'credentials': [
          {'name': 'github', 'description': 'GitHub login', 'fields': ['username', 'password']},
        ],
      },
      'webhooks': {
        'on': true,
        'status': 'Activo',
        'hooks': [
          {'name': 'ci', 'description': 'Builds', 'url': 'https://abc.minerva.kidandcat.com/k/'},
        ],
      },
    };

void main() {
  tearDown(() => languageSetting.value = null);

  testWidgets('the phone shows the desktop settings on a narrow screen', (tester) async {
    tester.view.physicalSize = const Size(377, 702);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final a = RemoteAssistant(relay: 'wss://example.invalid', key: 'k' * 43);
    a
      ..handleMessage({'t': 'hello'})
      ..handleMessage(_settings());
    expect(languageSetting.value, 'es');
    expect(a.voice, 6);
    expect(a.workerModel.model, 'sonnet');
    expect(a.credentials.single.fields, ['username', 'password']);
    a.handleMessage({
      't': 'usage',
      'providers': [
        {
          'provider': 'claude',
          'read_at': 0,
          'windows': [
            {'kind': 'session', 'used': 40},
          ],
        },
      ],
    });
    expect(a.usage.shown.single.windows.single.leftAt(DateTime.now()), 60);

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RemoteSettingsPage(assistant: a),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Ajustes'), findsOneWidget);
    expect(find.text('Claude · Opus 5.5 · Bajo'), findsOneWidget);
    expect(find.text('Masculina 2'), findsOneWidget);
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('ci'), 200, scrollable: list);
    expect(find.text('github'), findsOneWidget);

    // The model picker fits the phone too.
    // Back to the top (under the app bar the tile would not take the tap).
    await tester.drag(list, const Offset(0, 2000));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conversación'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Sonnet 5.5'), findsWidgets);
    await tester.tap(find.text('Sonnet 5.5').last);
    await tester.pumpAndSettle();
    expect(a.brainModel.model, 'sonnet');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the phone shows and changes the wake word mode, and its orb turns blue with it', (tester) async {
    tester.view.physicalSize = const Size(377, 702);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final a = RemoteAssistant(relay: 'wss://example.invalid', key: 'k' * 43);
    a
      ..handleMessage({'t': 'hello'})
      ..handleMessage(_settings()
        ..['wake_mode'] = 'auto'
        ..['wake_timeout'] = 10
        ..['voice_id'] = 'enrolling'
        ..['voice_samples'] = 2);
    expect(a.wakeMode, WakeMode.auto);
    expect(a.wakeTimeout, 10);
    expect(a.voiceId, VoiceIdState.enrolling);
    a.handleMessage({'t': 'state', 'mode': 'listening', 'wake': true});
    expect(a.wakeActive, isTrue);
    expect(a.presence.wake, isTrue);
    a.handleMessage({'t': 'state', 'mode': 'listening'});
    expect(a.presence.wake, isFalse);

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RemoteSettingsPage(assistant: a),
    ));
    await tester.pumpAndSettle();
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('Aprendiendo tu voz (2/5)'), 100, scrollable: list);
    expect(find.text('Por voz'), findsOneWidget);
    expect(find.text('10 min'), findsOneWidget);
    await tester.tap(find.text('Por voz'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Siempre').last);
    await tester.pumpAndSettle();
    expect(a.wakeMode, WakeMode.on);
    // Not automatic: no timeout nor voice profile.
    expect(find.text('10 min'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("the phone switches the provider, with each provider's models", (tester) async {
    tester.view.physicalSize = const Size(377, 702);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final a = RemoteAssistant(relay: 'wss://example.invalid', key: 'k' * 43);
    final settings = _settings()
      ..['catalogs'] = {
        'claude': _settings()['catalog'],
        'antigravity': {
          'provider': 'antigravity',
          'version': '1.5.16',
          'models': [
            {
              'value': 'gemini-4-neon',
              'displayName': 'Gemini 4 Neon',
              'supportsEffort': true,
              'supportedEffortLevels': ['low', 'medium', 'high'],
            },
            {'value': 'gemini-pro-orchestrator', 'displayName': 'Gemini Pro Orchestrator'},
          ],
        },
      }
      ..['unavailable'] = <String>[];
    a
      ..handleMessage({'t': 'hello'})
      ..handleMessage(settings);
    expect(a.catalogFor(BrainProvider.antigravity)!.find('gemini-4-neon')!.efforts, ['low', 'medium', 'high']);

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RemoteSettingsPage(assistant: a),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conversación'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Antigravity'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(a.brainModel.provider, BrainProvider.antigravity);
    expect(a.brainModel.model, 'gemini-4-neon');
    expect(find.text('Gemini Pro Orchestrator'), findsOneWidget);
    expect(find.text('1.5.16 (Antigravity CLI)'), findsOneWidget);
    await tester.tap(find.text('Gemini Pro Orchestrator'));
    await tester.pumpAndSettle();
    expect(a.brainModel.model, 'gemini-pro-orchestrator');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the phone shows each provider, and orders the backups', (tester) async {
    tester.view.physicalSize = const Size(377, 702);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final a = RemoteAssistant(relay: 'wss://example.invalid', key: 'k' * 43);
    final until = DateTime.now().add(const Duration(hours: 1));
    final settings = _settings()
      ..['catalogs'] = {
        'claude': _settings()['catalog'],
        'codex': {
          'provider': 'codex',
          'version': '0.154.0',
          'models': [
            {
              'value': 'gpt-6-astra',
              'displayName': 'GPT-6 Astra',
              'supportsEffort': true,
              'supportedEffortLevels': ['low', 'medium', 'high', 'ultra'],
              'supportsFastMode': true,
            },
          ],
        },
      }
      ..['unavailable'] = ['antigravity']
      ..['brain_fallbacks'] = [codexBrainModel.toJson()]
      ..['active_brain'] = codexBrainModel.toJson()
      ..['limits'] = {
        'claude': {'until': until.millisecondsSinceEpoch, 'reason': 'usage'},
      };
    a
      ..handleMessage({'t': 'hello'})
      ..handleMessage(settings);
    expect(a.brainFallbacks, [codexBrainModel]);
    expect(a.activeBrainModel, codexBrainModel);
    expect(a.providerOut(BrainProvider.claude)?.reason, LimitReason.usage);
    expect(a.providerOut(BrainProvider.codex), isNull);

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RemoteSettingsPage(assistant: a),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conversación'));
    await tester.pumpAndSettle();
    expect(find.text('Claude no está disponible: la conversación sigue con GPT-6 Astra hasta que vuelva.'),
        findsOneWidget);

    await tester.tap(find.text('Respaldos, por orden (1)'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('GPT-6 Astra'), findsOneWidget);
    // Antigravity is not installed: no other provider to add.
    await tester.ensureVisible(find.byTooltip('Quitar'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Quitar'));
    await tester.pumpAndSettle();
    expect(a.brainFallbacks, isEmpty);
    await tester.ensureVisible(find.text('Añadir respaldo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Añadir respaldo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Codex').last);
    await tester.pumpAndSettle();
    expect(a.brainFallbacks, [codexBrainModel]);

    await tester.tap(find.text('Proveedores'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Límite de uso hasta las'), findsOneWidget);
    expect(find.text('Listo · En uso: Conversación'), findsOneWidget);
    expect(find.text('No instalado o sin sesión iniciada'), findsOneWidget);
    expect(find.text('Codex CLI 0.154.0'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
