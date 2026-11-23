import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show GlobalKey, Size;

import '../app/assistant_ui.dart';
import '../audio/native_audio.dart';
import '../display/display.dart';
import '../display/display_runner.dart';
import '../presence/presence.dart';
import 'protocol.dart';
import 'remote_link.dart';

/// The phone side of DisplAI: the mic, the speaker and the display of a desktop that does all
/// the processing (speech recognition, the brain, the voice). See [RemoteProtocol].
class RemoteAssistant extends ChangeNotifier implements AssistantUi {
  RemoteAssistant({required this.relay, required this.key});

  final String relay;
  final String key;

  final audio = NativeAudio();
  @override
  final display = DisplayController();
  @override
  final presence = PresenceSignal();
  @override
  final GlobalKey screenKey = GlobalKey(debugLabel: 'displai-remote-screen');

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

  @override
  String get linkNote {
    if (_hostReady) return '';
    if (link.lastError == 'replaced') return 'Otro móvil está conectado a este ordenador';
    if (!link.online) return 'Conectando…';
    return 'Esperando al ordenador… (abre DisplAI en él)';
  }

  void start() {
    _subs
      ..add(link.messages.listen(_onMessage))
      ..add(link.audio.listen(_onAudio))
      ..add(audio.mic.listen(_onMic))
      ..add(audio.output.listen((o) => presence.addAudio(o.$1, o.$2)))
      ..add(audio.idle.listen((_) => link.send({'t': 'idle', 'n': _received})))
      ..add(display.userEvents.listen((text) => link.send({'t': 'event', 'text': text})));
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
          presence.mode = PresenceMode.idle;
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
        muted = m['muted'] == true;
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
    }
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
      error = 'No se pudo usar el micrófono: $e';
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
        'text': 'DisplAI display on the phone, ${size.width.round()}×${size.height.round()} logical px',
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
    link.send({'t': 'mute', 'on': muted});
    notifyListeners();
  }

  /// Back in the foreground: reconnect at once instead of waiting for the next retry.
  void resumed() => link.reconnectNow();

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
