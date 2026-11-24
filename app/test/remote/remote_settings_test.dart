import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RemoteSettingsPage(assistant: a),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Ajustes'), findsOneWidget);
    expect(find.text('Opus 5.5 · Bajo'), findsOneWidget);
    expect(find.text('Masculina 2'), findsOneWidget);
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('ci'), 200, scrollable: list);
    expect(find.text('github'), findsOneWidget);

    // The model picker fits the phone too.
    await tester.scrollUntilVisible(find.text('Conversación'), -200, scrollable: list);
    await tester.tap(find.text('Conversación'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Sonnet 5.5'), findsWidgets);
    await tester.tap(find.text('Sonnet 5.5').last);
    await tester.pumpAndSettle();
    expect(a.brainModel.model, 'sonnet');

    await tester.pumpWidget(const SizedBox());
  });
}
