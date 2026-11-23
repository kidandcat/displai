import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show GlobalKey;

import '../display/display.dart';
import '../presence/presence.dart';

/// What the main screen needs from an assistant: the desktop [Assistant] that does all the
/// processing, or the phone's [RemoteAssistant] that only shows and plays what it is sent.
abstract interface class AssistantUi implements Listenable {
  DisplayController get display;
  PresenceSignal get presence;

  /// Wraps what DisplAI shows, for snapshots.
  GlobalKey get screenKey;

  bool get ready;
  String? get error;
  bool get muted;

  /// What the brain is doing right now ("Buscando en la web…"), or empty.
  String get activity;

  /// Last thing the user said.
  String get lastHeard;

  /// Background workers running.
  int get backgroundJobs;

  /// A short note about the desktop–phone link for the status bar, or empty.
  String get linkNote;

  void toggleMute();
}
