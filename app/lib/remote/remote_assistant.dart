import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show GlobalKey, Size;

import '../app/assistant_ui.dart';
import '../app/settings.dart';
import '../audio/native_audio.dart';
import '../brain/models.dart';
import '../display/display.dart';
import '../display/display_runner.dart';
import '../l10n/l10n.dart';
import '../presence/presence.dart';
import 'protocol.dart';
import 'remote_link.dart';

/// The phone side of Minerva: the mic, the speaker and the display of a desktop that does all
/// the processing (speech recognition, the brain, the voice). See [RemoteProtocol].
///
/// Its settings are the desktop's: shown as the desktop last sent them, and changed by asking it.
class RemoteAssistant extends ChangeNotifier implements AssistantUi, AssistantSettings {
  RemoteAssistant({required this.relay, required this.key});

  final String relay;
  final String key;

  final audio = NativeAudio();
  @override
  final display = DisplayController();
  @override
  final presence = PresenceSignal();
  @override
  final GlobalKey screenKey = GlobalKey(debugLabel: 'minerva-remote-screen');

  late final RemoteLink link = RemoteLink(relay: relay, key: key, role: 'remote');
  final _subs = <StreamSubscription<Object?>>[];

  /// The desktop is connected and has said hello.
  bool _hostReady = false;
  int? _playRate;
  bool _audioStarting = false;

  /// Voice frames received since the desktop's hello (reported back when the queue drains).
  int _received = 0;

  Size _size = Size.zero;

  @override
  bool get ready => _hostReady;
  @override
  String? error;
  @override
  bool muted = false;
  @override
  String activity = '';
  @override
  String lastHeard = '';
  @override
  int backgroundJobs = 0;

  // Settings, as the desktop last sent them.

  /// The desktop has sent its settings.
  bool settingsKnown = false;
  @override
  ModelChoice brainModel = defaultBrainModel;
  @override
  ModelChoice workerModel = defaultWorkerModel;
  final _catalogs = <BrainProvider, ModelCatalog>{};
  @override
  ModelCatalog? catalogFor(BrainProvider provider) => _catalogs[provider];
  @override
  Set<BrainProvider> unavailableProviders = {};
  @override
  String? fastUnavailable;
  @override
  int voice = defaultVoice;

  /// The desktop's saved credentials: names, descriptions and field names (never values).
  List<({String name, String description, List<String> fields})> credentials = const [];

  /// Why the desktop's vault can't be used, or null.
  String? vaultError;

  /// The desktop's webhooks (null when it does not run them), its status line, and whether they
  /// can be received.
  List<({String name, String description, String? url})>? webhooks;
  String webhooksStatus = '';
  bool webhooksOn = false;

  @override
  String get linkNote {
    if (_hostReady) return '';
    final l = strings;
    if (link.lastError == 'replaced') return l.remoteReplaced;
    if (!link.online) return l.remoteConnecting;
    return l.remoteWaitingHost;
  }

  void start() {
    _subs
      ..add(link.messages.listen(_onMessage))
      ..add(link.audio.listen(_onAudio))
      ..add(audio.mic.listen(_onMic))
      ..add(audio.output.listen((o) => presence.addAudio(o.$1, o.$2)))
      ..add(audio.idle.listen((_) => link.send({'t': 'idle', 'n': _received})))
      ..add(display.userEvents.listen((text) => link.send({'t': 'event', 'text': text})))
      // Typed credentials go to the desktop's vault, over the encrypted link only.
      ..add(display.vaultSubmissions.listen((v) => link.send({'t': 'vault', ...v.toJson()})));
    link.addListener(notifyListeners);
    link.start();
    presence.mode = PresenceMode.idle;
  }

  /// The size of the display area changed (first layout, rotation).
  void setDisplaySize(Size size) {
    if (size == _size || size.isEmpty) return;
    _size = size;
    if (link.peerUp) _hello();
  }

  void _hello() => link.send({
        't': 'hello',
        'w': _size.width.round(),
        'h': _size.height.round(),
        'platform': Platform.operatingSystem,
      });

  void _onMessage(Map<String, dynamic> m) {
    switch (m['t']) {
      case 'peer':
        if (m['up'] == true) {
          _hello();
        } else {
          _hostReady = false;
          unawaited(audio.stop());
          display.cancelPartial();
          presence
            ..mode = PresenceMode.idle
            ..workers = const [];
          activity = '';
          notifyListeners();
        }
      case 'hello':
        _received = 0;
        _hostReady = true;
        final rate = (m['rate'] as num?)?.toInt();
        if (rate != null && rate != _playRate) unawaited(_startAudio(rate));
        notifyListeners();
      case 'state':
        final mode = m['mode'];
        final next = PresenceMode.values.where((v) => v.name == mode).firstOrNull;
        if (next != null && presence.mode != next) presence.mode = next;
        activity = '${m['activity'] ?? ''}';
        lastHeard = '${m['heard'] ?? ''}';
        backgroundJobs = (m['jobs'] as num?)?.toInt() ?? 0;
        presence.workers = [for (final id in m['workers'] as List? ?? const []) (id as num).toInt()];
        muted = m['muted'] == true;
        presence.muted = muted;
        if (_unmuteOnState) {
          _unmuteOnState = false;
          if (muted) return toggleMute();
        }
        notifyListeners();
      case 'stop':
        unawaited(audio.stop());
      case 'reset':
        display.reset();
      case 'tool':
        unawaited(_runTool(m));
      case 'partial':
        display.streamPartial('${m['name']}', '${m['json']}');
      case 'cancel_partial':
        display.cancelPartial();
      case 'settings':
        _applySettings(m);
    }
  }

  /// A message from the desktop, as if it came over the link.
  @visibleForTesting
  void handleMessage(Map<String, dynamic> m) => _onMessage(m);

  /// The desktop's settings message (see [RemoteProtocol]).
  void _applySettings(Map<String, dynamic> m) {
    settingsKnown = true;
    brainModel = ModelChoice.fromJson(m['brain']) ?? brainModel;
    workerModel = ModelChoice.fromJson(m['workers']) ?? workerModel;
    // Each provider's models; a desktop from before there was a choice sends Claude's alone.
    final catalogs = m['catalogs'] is Map ? m['catalogs'] as Map : {'claude': m['catalog']};
    final unavailable = m['unavailable'] is List ? m['unavailable'] as List : const [];
    for (final p in BrainProvider.values) {
      final c = ModelCatalog.fromJson(catalogs[p.name], p);
      if (c != null) _catalogs[p] = c;
    }
    unavailableProviders = {
      for (final p in BrainProvider.values)
        if (unavailable.contains(p.name)) p,
    };
    fastUnavailable = m['fast_unavailable'] as String?;
    // The phone's screens follow the desktop's language too.
    languageSetting.value = validLanguage(m['language'] as String?);
    voice = validVoice((m['voice'] as num?)?.toInt()) ?? voice;
    final vault = m['vault'] is Map ? m['vault'] as Map : const {};
    vaultError = vault['error'] as String?;
    credentials = [
      for (final c in vault['credentials'] as List? ?? const [])
        if (c is Map && c['name'] is String)
          (
            name: c['name'] as String,
            description: '${c['description'] ?? ''}',
            fields: [for (final f in c['fields'] as List? ?? const []) '$f'],
          ),
    ];
    final hooks = m['webhooks'];
    if (hooks is Map) {
      webhooksOn = hooks['on'] == true;
      webhooksStatus = '${hooks['status'] ?? ''}';
      webhooks = [
        for (final h in hooks['hooks'] as List? ?? const [])
          if (h is Map && h['name'] is String)
            (name: h['name'] as String, description: '${h['description'] ?? ''}', url: h['url'] as String?),
      ];
    } else {
      webhooks = null;
    }
    notifyListeners();
  }

  /// Asks the desktop to change settings; shown at once, then as the desktop confirms them.
  void _set(Map<String, Object?> change) {
    link.send({'t': 'set', ...change});
    notifyListeners();
  }

  @override
  void setBrainModel(ModelChoice choice) {
    brainModel = choice;
    _set({'brain': choice.toJson()});
  }

  @override
  void setWorkerModel(ModelChoice choice) {
    workerModel = choice;
    _set({'workers': choice.toJson()});
  }

  @override
  Future<void> setLanguage(String? code) async {
    languageSetting.value = validLanguage(code);
    _set({'language': languageSetting.value});
  }

  @override
  void setVoice(int voice) {
    final v = validVoice(voice);
    if (v == null) return;
    this.voice = v;
    _set({'voice': v});
  }

  /// Deletes one of the desktop's credentials.
  void deleteCredential(String name) {
    credentials = [for (final c in credentials) if (c.name != name) c];
    link.send({'t': 'vault_delete', 'name': name});
    notifyListeners();
  }

  Future<void> _startAudio(int rate) async {
    if (_audioStarting) return;
    _audioStarting = true;
    try {
      final format = await audio.start(playRate: rate);
      _playRate = rate;
      error = null;
      debugPrint('remote audio: $format');
    } catch (e) {
      error = strings.micFailed('$e');
      debugPrint('remote audio start failed: $e');
    } finally {
      _audioStarting = false;
      notifyListeners();
    }
  }

  Future<void> _runTool(Map<String, dynamic> m) async {
    final id = m['id'];
    final name = '${m['name']}';
    final args = (m['args'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    if (name == 'snapshot') {
      final shot = await DisplayRunner.capture(screenKey);
      if (id == null) return;
      if (shot == null) {
        link.send({'t': 'result', 'id': id, 'text': 'error: display not ready', 'error': true});
        return;
      }
      final (png, size) = shot;
      link.send({
        't': 'result',
        'id': id,
        'text': 'Minerva display on the phone, ${size.width.round()}×${size.height.round()} logical px',
        'png': base64Encode(png),
      });
      return;
    }
    // Replayed calls (no id) skip the layout wait: they only rebuild the display.
    final text = id == null ? display.callTool(name, args) : await DisplayRunner.run(display, name, args);
    if (id != null) {
      link.send({'t': 'result', 'id': id, 'text': text, 'error': text.startsWith('error:')});
    }
  }

  void _onAudio((int, Float32List) a) {
    if (a.$1 != RemoteProtocol.kindVoice || !_hostReady) return;
    _received++;
    unawaited(audio.play(a.$2));
  }

  void _onMic(Float32List samples) {
    if (!audio.isPlaying) presence.addAudio(samples, 16000);
    if (muted || !_hostReady) return;
    link.sendAudio(RemoteProtocol.kindMic, samples);
  }

  @override
  void toggleMute() {
    muted = !muted;
    presence.muted = muted;
    link.send({'t': 'mute', 'on': muted});
    notifyListeners();
  }

  /// Back in the foreground: reconnect at once instead of waiting for the next retry.
  void resumed() => link.reconnectNow();

  /// Opened as the phone's assistant: unmute and reconnect at once, so the mic streams to the
  /// desktop as soon as it says hello.
  void listenNow() {
    if (!_hostReady) _unmuteOnState = true;
    if (muted) toggleMute();
    link.reconnectNow();
  }

  /// [listenNow] ran before the desktop was there: unmute once it tells its state.
  bool _unmuteOnState = false;

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    link.removeListener(notifyListeners);
    unawaited(link.close());
    unawaited(audio.stop());
    presence.dispose();
    display.dispose();
    super.dispose();
  }
}
