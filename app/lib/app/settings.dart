import 'package:flutter/foundation.dart';

import '../brain/fallback.dart';
import '../brain/models.dart';
import '../l10n/l10n.dart';

/// Minerva's settings, as the status bar on the Mac and the settings screen on the phone change
/// them: the desktop [Assistant] applies them itself, the phone's [RemoteAssistant] sends them
/// to the desktop (see [RemoteProtocol]), which applies them and sends back what it now has. The
/// language is [languageSetting] on both.
abstract interface class AssistantSettings implements Listenable {
  /// The conversation's model (the main brain) and the workers'.
  ModelChoice get brainModel;
  ModelChoice get workerModel;

  /// The models of [provider]'s installed agent (null until it first reported them).
  ModelCatalog? catalogFor(BrainProvider provider);

  /// Providers whose agent is not installed or not signed in.
  Set<BrainProvider> get unavailableProviders;

  /// Why Claude Code says fast mode can't be used on this account, else null.
  String? get fastUnavailable;

  void setBrainModel(ModelChoice choice);
  void setWorkerModel(ModelChoice choice);

  /// Backups of the conversation's model and the workers', in order: when a provider hits its
  /// usage limit, Minerva goes on with the next one whose provider is not out, and back to the
  /// first once its limit is over (see lib/brain/fallback.dart).
  List<ModelChoice> get brainFallbacks;
  List<ModelChoice> get workerFallbacks;
  void setBrainFallbacks(List<ModelChoice> fallbacks);
  void setWorkerFallbacks(List<ModelChoice> fallbacks);

  /// What the conversation runs on now: [brainModel], or a backup while its provider is out.
  ModelChoice get activeBrainModel;

  /// Until when [provider] is out (usage limit, or signed out) and why; null when it can be used.
  ProviderOut? providerOut(BrainProvider provider);

  /// [code] one of [languageChoices], or null to follow the OS.
  Future<void> setLanguage(String? code);

  /// The Supertonic 3 speaker the replies are read with, 0 to [voiceCount] - 1.
  int get voice;
  void setVoice(int voice);
}

/// How many voices there are: 0–4 are female (F1–F5), 5–9 male (M1–M5).
const voiceCount = 10;

/// The voice Minerva speaks with until the user picks another.
const defaultVoice = 1;

/// [voice] if it is one, else null.
int? validVoice(int? voice) => voice != null && voice >= 0 && voice < voiceCount ? voice : null;

/// A voice by name, as the voice menus show it.
String voiceName(AppLocalizations l, int voice) => voice < 5 ? l.voiceFemale(voice + 1) : l.voiceMale(voice - 4);
