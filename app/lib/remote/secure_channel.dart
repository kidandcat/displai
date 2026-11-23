/// End-to-end encryption between Minerva on the desktop and its phone remote. The relay forwards
/// frames it can neither read nor forge, replay, reorder or inject.
///
/// Keys
///   The pairing key (256 random bits) is shared only through the QR code the desktop shows, so
///   it never crosses the network. HKDF-SHA256 derives two independent values from it:
///     room token  the relay credential ("Authorization: Bearer"); the relay hashes it into a room
///     psk         a pre-shared key mixed into every session key; it never leaves the devices
///   HKDF is one-way: knowing the room token gives no information about the pairing key or psk.
///
/// Handshake, each time both sides are connected (the pattern of Noise NNpsk0)
///   both → other:  `{"t":"hs","v":1,"pub":"<X25519 ephemeral public key, base64>"}`  (plain text)
///   keys = HKDF-SHA256(ikm: X25519(own secret, peer public), salt: psk,
///                      info: "minerva session v1" ‖ host public ‖ remote public)
///        → 32-byte key host → remote ‖ 32-byte key remote → host
///   both → other:  sealed {"t":"ready"}; a side reports the peer as up only once it opens it.
///   Without the psk nobody in the middle can compute the keys, even by swapping the public keys;
///   new ephemeral keys per session give forward secrecy for past sessions.
///
/// Sealed frames (binary WebSocket frames)
///   [8-byte little-endian counter][ChaCha20-Poly1305 ciphertext][16-byte tag]
///   nonce = counter (8 bytes LE) ‖ 4 zero bytes. Counters restart at 0 with each session's new
///   keys, and the receiver accepts only increasing counters (no replay or reordering).
///   Plaintext: one type byte, then the payload: 0 = a UTF-8 JSON message; otherwise an audio
///   frame as built by RemoteProtocol.encodeAudio (its kind byte doubles as the type).
///
/// Plain text frames other than the relay's "peer" notices and the handshake are dropped, so the
/// relay cannot inject messages. What the relay still sees: when each side connects, the size and
/// timing of the frames, and the ephemeral public keys.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

const _version = 1;
const _typeJson = 0;
const _tagLength = 16;
const _aead = DartChacha20.poly1305Aead();
final _x25519 = DartX25519();

/// The two values derived from a pairing key.
class PairingSecrets {
  PairingSecrets._(this.roomToken, this.psk);

  /// What the relay gets instead of the pairing key.
  final String roomToken;

  /// Mixed into every session's keys; never sent anywhere.
  final List<int> psk;

  static Future<PairingSecrets> derive(String pairingKey) async {
    final ikm = SecretKey(utf8.encode(pairingKey));
    final hkdf = DartHkdf(hmac: DartHmac.sha256(), outputLength: 32);
    Future<List<int>> expand(String info) async =>
        (await hkdf.deriveKey(secretKey: ikm, info: utf8.encode(info))).extractBytes();
    final token = await expand('minerva relay room v1');
    final psk = await expand('minerva psk v1');
    return PairingSecrets._(base64Url.encode(token).replaceAll('=', ''), psk);
  }
}

/// The encryption layer of one side's relay connection. Feed it every frame from the socket with
/// [receive] (it keeps their order), and call [reset] when the socket drops. It reports the peer
/// with [onUp] and [onDown], and delivers what the peer sent once the session is established.
class SecureChannel {
  SecureChannel({
    required this.role,
    required this.psk,
    required this.transmit,
    required this.onUp,
    required this.onDown,
    required this.onMessage,
    required this.onBinary,
    this.log,
  }) : assert(role == 'host' || role == 'remote');

  /// 'host' (the desktop) or 'remote' (the phone).
  final String role;
  final List<int> psk;

  /// Writes a frame (String or Uint8List) to the current socket.
  final void Function(Object frame) transmit;
  final void Function() onUp;
  final void Function() onDown;
  final void Function(Map<String, dynamic> message) onMessage;

  /// A binary payload from the peer; its first byte is the audio kind.
  final void Function(Uint8List frame) onBinary;
  final void Function(String line)? log;

  bool _up = false;
  SimpleKeyPair? _ephemeral;
  List<int>? _ownPublic;
  bool _peerSeen = false;
  _SessionKeys? _keys;
  Future<void> _inbox = Future.value();
  int _epoch = 0;

  /// A session is established and the peer confirmed it.
  bool get up => _up;

  /// Short hex fingerprint of the current session keys (the same on both sides), or null.
  String? get fingerprint => _keys?.fingerprint;

  /// Queues a frame from the socket; frames are processed one at a time, in order.
  void receive(Object frame) {
    final epoch = _epoch;
    _inbox = _inbox.then((_) => epoch == _epoch ? _receive(frame, epoch) : null).catchError((Object e) {
      log?.call('secure channel: $e');
    });
  }

  /// The socket dropped: forget the session (frames still queued from it are ignored).
  void reset() {
    _epoch++;
    _drop();
  }

  /// Sends a JSON message to the peer. False when no session is up (the message is dropped).
  bool send(Map<String, Object?> message) {
    if (!_up) return false;
    final json = utf8.encode(jsonEncode(message));
    final clear = Uint8List(1 + json.length)
      ..[0] = _typeJson
      ..setAll(1, json);
    transmit(_keys!.seal(clear));
    return true;
  }

  /// Sends a binary frame whose first byte is its (non-zero) audio kind.
  bool sendBinary(Uint8List frame) {
    if (!_up || frame.isEmpty || frame[0] == _typeJson) return false;
    transmit(_keys!.seal(frame));
    return true;
  }

  Future<void> _receive(Object frame, int epoch) async {
    if (frame is String) {
      final Object? m;
      try {
        m = jsonDecode(frame);
      } catch (_) {
        return;
      }
      if (m is! Map<String, dynamic>) return;
      switch (m['t']) {
        case 'peer':
          if (m['up'] == true) {
            await _start(epoch);
          } else {
            _drop();
          }
        case 'hs':
          await _onHandshake(m, epoch);
        default:
          log?.call('secure channel: dropped an unencrypted "${m['t']}" message');
      }
    } else if (frame is List<int>) {
      final keys = _keys;
      if (keys == null) return;
      final clear = keys.open(frame is Uint8List ? frame : Uint8List.fromList(frame));
      if (clear == null) {
        log?.call('secure channel: dropped a frame that failed authentication or was replayed');
        return;
      }
      if (clear[0] != _typeJson) {
        if (_up) onBinary(clear);
        return;
      }
      final Object? m;
      try {
        m = jsonDecode(utf8.decode(Uint8List.sublistView(clear, 1)));
      } catch (_) {
        return;
      }
      if (m is! Map<String, dynamic>) return;
      if (m['t'] == 'ready') {
        if (!_up) {
          _up = true;
          log?.call('secure channel: session ${keys.fingerprint} up');
          onUp();
        }
      } else if (_up) {
        onMessage(m);
      }
    }
  }

  /// Starts a handshake with a new ephemeral key pair.
  Future<void> _start(int epoch) async {
    _drop();
    final pair = await _x25519.newKeyPair();
    final public = (await pair.extractPublicKey()).bytes;
    if (epoch != _epoch) return;
    _ephemeral = pair;
    _ownPublic = public;
    transmit(jsonEncode({'t': 'hs', 'v': _version, 'pub': base64Encode(public)}));
  }

  Future<void> _onHandshake(Map<String, dynamic> m, int epoch) async {
    final List<int> peerPublic;
    try {
      peerPublic = base64Decode(m['pub'] as String);
    } catch (_) {
      return;
    }
    if (m['v'] != _version || peerPublic.length != 32) {
      log?.call('secure channel: unsupported handshake (v=${m['v']})');
      return;
    }
    // The peer started over (or spoke first): answer with a fresh key pair of our own.
    if (_ephemeral == null || _peerSeen) await _start(epoch);
    if (epoch != _epoch) return;
    _peerSeen = true;
    final shared = await _x25519.sharedSecretKey(
      keyPair: _ephemeral!,
      remotePublicKey: SimplePublicKey(peerPublic, type: KeyPairType.x25519),
    );
    final sharedBytes = await shared.extractBytes();
    if (sharedBytes.every((b) => b == 0)) {
      log?.call('secure channel: rejected a low-order public key');
      return;
    }
    final own = _ownPublic!;
    final (hostPublic, remotePublic) = role == 'host' ? (own, peerPublic) : (peerPublic, own);
    final okm = await DartHkdf(hmac: DartHmac.sha256(), outputLength: 64).deriveKey(
      secretKey: SecretKey(sharedBytes),
      nonce: psk,
      info: [...utf8.encode('minerva session v1'), ...hostPublic, ...remotePublic],
    );
    if (epoch != _epoch) return;
    final bytes = okm.bytes;
    final hostToRemote = bytes.sublist(0, 32), remoteToHost = bytes.sublist(32, 64);
    final keys = role == 'host'
        ? _SessionKeys(send: hostToRemote, receive: remoteToHost)
        : _SessionKeys(send: remoteToHost, receive: hostToRemote);
    _keys = keys;
    transmit(keys.seal(Uint8List.fromList([_typeJson, ...utf8.encode('{"t":"ready"}')])));
  }

  void _drop() {
    _keys = null;
    _ephemeral = null;
    _ownPublic = null;
    _peerSeen = false;
    if (_up) {
      _up = false;
      onDown();
    }
  }
}

class _SessionKeys {
  _SessionKeys({required List<int> send, required List<int> receive})
      : _send = SecretKeyData(send),
        _receive = SecretKeyData(receive),
        fingerprint = _fingerprint(send, receive);

  final SecretKeyData _send;
  final SecretKeyData _receive;
  final String fingerprint;
  int _sent = 0;
  int _received = -1;

  Uint8List seal(List<int> clear) {
    final counter = _sent++;
    final box = _aead.encryptSync(clear, secretKey: _send, nonce: _nonce(counter));
    final out = Uint8List(8 + box.cipherText.length + _tagLength);
    ByteData.sublistView(out).setUint64(0, counter, Endian.little);
    out
      ..setAll(8, box.cipherText)
      ..setAll(8 + box.cipherText.length, box.mac.bytes);
    return out;
  }

  /// The plaintext, or null when the frame is forged, altered, replayed or out of order.
  Uint8List? open(Uint8List frame) {
    if (frame.length < 8 + 1 + _tagLength) return null;
    final counter = ByteData.sublistView(frame).getUint64(0, Endian.little);
    if (counter <= _received) return null;
    final end = frame.length - _tagLength;
    final List<int> clear;
    try {
      clear = _aead.decryptSync(
        SecretBox(Uint8List.sublistView(frame, 8, end), nonce: _nonce(counter), mac: Mac(frame.sublist(end))),
        secretKey: _receive,
      );
    } on SecretBoxAuthenticationError {
      return null;
    }
    _received = counter;
    return clear is Uint8List ? clear : Uint8List.fromList(clear);
  }

  static List<int> _nonce(int counter) {
    final n = Uint8List(12);
    ByteData.sublistView(n).setUint64(0, counter, Endian.little);
    return n;
  }

  /// Order-independent, so both sides print the same value.
  static String _fingerprint(List<int> a, List<int> b) {
    final keys = [a, b]..sort((x, y) => _compare(x, y));
    final digest = const DartSha256().hashSync([...keys[0], ...keys[1]]).bytes;
    return digest.take(4).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  static int _compare(List<int> x, List<int> y) {
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return x[i] - y[i];
    }
    return 0;
  }
}
