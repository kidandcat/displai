import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'protocol.dart';
import 'secure_channel.dart';

/// One side's connection to the relay (see [RemoteProtocol]), with automatic reconnection and
/// end-to-end encryption ([SecureChannel]): the relay only gets a room token and ciphertext.
///
/// [peerUp] says whether the other side is connected and the encrypted session is up; [messages]
/// carries its JSON messages and [audio] its binary audio frames (kind, samples).
class RemoteLink extends ChangeNotifier {
  RemoteLink({required this.relay, required this.key, required this.role});

  final String relay;
  final String key;

  /// 'host' (the desktop) or 'remote' (the phone).
  final String role;

  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  final _audio = StreamController<(int, Float32List)>.broadcast();

  WebSocket? _socket;
  SecureChannel? _channel;
  PairingSecrets? _secrets;
  Timer? _retry;
  int _failures = 0;
  bool _closed = false;

  /// Connected to the relay.
  bool get online => _socket != null;

  /// The other side is connected too, through an established encrypted session.
  bool peerUp = false;

  /// Fingerprint of the current session keys (the same on both devices), or null.
  String? get sessionFingerprint => _channel?.fingerprint;

  /// Why the last connection attempt failed (for the UI), or null.
  String? lastError;

  Stream<Map<String, dynamic>> get messages => _messages.stream;
  Stream<(int, Float32List)> get audio => _audio.stream;

  void start() => unawaited(_connect());

  Future<void> _connect() async {
    if (_closed || _socket != null) return;
    try {
      final secrets = _secrets ??= await PairingSecrets.derive(key);
      _channel ??= SecureChannel(
        role: role,
        psk: secrets.psk,
        transmit: (frame) => _socket?.add(frame),
        onUp: () => _peer(true),
        onDown: () => _peer(false),
        onMessage: _messages.add,
        onBinary: (frame) => _audio.add((frame[0], RemoteProtocol.decodeAudio(frame))),
        log: debugPrint,
      );
      final ws = await WebSocket.connect(
        RemoteProtocol.socketUri(relay, role).toString(),
        headers: {'Authorization': 'Bearer ${secrets.roomToken}'},
      ).timeout(const Duration(seconds: 15));
      if (_closed) {
        await ws.close();
        return;
      }
      ws.pingInterval = const Duration(seconds: 20);
      _socket = ws;
      _failures = 0;
      lastError = null;
      notifyListeners();
      ws.listen(
        (frame) {
          if (_socket == ws) _channel!.receive(frame as Object);
        },
        onDone: () => _dropped(ws),
        onError: (Object e) => _dropped(ws, e),
        cancelOnError: true,
      );
    } catch (e) {
      lastError = '$e';
      _scheduleRetry();
      notifyListeners();
    }
  }

  void _peer(bool up) {
    peerUp = up;
    notifyListeners();
    _messages.add({'t': 'peer', 'up': up});
  }

  void _dropped(WebSocket ws, [Object? error]) {
    if (_socket != ws) return;
    _socket = null;
    _channel?.reset();
    if (ws.closeCode == 4000) {
      // Another device took this role with the same key: do not fight over the room.
      lastError = 'replaced';
      debugPrint('remote link: replaced by a newer $role connection');
    } else {
      if (error != null) lastError = '$error';
      _scheduleRetry();
    }
    notifyListeners();
  }

  void _scheduleRetry() {
    if (_closed) return;
    _retry?.cancel();
    final seconds = math.min(30, 1 << math.min(_failures, 5));
    _failures++;
    _retry = Timer(Duration(seconds: seconds), _connect);
  }

  /// Reconnects at once (e.g. after the app comes back to the foreground).
  void reconnectNow() {
    if (_closed || _socket != null) return;
    _retry?.cancel();
    unawaited(_connect());
  }

  /// Sends a message to the peer; dropped while no encrypted session is up.
  void send(Map<String, Object?> message) => _channel?.send(message);

  void sendAudio(int kind, Float32List samples) {
    if (samples.isEmpty) return;
    _channel?.sendBinary(RemoteProtocol.encodeAudio(kind, samples));
  }

  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    final ws = _socket;
    _socket = null;
    _channel?.reset();
    peerUp = false;
    await ws?.close();
    await _messages.close();
    await _audio.close();
  }
}
