import 'package:flutter/foundation.dart';

import '../brain/claude_models.dart';
import '../l10n/l10n.dart';

/// Minerva's settings, as the status bar on the Mac and the settings screen on the phone change
/// them: the desktop [Assistant] applies them itself, the phone's [RemoteAssistant] sends them
/// to the desktop (see [RemoteProtocol]), which applies them and sends back what it now has. The
/// language is [languageSetting] on both.
abstract interface class AssistantSettings implements Listenable {
  /// The conversation's model (the main brain) and the workers'.
  ModelChoice get brainModel;
  ModelChoice get workerModel;

  /// The models of the installed Claude Code (null until it first reported them).
  ClaudeCatalog? get catalog;

  /// Why Claude Code says fast mode can't be used on this account, else null.
  String? get fastUnavailable;

  void setBrainModel(ModelChoice choice);
  void setWorkerModel(ModelChoice choice);

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
