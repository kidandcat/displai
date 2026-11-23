// ignore_for_file: avoid_print
// Smoke test of the phone remote, without a phone: acts as the remote through the relay, speaks
// a recorded question into the desktop's speech recognition, answers its display calls with a
// stub and counts the voice it gets back. The desktop must be running and paired with [key].
//
// Run: dart run tool/remote_smoke.dart <relay> <key> <speech.wav: mono float32 16 kHz>
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const kindMic = 1, kindVoice = 2;

Future<void> main(List<String> args) async {
  final relay = args[0], key = args[1];
  final speech = readWav(File(args[2]).readAsBytesSync());
  final t0 = DateTime.now();
  String at() => '${(DateTime.now().difference(t0).inMilliseconds / 1000).toStringAsFixed(1)}s';

  final ws = await WebSocket.connect('$relay/ws?role=remote', headers: {'Authorization': 'Bearer $key'});
  final tools = <String>[];
  var voiceFrames = 0, voiceSamples = 0, rate = 0, replayed = 0;
  String heard = '', lastMode = '';
  DateTime? lastVoice;
  final hostHello = Completer<void>();
  final done = Completer<void>();

  ws.listen((frame) {
    if (frame is List<int>) {
      if (frame[0] == kindVoice) {
        voiceFrames++;
        voiceSamples += (frame.length - 1) ~/ 2;
        if (voiceFrames == 1) print('${at()} first voice frame');
        lastVoice = DateTime.now();
      }
      return;
    }
    final m = jsonDecode(frame as String) as Map<String, dynamic>;
    switch (m['t']) {
      case 'peer':
        print('${at()} peer up=${m['up']}');
        if (m['up'] == true) ws.add(jsonEncode({'t': 'hello', 'w': 360, 'h': 588, 'platform': 'smoke'}));
      case 'hello':
        rate = m['rate'] as int;
        print('${at()} host hello, voice at $rate Hz');
        if (!hostHello.isCompleted) hostHello.complete();
      case 'reset':
        print('${at()} reset');
      case 'state':
        heard = '${m['heard']}';
        if (m['mode'] != lastMode) {
          lastMode = '${m['mode']}';
          print('${at()} state mode=$lastMode activity="${m['activity']}" heard="$heard"');
        }
      case 'tool':
        final id = m['id'];
        if (id == null) {
          replayed++;
          return;
        }
        tools.add('${m['name']}');
        print('${at()} tool ${m['name']} ${jsonEncode(m['args']).substring(0, 80.clamp(0, jsonEncode(m['args']).length))}…');
        ws.add(jsonEncode({'t': 'result', 'id': id, 'text': 'ok: shown on the phone (stub)', 'error': false}));
      case 'partial':
        break;
      case 'stop':
        print('${at()} stop');
    }
  }, onDone: () {
    print('${at()} socket closed ${ws.closeCode} ${ws.closeReason}');
    if (!done.isCompleted) done.complete();
  });

  await hostHello.future.timeout(const Duration(seconds: 15));
  await Future<void>.delayed(const Duration(milliseconds: 500));

  // Mic: silence, the question, then silence for the rest of the test, in real time.
  const chunk = 512;
  final silence = Float32List(chunk);
  var pos = 0, sent = 0;
  final mic = Timer.periodic(const Duration(milliseconds: 32), (_) {
    Float32List samples = silence;
    if (sent > 30 && pos < speech.length) {
      final end = (pos + chunk).clamp(0, speech.length);
      samples = Float32List.sublistView(speech, pos, end);
      pos = end;
    }
    sent++;
    ws.add(encode(kindMic, samples));
  });

  // Like the phone: report "idle" once the voice stops arriving (it would have played it).
  final idle = Timer.periodic(const Duration(milliseconds: 300), (_) {
    final lv = lastVoice;
    if (lv != null && DateTime.now().difference(lv) > const Duration(milliseconds: 1500)) {
      lastVoice = null;
      ws.add(jsonEncode({'t': 'idle', 'n': voiceFrames}));
      print('${at()} idle n=$voiceFrames');
    }
    if (voiceFrames > 0 && lastVoice == null && lastMode == 'listening' && !done.isCompleted) done.complete();
  });

  await done.future.timeout(const Duration(seconds: 120), onTimeout: () => print('${at()} TIMEOUT'));
  mic.cancel();
  idle.cancel();
  await ws.close();
  final voiceSeconds = rate == 0 ? 0 : voiceSamples / rate;
  print('\nheard: "$heard"\ntools: $tools\nreplayed calls: $replayed\n'
      'voice: $voiceFrames frames, ${voiceSeconds.toStringAsFixed(1)} s');
  final ok = heard.isNotEmpty && voiceFrames > 0;
  print(ok ? 'PASS' : 'FAIL');
  exit(ok ? 0 : 1);
}

Uint8List encode(int kind, Float32List s) {
  final out = Uint8List(1 + s.length * 2);
  out[0] = kind;
  final pcm = ByteData.sublistView(out, 1);
  for (var i = 0; i < s.length; i++) {
    pcm.setInt16(i * 2, (s[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return out;
}

/// The samples of a WAV file in 32-bit float (afconvert -f WAVE -d LEF32@16000 -c 1).
Float32List readWav(Uint8List bytes) {
  final d = ByteData.sublistView(bytes);
  var p = 12;
  while (p + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(p, p + 4));
    final size = d.getUint32(p + 4, Endian.little);
    if (id == 'data') {
      final n = size ~/ 4;
      final out = Float32List(n);
      for (var i = 0; i < n; i++) {
        out[i] = d.getFloat32(p + 8 + i * 4, Endian.little);
      }
      return out;
    }
    p += 8 + size + (size & 1);
  }
  throw const FormatException('no data chunk');
}
