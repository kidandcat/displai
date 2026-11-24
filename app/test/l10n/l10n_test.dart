import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/brain/system_prompt.dart';
import 'package:minerva/display/theme.dart';
import 'package:minerva/l10n/l10n.dart';

void main() {
  group('resolveLocale', () {
    test('picks the first OS language the app has', () {
      expect(resolveLocale(const [Locale('es', 'ES')]), const Locale('es'));
      expect(resolveLocale(const [Locale('en', 'GB'), Locale('es')]), const Locale('en'));
      expect(resolveLocale(const [Locale('fr', 'FR'), Locale('es', 'MX')]), const Locale('es'));
    });

    test('falls back to English', () {
      expect(resolveLocale(const [Locale('fr', 'FR'), Locale('de')]), const Locale('en'));
      expect(resolveLocale(const []), const Locale('en'));
      expect(resolveLocale(null), const Locale('en'));
    });
  });

  test('the voice speaks the OS language when it can, else English', () {
    expect(speechLanguageOf(const [Locale('es', 'ES')]), 'es');
    expect(speechLanguageOf(const [Locale('fr', 'FR'), Locale('es')]), 'fr');
    expect(speechLanguageOf(const [Locale('zh', 'CN')]), 'en');
    expect(speechLanguageOf(const []), 'en');
  });

  test('the brain is told the language and the reminder phrase', () {
    final es = languagePromptSection('es', lookupAppLocalizations(const Locale('es')));
    expect(es, contains('system language is Spanish. Reply in Spanish'));
    expect(es, contains('"Te recuerdo"'));
    final en = languagePromptSection('en', lookupAppLocalizations(const Locale('en')));
    expect(en, contains('system language is English'));
    expect(en, contains('"Just a reminder"'));
    expect(systemPrompt, isNot(contains('Spanish')));
  });

  test('strings outside widgets follow the OS language', () {
    addTearDown(() => debugOsLocales = null);
    debugOsLocales = const [Locale('es', 'ES')];
    expect(strings.activityThinking, 'Pensando…');
    expect(DisplayStrings.submit, 'Enviar');
    expect(strings.vaultFormTitle('github'), 'Credencial: github');
    debugOsLocales = const [Locale('ja', 'JP')];
    expect(strings.activityThinking, 'Thinking…');
    expect(speechLanguage, 'ja');
  });

  testWidgets('the UI is in the OS language, English by default', (tester) async {
    Widget app() => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          localeListResolutionCallback: (locales, _) => resolveLocale(locales),
          home: Builder(builder: (context) => Text(AppLocalizations.of(context).backgroundJobs(2))),
        );
    tester.platformDispatcher.localesTestValue = const [Locale('pt', 'BR')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(app());
    expect(find.text('2 background jobs'), findsOneWidget);

    tester.platformDispatcher.localesTestValue = const [Locale('es', 'ES')];
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('2 trabajos en segundo plano'), findsOneWidget);
  });
}
