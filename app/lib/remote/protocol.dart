import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// The wire protocol between Minerva on the desktop (the host, which does all the processing)
/// and its phone remote, through the relay (relay/main.go). Everything below travels end-to-end
/// encrypted (see secure_channel.dart); the relay only sees the handshake and its own notices.
///
/// Binary frames: one type byte, then 16-bit little-endian mono PCM.
///   [kindMic]  remote → host: echo-cancelled mic audio, 16 kHz.
///   [kindVoice] host → remote: the assistant's voice, at the rate given in the host's hello.
///
/// JSON messages have a "t" field:
///   link → both:      peer {up}                       the encrypted session came up or went down
///   host → remote:    hello {rate}                    sent when the remote joins
///                     state {mode, activity, heard, jobs, workers, muted}
///                     stop                            drop the queued voice (barge-in)
///                     reset                           clear the display (before a replay)
///                     tool {id?, name, args}          run a display tool; reply when id is set
///                     partial {name, json}            streaming tool input (progressive show)
///                     cancel_partial
///                     settings {brain, workers, catalog, fast_unavailable, language, voice,
///                               vault: {error, credentials: [{name, description, fields}]},
///                               webhooks?: {on, status, hooks: [{name, description, url}]}}
///                                                     the desktop's settings, when they change
///                                                     (field names only, never vault values)
///   remote → host:    hello {w, h, platform}          logical screen size of the remote display
///                     result {id, text, error?, png?} a display tool's result (png: base64)
///                     idle {n}                        voice queue drained after n voice frames
///                     event {text}                    a display action ("[display] ...")
///                     mute {on}                       the user muted or unmuted the phone mic
///                     vault {name, description, fields: [{name, value, secret}]}
///                                                     a credential typed in a vault form; the
///                                                     host saves it in its vault, never in the
///                                                     brain's conversation
///                     set {brain?, workers?, language?, voice?}
///                                                     the user changed settings on the phone
///                                                     (brain/workers: {model, effort, fast};
///                                                     language null: follow the OS)
///                     vault_delete {name}             the user deleted a credential
class RemoteProtocol {
  static const kindMic = 1;
  static const kindVoice = 2;

  /// The relay Minerva uses unless MINERVA_RELAY says otherwise. Run your own with relay/.
  static const defaultRelay = 'wss://minerva.kidandcat.com';

  /// Pairing link encoded in the QR code the desktop shows.
  static String pairingLink(String relay, String key) =>
      'minerva://pair?r=${Uri.encodeQueryComponent(relay)}&k=${Uri.encodeQueryComponent(key)}';

  /// (relay, key) from a pairing link, or null.
  static (String, String)? parsePairingLink(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || uri.scheme != 'minerva' || uri.host != 'pair') return null;
    final relay = uri.queryParameters['r'];
    final key = uri.queryParameters['k'];
    if (relay == null || key == null || key.length < 32) return null;
    if (!relay.startsWith('wss://') && !relay.startsWith('ws://')) return null;
    return (relay, key);
  }

  /// A new random pairing key (256 bits, base64url).
  static String newKey() {
    final r = math.Random.secure();
    return base64Url.encode(List<int>.generate(32, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  static Uri socketUri(String relay, String role) => Uri.parse('$relay/ws?role=$role');

  /// Float samples in [-1, 1] → a binary frame of [kind] + PCM16 LE.
  static Uint8List encodeAudio(int kind, Float32List samples) {
    final out = Uint8List(1 + samples.length * 2);
    out[0] = kind;
    final pcm = ByteData.sublistView(out, 1);
    for (var i = 0; i < samples.length; i++) {
      final s = (samples[i].clamp(-1.0, 1.0) * 32767).round();
      pcm.setInt16(i * 2, s, Endian.little);
    }
    return out;
  }

  /// The samples of a binary audio frame (without the kind byte).
  static Float32List decodeAudio(Uint8List frame) {
    final n = (frame.length - 1) ~/ 2;
    final pcm = ByteData.sublistView(frame, 1);
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = pcm.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }
}
