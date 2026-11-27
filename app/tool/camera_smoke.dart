// ignore_for_file: avoid_print
// Smoke test of the phone's camera, without the desktop app: acts as the desktop through the
// relay, asks the phone app for a photo (the brain's `camera` tool) and saves the JPEG it gets.
// The phone app must be open and paired with [key] (pair it with
// `adb shell am start -a android.intent.action.VIEW -d 'minerva://pair?r=<relay>&k=<key>'`).
// Do not use the key of a desktop that is running: the relay keeps the newest host.
//
// Run: dart run tool/camera_smoke.dart <relay> <key> <out.jpg> [back|front]
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:minerva/remote/secure_channel.dart';

Future<void> main(List<String> args) async {
  final relay = args[0], key = args[1], out = args[2];
  final facing = args.length > 3 ? args[3] : 'back';
  final t0 = DateTime.now();
  String at() => '${(DateTime.now().difference(t0).inMilliseconds / 1000).toStringAsFixed(1)}s';

  final secrets = await PairingSecrets.derive(key);
  final ws = await WebSocket.connect('$relay/ws?role=host', headers: {'Authorization': 'Bearer ${secrets.roomToken}'});
  late final SecureChannel channel;
  final result = Completer<Map<String, dynamic>>();
  var asked = false;

  void onMessage(Map<String, dynamic> m) {
    switch (m['t']) {
      case 'peer':
        print('${at()} peer up=${m['up']}');
        if (m['up'] == true) channel.send({'t': 'hello', 'rate': 24000});
      case 'hello':
        print('${at()} phone hello ${m['w']}×${m['h']} ${m['platform']}');
        if (!asked) {
          asked = true;
          print('${at()} asking for a photo ($facing)');
          channel.send({
            't': 'tool',
            'id': 1,
            'name': 'camera',
            'args': {'facing': facing},
          });
        }
      case 'result':
        if (m['id'] == 1 && !result.isCompleted) result.complete(m);
    }
  }

  channel = SecureChannel(
    role: 'host',
    psk: secrets.psk,
    transmit: (f) => ws.add(f),
    onUp: () => onMessage({'t': 'peer', 'up': true}),
    onDown: () => onMessage({'t': 'peer', 'up': false}),
    onMessage: onMessage,
    onBinary: (_) {},
    log: print,
  );
  ws.listen((frame) => channel.receive(frame as Object));

  var code = 0;
  try {
    final m = await result.future.timeout(const Duration(seconds: 90));
    final jpeg = m['jpeg'];
    if (jpeg is String) {
      final bytes = base64Decode(jpeg);
      File(out).writeAsBytesSync(bytes);
      print('${at()} photo: ${bytes.length} bytes → $out');
    } else {
      print('${at()} no photo: ${m['text']}');
      code = 1;
    }
  } on TimeoutException {
    print('${at()} the phone did not answer');
    code = 1;
  }
  await ws.close();
  exit(code);
}
