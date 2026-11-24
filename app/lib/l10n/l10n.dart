/// The app's language: the OS language when the app has it (English or Spanish), else English.
///
/// Widgets use `AppLocalizations.of(context)`; code outside widgets (status lines the voice
/// speaks, errors, the brain's prompt) uses [strings], which resolves the same locale.
library;

import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart' show visibleForTesting;

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
List<Locale> get osLocales => debugOsLocales ?? PlatformDispatcher.instance.locales;

/// Replaces [osLocales] in tests.
@visibleForTesting
List<Locale>? debugOsLocales;

/// The locale of the UI and of the status lines, from the OS languages.
Locale get appLocale => resolveLocale(osLocales);

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

/// [speechLanguageOf] the OS languages.
String get speechLanguage => speechLanguageOf(osLocales);
