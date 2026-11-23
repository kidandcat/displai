import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/remote/protocol.dart';
import 'package:minerva/remote/secure_channel.dart';

/// Both sides of a pairing joined through an in-memory relay that records every frame it forwards
/// and can act maliciously through [intercept] (return null to drop a frame).
class _Pair {
  _Pair._(this.secrets, PairingSecrets? remoteSecrets) {
    host = _side('host', secrets);
    remote = _side('remote', remoteSecrets ?? secrets);
  }

  static Future<_Pair> create({String key = _key, String? remoteKey}) async => _Pair._(
        await PairingSecrets.derive(key),
        remoteKey == null ? null : await PairingSecrets.derive(remoteKey),
      );

  final PairingSecrets secrets;
  late final SecureChannel host;
  late final SecureChannel remote;
  final relaySaw = <Object>[];
  final received = <String, List<Map<String, dynamic>>>{'host': [], 'remote': []};
  final audio = <String, List<Uint8List>>{'host': [], 'remote': []};
  Object? Function(String from, Object frame)? intercept;

  SecureChannel _side(String role, PairingSecrets s) => SecureChannel(
        role: role,
        psk: s.psk,
        transmit: (frame) {
          relaySaw.add(frame);
          final f = intercept == null ? frame : intercept!(role, frame);
          if (f != null) (role == 'host' ? remote : host).receive(f);
        },
        onUp: () {},
        onDown: () {},
        onMessage: received[role]!.add,
        onBinary: audio[role]!.add,
      );

  /// What the relay itself sends when both sides are connected.
  void join() {
    remote.receive('{"t":"peer","up":true}');
    host.receive('{"t":"peer","up":true}');
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 150));

  /// Everything the relay could read, as one string (text frames, and binary frames as latin1).
  String get relayView => relaySaw.map((f) => f is String ? f : latin1.decode(f as List<int>)).join('\n');
}

const _key = 'q8V1k0Zr3o9JcXwz4mY2bE7nTgP6sAaLhUdRfKiQvOe';
const _secret = 'Pedido de croquetas para la mesa 7';

void main() {
  test('the relay gets a room token that reveals neither the pairing key nor the psk', () async {
    final s = await PairingSecrets.derive(_key);
    expect(s.roomToken.length, greaterThanOrEqualTo(32), reason: 'the relay requires 32+ characters');
    expect(s.roomToken, isNot(contains(_key)));
    expect(base64Url.decode('${s.roomToken}='), isNot(equals(s.psk)));
    expect((await PairingSecrets.derive(_key)).roomToken, s.roomToken, reason: 'both sides meet in one room');
    expect((await PairingSecrets.derive('${_key}x')).roomToken, isNot(s.roomToken));
  });

  test('messages and audio arrive in both directions and the relay only sees ciphertext', () async {
    final p = await _Pair.create();
    p.join();
    await p.settle();
    expect(p.host.up && p.remote.up, isTrue);
    expect(p.host.fingerprint, p.remote.fingerprint);

    p.host.send({'t': 'tool', 'name': 'show', 'args': {'title': _secret}});
    p.remote.send({'t': 'event', 'text': _secret});
    final voice = RemoteProtocol.encodeAudio(RemoteProtocol.kindVoice, Float32List.fromList([0.25, -0.5, 0.75]));
    p.host.sendBinary(voice);
    await p.settle();

    expect(p.remote.fingerprint, isNotNull);
    expect(p.received['remote']!.single['args']['title'], _secret);
    expect(p.received['host']!.single['text'], _secret);
    expect(p.audio['remote']!.single, voice);

    final view = p.relayView;
    expect(view, isNot(contains(_secret)));
    expect(view, isNot(contains('show')));
    expect(view, isNot(contains(_key)));
    expect(view, isNot(contains(base64Encode(p.secrets.psk))));
    // The only readable frames are the two handshakes with ephemeral public keys.
    final readable = p.relaySaw.whereType<String>().map((f) => jsonDecode(f)['t']).toList();
    expect(readable, ['hs', 'hs']);
    // Audio is sealed too: the PCM bytes do not appear in what the relay forwarded.
    final pcm = latin1.decode(voice.sublist(1));
    expect(view, isNot(contains(pcm)));
  });

  test('a relay that swaps the public keys (man in the middle) gets no session', () async {
    final p = await _Pair.create();
    final attacker = await DartX25519().newKeyPair();
    final attackerPublic = base64Encode((await attacker.extractPublicKey()).bytes);
    p.intercept = (from, frame) {
      if (frame is String && frame.contains('"hs"')) {
        return jsonEncode({...jsonDecode(frame) as Map<String, dynamic>, 'pub': attackerPublic});
      }
      return frame;
    };
    p.join();
    await p.settle();
    expect(p.host.up, isFalse);
    expect(p.remote.up, isFalse);
    expect(p.host.send({'t': 'state'}), isFalse, reason: 'nothing is sent without a session');
  });

  test('a device with another pairing key cannot join the session', () async {
    final p = await _Pair.create(remoteKey: 'another-key-that-was-never-in-the-qr-code-0123');
    p.join();
    await p.settle();
    expect(p.host.up || p.remote.up, isFalse);
  });

  test('altered, replayed and injected frames are dropped', () async {
    final p = await _Pair.create();
    p.join();
    await p.settle();
    expect(p.remote.up, isTrue);

    // Altered: flip one bit of the ciphertext.
    p.intercept = (from, frame) {
      if (frame is! Uint8List) return frame;
      return Uint8List.fromList(frame)..[10] ^= 1;
    };
    p.host.send({'t': 'stop'});
    await p.settle();
    expect(p.received['remote'], isEmpty);

    // Replayed: the relay sends a genuine frame a second time.
    p.intercept = null;
    p.host.send({'t': 'reset'});
    await p.settle();
    expect(p.received['remote']!.map((m) => m['t']), ['reset']);
    p.remote.receive(p.relaySaw.last);
    await p.settle();
    expect(p.received['remote']!.map((m) => m['t']), ['reset']);

    // Injected: an unencrypted message, as the old protocol sent them.
    p.remote.receive(jsonEncode({'t': 'tool', 'name': 'show', 'args': {'title': 'fake'}}));
    await p.settle();
    expect(p.received['remote']!.map((m) => m['t']), ['reset']);

    // The session survives all of it.
    p.host.send({'t': 'cancel_partial'});
    await p.settle();
    expect(p.received['remote']!.map((m) => m['t']), ['reset', 'cancel_partial']);
  });

  test('each connection gets new session keys', () async {
    final p = await _Pair.create();
    p.join();
    await p.settle();
    final first = p.host.fingerprint;
    final firstFrame = p.relaySaw.whereType<Uint8List>().first;

    // The remote reconnects: its socket drops and the relay announces it again.
    p.remote.reset();
    p.host.receive('{"t":"peer","up":false}');
    p.join();
    await p.settle();
    expect(p.host.up && p.remote.up, isTrue);
    expect(p.host.fingerprint, isNot(first));

    // A frame from the old session is rejected by the new one.
    p.remote.receive(firstFrame);
    p.host.send({'t': 'stop'});
    await p.settle();
    expect(p.received['remote']!.map((m) => m['t']), ['stop']);
  });
}
