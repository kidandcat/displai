import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/remote/remote_link.dart';

/// A local relay that keeps one socket per role and, like the real one, closes the older socket
/// with 4000 when a newer one takes the role.
class _Relay {
  late final HttpServer server;
  final sockets = <String, WebSocket>{};
  int connections = 0;

  String get url => 'ws://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final role = req.uri.queryParameters['role']!;
      final ws = await WebSocketTransformer.upgrade(req);
      connections++;
      final old = sockets[role];
      sockets[role] = ws;
      unawaited(old?.close(4000, 'replaced by a newer connection'));
      ws.listen((_) {});
    });
  }

  Future<void> stop() => server.close(force: true);
}

void main() {
  test('reconnect requests while a connection is in flight open one socket only', () async {
    final relay = _Relay();
    await relay.start();
    final link = RemoteLink(relay: relay.url, key: 'test pairing key', role: 'remote');
    // An assist launch: the app starts the link, then the listen request and the resume both ask
    // to reconnect before the first socket is up.
    link.start();
    link.reconnectNow();
    link.reconnectNow();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!link.online && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(relay.connections, 1);
    expect(link.online, isTrue);
    expect(link.lastError, isNull);
    await link.close();
    await relay.stop();
  });
}
