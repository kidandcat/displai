import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../display/display_controller.dart' show VaultSubmission;
import '../display/display_runner.dart';
import 'protocol.dart';
import 'remote_link.dart';

/// The desktop's side of the phone remote ("Mac callado"): while a phone is connected, the
/// phone is the mic, the speaker and the display, and the desktop only does the processing.
///
/// The [Assistant] sets the callbacks, routes the voice and the display calls here while
/// [active], and keeps feeding [record] so the display can move to whichever side is in use.
class PhoneHost extends ChangeNotifier {
  PhoneHost({required String relay, required String key, required this.playRate, required this.log})
      : link = RemoteLink(relay: relay, key: key, role: 'host') {
    link.addListener(notifyListeners);
    _subs
      ..add(link.messages.listen(_onMessage))
      ..add(link.audio.listen((a) {
        if (active && a.$1 == RemoteProtocol.kindMic) onMic?.call(a.$2);
      }));
    link.start();
  }

  final RemoteLink link;

  /// Sample rate of the voice frames sent to the phone.
  final int playRate;

  /// What built the desktop's display; replayed on the phone when it joins.
  final DisplayLog log;

  final _subs = <StreamSubscription<Object?>>[];

  /// A phone is connected and has said hello: route voice and display to it.
  bool active = false;

  /// The phone's display, in logical pixels.
  double width = 0, height = 0;
  String platform = '';

  void Function(Float32List samples)? onMic;
  void Function(String text)? onEvent;
  void Function(bool on)? onMute;

  /// A credential the user typed in a vault form on the phone (for the vault, not the brain).
  void Function(VaultSubmission submission)? onVault;

  /// The user changed settings on the phone (any of the keys of [pushSettings]).
  void Function(Map<String, dynamic> settings)? onSettings;

  /// The user deleted a credential on the phone.
  void Function(String name)? onVaultDelete;

  /// The phone finished playing everything it was sent.
  void Function()? onIdle;
  void Function()? onJoin;
  void Function()? onLeave;

  // Voice.
  int _sent = 0;
  bool playing = false;

  // Display calls waiting for the phone's result.
  int _nextId = 0;
  final _pending = <int, Completer<Map<String, dynamic>?>>{};

  String _lastState = '';
  String _lastSettings = '';
  Timer? _partialTimer;
  (String, String)? _partial;

  void _onMessage(Map<String, dynamic> m) {
    switch (m['t']) {
      case 'peer':
        if (m['up'] == true) {
          _sent = 0;
          playing = false;
          link.send({'t': 'hello', 'rate': playRate});
        } else if (active) {
          _leave();
        }
      case 'hello':
        width = (m['w'] as num?)?.toDouble() ?? 0;
        height = (m['h'] as num?)?.toDouble() ?? 0;
        platform = '${m['platform'] ?? ''}';
        if (!active) {
          active = true;
          _lastState = '';
          _lastSettings = '';
          link.send({'t': 'reset'});
          log.replay((name, args) => link.send({'t': 'tool', 'name': name, 'args': args}));
          debugPrint('phone joined (${width.round()}×${height.round()} $platform)');
          onJoin?.call();
        }
        notifyListeners();
      case 'result':
        _pending.remove(m['id'])?.complete(m);
      case 'idle':
        final n = (m['n'] as num?)?.toInt() ?? 0;
        if (playing && n >= _sent) {
          playing = false;
          onIdle?.call();
        }
      case 'event':
        final text = m['text'];
        if (active && text is String && text.isNotEmpty) onEvent?.call(text);
      case 'mute':
        if (active) onMute?.call(m['on'] == true);
      case 'vault':
        final submission = VaultSubmission.fromJson(m);
        if (active && submission != null) onVault?.call(submission);
      case 'set':
        if (active) onSettings?.call(m);
      case 'vault_delete':
        final name = m['name'];
        if (active && name is String && name.isNotEmpty) onVaultDelete?.call(name);
    }
  }

  void _leave() {
    active = false;
    playing = false;
    for (final c in _pending.values) {
      c.complete(null);
    }
    _pending.clear();
    debugPrint('phone left');
    onLeave?.call();
    notifyListeners();
  }

  // ---------------------------------------------------------------- voice

  void sendVoice(Float32List samples) {
    if (!active || samples.isEmpty) return;
    _sent++;
    playing = true;
    link.sendAudio(RemoteProtocol.kindVoice, samples);
  }

  void stopVoice() {
    playing = false;
    if (active) link.send({'t': 'stop'});
  }

  // ---------------------------------------------------------------- display

  /// Runs a display tool on the phone; null when it did not answer in time or left.
  Future<Map<String, dynamic>?> call(String name, Map<String, dynamic> args,
      {Duration timeout = const Duration(seconds: 10)}) {
    if (!active) return Future.value(null);
    final id = ++_nextId;
    final c = Completer<Map<String, dynamic>?>();
    _pending[id] = c;
    link.send({'t': 'tool', 'id': id, 'name': name, 'args': args});
    return c.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      return null;
    });
  }

  /// Streams partial tool input to the phone (throttled: it is the whole JSON every time).
  void partial(String name, String json) {
    if (!active) return;
    _partial = (name, json);
    _partialTimer ??= Timer(const Duration(milliseconds: 120), _flushPartial);
  }

  void _flushPartial() {
    _partialTimer = null;
    final p = _partial;
    _partial = null;
    if (p != null && active) link.send({'t': 'partial', 'name': p.$1, 'json': p.$2});
  }

  void cancelPartial() {
    _partialTimer?.cancel();
    _partialTimer = null;
    _partial = null;
    if (active) link.send({'t': 'cancel_partial'});
  }

  // ---------------------------------------------------------------- state

  /// Sends the assistant's state to the phone when it changed.
  void pushState(Map<String, Object?> state) {
    if (!active) return;
    final json = jsonEncode({'t': 'state', ...state});
    if (json == _lastState) return;
    _lastState = json;
    link.send(jsonDecode(json) as Map<String, Object?>);
  }

  /// Sends the settings to the phone when they changed.
  void pushSettings(Map<String, Object?> settings) {
    if (!active) return;
    final json = jsonEncode({'t': 'settings', ...settings});
    if (json == _lastSettings) return;
    _lastSettings = json;
    link.send(jsonDecode(json) as Map<String, Object?>);
  }

  Future<void> close() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _partialTimer?.cancel();
    link.removeListener(notifyListeners);
    await link.close();
    for (final c in _pending.values) {
      c.complete(null);
    }
    _pending.clear();
    active = false;
  }
}
