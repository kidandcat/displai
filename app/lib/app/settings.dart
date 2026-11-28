import 'package:flutter/foundation.dart';

import '../brain/fallback.dart';
import '../brain/models.dart';
import '../l10n/l10n.dart';
import '../voice/voice_profile.dart';

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

  /// Wake word mode: Minerva only takes what is said to her starting with "Minerva" (voice from
  /// the Mac or the phone; not Telegram or the display), always, never, or for [wakeTimeout]
  /// minutes after a voice that is not the owner's ([WakeMode.auto]).
  WakeMode get wakeMode;
  void setWakeMode(WakeMode mode);
  int get wakeTimeout;
  void setWakeTimeout(int minutes);

  /// Wake word mode is on now (set so, or switched on by another voice): the orb is blue.
  bool get wakeActive;

  /// How the owner's voice profile stands, and how many utterances it has learned from.
  VoiceIdState get voiceId;
  int get voiceSamples;

  /// Forgets the owner's voice: the next utterances enroll it again.
  void resetVoiceProfile();
}

enum WakeMode { off, on, auto }

/// The owner's voice profile: not in use (wake word mode isn't automatic), loading the model,
/// enrolling, ready, or unavailable (the model failed: automatic mode then does nothing).
enum VoiceIdState { off, loading, enrolling, ready, failed }

/// Minutes automatic wake word mode stays on after the last voice that is not the owner's.
const wakeTimeouts = [1, 2, 5, 10, 15, 30];
const defaultWakeTimeout = 5;

/// [mode]'s name in the menus.
String wakeModeName(AppLocalizations l, WakeMode mode) => switch (mode) {
      WakeMode.off => l.wakeModeOff,
      WakeMode.on => l.wakeModeOn,
      WakeMode.auto => l.wakeModeAuto,
    };

/// The voice profile's state for the settings, or null when there is nothing to say.
String? voiceIdNote(AppLocalizations l, VoiceIdState state, int samples) => switch (state) {
      VoiceIdState.off => null,
      VoiceIdState.loading => l.voiceIdLoading,
      VoiceIdState.enrolling => l.voiceIdEnrolling(samples, VoiceProfile.enrollSamples),
      VoiceIdState.ready => l.voiceIdReady,
      VoiceIdState.failed => l.voiceIdFailed,
    };

/// How many voices there are: 0–4 are female (F1–F5), 5–9 male (M1–M5).
const voiceCount = 10;

/// The voice Minerva speaks with until the user picks another.
const defaultVoice = 1;

/// [voice] if it is one, else null.
int? validVoice(int? voice) => voice != null && voice >= 0 && voice < voiceCount ? voice : null;

/// A voice by name, as the voice menus show it.
String voiceName(AppLocalizations l, int voice) => voice < 5 ? l.voiceFemale(voice + 1) : l.voiceMale(voice - 4);
