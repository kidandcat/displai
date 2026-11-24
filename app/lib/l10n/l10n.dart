/// The app's language: the one chosen in Minerva's settings ([languageSetting]), else the OS
/// language when the app has it (English or Spanish), else English.
///
/// Widgets use `AppLocalizations.of(context)`; code outside widgets (status lines the voice
/// speaks, errors, the brain's prompt) uses [strings], which resolves the same locale.
library;

import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;

import 'app_localizations.dart';

export 'app_localizations.dart';

/// The first of [preferred] (the OS languages, most preferred first) that the app supports, by
/// language code; English when none is.
Locale resolveLocale(Iterable<Locale>? preferred) {
  for (final l in preferred ?? const <Locale>[]) {
    for (final s in AppLocalizations.supportedLocales) {
      if (s.languageCode == l.languageCode) return s;
    }
  }
  return const Locale('en');
}

/// The OS languages, most preferred first (macOS: the preferred languages; Android: the locales).
List<Locale> get osLocales => debugOsLocales ?? systemLocales ?? PlatformDispatcher.instance.locales;

/// The user's languages for all apps, when the platform tells them apart from the app's own
/// (macOS, where the language setting is also the app's; see DesktopWindow).
List<Locale>? systemLocales;

/// Replaces [osLocales] in tests.
@visibleForTesting
List<Locale>? debugOsLocales;

/// Minerva's language setting: one of [languageChoices], or null to follow the OS.
final languageSetting = ValueNotifier<String?>(null);

/// The languages the setting offers: those the UI has.
List<String> get languageChoices => [for (final l in AppLocalizations.supportedLocales) l.languageCode];

/// [languageChoices] by their own names, as a language menu shows them.
const languageNames = {'en': 'English', 'es': 'Español'};

/// [code] if the setting accepts it, else null (follow the OS).
String? validLanguage(String? code) => languageChoices.contains(code) ? code : null;

/// The locale of the UI and of the status lines: the setting's, else from the OS languages.
Locale get appLocale {
  final chosen = languageSetting.value;
  return chosen != null ? Locale(chosen) : resolveLocale(osLocales);
}

/// The UI strings in [appLocale], for code that has no BuildContext.
AppLocalizations get strings => lookupAppLocalizations(appLocale);

/// The languages the Supertonic 3 voice speaks, by ISO 639-1 code (English names, for the brain).
const speechLanguages = {
  'ar': 'Arabic', 'bg': 'Bulgarian', 'cs': 'Czech', 'da': 'Danish', 'de': 'German',
  'el': 'Greek', 'en': 'English', 'es': 'Spanish', 'et': 'Estonian', 'fi': 'Finnish',
  'fr': 'French', 'hi': 'Hindi', 'hr': 'Croatian', 'hu': 'Hungarian', 'id': 'Indonesian',
  'it': 'Italian', 'ja': 'Japanese', 'ko': 'Korean', 'lt': 'Lithuanian', 'lv': 'Latvian',
  'nl': 'Dutch', 'pl': 'Polish', 'pt': 'Portuguese', 'ro': 'Romanian', 'ru': 'Russian',
  'sk': 'Slovak', 'sl': 'Slovenian', 'sv': 'Swedish', 'tr': 'Turkish', 'uk': 'Ukrainian',
  'vi': 'Vietnamese',
};

/// The language the voice speaks the brain's replies in: the OS language (the first of
/// [preferred]) when the voice has it, else English. It can be one the UI lacks (e.g. French).
String speechLanguageOf(Iterable<Locale>? preferred) {
  final first = preferred == null || preferred.isEmpty ? null : preferred.first.languageCode;
  return speechLanguages.containsKey(first) ? first! : 'en';
}

/// The language the voice speaks the brain's replies in: the setting's, else [speechLanguageOf]
/// the OS languages.
String get speechLanguage => languageSetting.value ?? speechLanguageOf(osLocales);
