import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'protocol.dart';

/// One side's connection to the relay (see [RemoteProtocol]), with automatic reconnection.
///
/// [peerUp] says whether the other side is connected right now; [messages] carries its JSON
/// messages and [audio] its binary audio frames (kind, samples).
class RemoteLink extends ChangeNotifier {
  RemoteLink({required this.relay, required this.key, required this.role});

  final String relay;
  final String key;

  /// 'host' (the desktop) or 'remote' (the phone).
  final String role;

  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  final _audio = StreamController<(int, Float32List)>.broadcast();

  WebSocket? _socket;
  Timer? _retry;
  int _failures = 0;
  bool _closed = false;

  /// Connected to the relay.
  bool get online => _socket != null;

  /// The other side is connected too.
  bool peerUp = false;

  /// Why the last connection attempt failed (for the UI), or null.
  String? lastError;

  Stream<Map<String, dynamic>> get messages => _messages.stream;
  Stream<(int, Float32List)> get audio => _audio.stream;

  void start() => unawaited(_connect());

  Future<void> _connect() async {
    if (_closed || _socket != null) return;
    try {
      final ws = await WebSocket.connect(
        RemoteProtocol.socketUri(relay, role).toString(),
        headers: {'Authorization': 'Bearer $key'},
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
      ws.listen(_onFrame, onDone: () => _dropped(ws), onError: (Object e) => _dropped(ws, e), cancelOnError: true);
    } catch (e) {
      lastError = '$e';
      _scheduleRetry();
      notifyListeners();
    }
  }

  void _onFrame(dynamic frame) {
    if (frame is String) {
      final Object? m;
      try {
        m = jsonDecode(frame);
      } catch (_) {
        return;
      }
      if (m is! Map<String, dynamic>) return;
      if (m['t'] == 'peer') {
        peerUp = m['up'] == true;
        notifyListeners();
      }
      _messages.add(m);
    } else if (frame is List<int> && frame.isNotEmpty) {
      final bytes = frame is Uint8List ? frame : Uint8List.fromList(frame);
      _audio.add((bytes[0], RemoteProtocol.decodeAudio(bytes)));
    }
  }

  void _dropped(WebSocket ws, [Object? error]) {
    if (_socket != ws) return;
    _socket = null;
    final wasUp = peerUp;
    peerUp = false;
    if (ws.closeCode == 4000) {
      // Another device took this role with the same key: do not fight over the room.
      lastError = 'replaced';
      debugPrint('remote link: replaced by a newer $role connection');
    } else {
      if (error != null) lastError = '$error';
      _scheduleRetry();
    }
    if (wasUp) _messages.add({'t': 'peer', 'up': false});
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

  void send(Map<String, Object?> message) {
    final ws = _socket;
    if (ws == null) return;
    ws.add(jsonEncode(message));
  }

  void sendAudio(int kind, Float32List samples) {
    final ws = _socket;
    if (ws == null || samples.isEmpty) return;
    ws.add(RemoteProtocol.encodeAudio(kind, samples));
  }

  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    final ws = _socket;
    _socket = null;
    peerUp = false;
    await ws?.close();
    await _messages.close();
    await _audio.close();
  }
}
