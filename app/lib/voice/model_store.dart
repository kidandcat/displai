import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../l10n/l10n.dart';

/// One downloadable model: a single file or a .tar.bz2 that unpacks into [dirName].
class ModelSpec {
  const ModelSpec({required this.label, required this.url, required this.checkPath, this.archive = false});

  /// Its name for the user, in the UI language.
  final String Function(AppLocalizations l) label;
  final String url;

  /// Path relative to the models dir that exists once the model is installed.
  final String checkPath;
  final bool archive;
}

const _base = 'https://github.com/k2-fsa/sherpa-onnx/releases/download';
const vadFile = 'silero_vad_v5.onnx';
const parakeetDir = 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8';
const supertonicDir = 'sherpa-onnx-supertonic-3-tts-int8-2026-05-11';

String _vadLabel(AppLocalizations l) => l.modelVad;
String _sttLabel(AppLocalizations l) => l.modelStt;
String _voiceLabel(AppLocalizations l) => l.modelVoice;

const models = [
  ModelSpec(label: _vadLabel, url: '$_base/asr-models/$vadFile', checkPath: vadFile),
  ModelSpec(
      label: _sttLabel,
      url: '$_base/asr-models/$parakeetDir.tar.bz2',
      checkPath: '$parakeetDir/tokens.txt',
      archive: true),
  ModelSpec(
      label: _voiceLabel,
      url: '$_base/tts-models/$supertonicDir.tar.bz2',
      checkPath: '$supertonicDir/voice.bin',
      archive: true),
];

/// Finds or downloads the local voice models (first run).
///
/// Location: `~/Library/Application Support/<bundle id>/models`, or `MINERVA_MODELS_DIR` if set.
class ModelStore extends ChangeNotifier {
  late String dir;
  bool ready = false;
  String status = '';

  /// The current model is unpacking (no progress to show).
  bool installing = false;
  double progress = 0; // 0..1 of the current download
  String? error;

  String get vad => '$dir/$vadFile';
  String get parakeet => '$dir/$parakeetDir';
  String get supertonic => '$dir/$supertonicDir';

  Future<void> ensure() async {
    final override = Platform.environment['MINERVA_MODELS_DIR'];
    dir = override ?? '${(await getApplicationSupportDirectory()).path}/models';
    await Directory(dir).create(recursive: true);
    try {
      for (final m in models) {
        if (File('$dir/${m.checkPath}').existsSync()) continue;
        await _download(m);
      }
      ready = true;
      status = '';
      installing = false;
    } catch (e) {
      error = '$e';
    }
    notifyListeners();
  }

  Future<void> _download(ModelSpec m) async {
    status = strings.modelDownloading(m.label(strings));
    installing = false;
    progress = 0;
    notifyListeners();
    final name = m.url.split('/').last;
    final tmp = File('$dir/$name.part');
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(m.url)));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode} for ${m.url}');
      final total = res.contentLength ?? 0;
      var got = 0;
      var lastNotify = DateTime.now();
      final sink = tmp.openWrite();
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0 && DateTime.now().difference(lastNotify).inMilliseconds > 100) {
          progress = got / total;
          lastNotify = DateTime.now();
          notifyListeners();
        }
      }
      await sink.close();
    } finally {
      client.close();
    }
    if (m.archive) {
      status = strings.modelInstalling(m.label(strings));
      installing = true;
      notifyListeners();
      // macOS always ships bsdtar, which handles .tar.bz2 natively and streams to disk.
      final r = await Process.run('/usr/bin/tar', ['xjf', tmp.path, '-C', dir]);
      await tmp.delete();
      if (r.exitCode != 0) throw ProcessException('tar', ['xjf', name], '${r.stderr}', r.exitCode);
    } else {
      await tmp.rename('$dir/$name');
    }
  }
}
