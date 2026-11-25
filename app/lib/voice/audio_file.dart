import 'dart:io';
import 'dart:typed_data';

class AudioFileException implements Exception {
  AudioFileException(this.message);

  final String message;

  @override
  String toString() => 'audio file: $message';
}

/// Audio files (voice notes, recordings, songs) as the 16 kHz mono samples the speech recognizer
/// takes.
///
/// macOS's `afconvert` decodes most formats (Ogg Opus voice notes, MP3, M4A/AAC, WAV, AIFF, FLAC);
/// whatever it can't is tried with `ffmpeg` when one is installed.
abstract final class AudioFile {
  static const sampleRate = 16000;

  /// The samples of [path], decoded and resampled to 16 kHz mono. The converters are looked for on
  /// PATH and in the usual folders (a GUI app's PATH lacks Homebrew's).
  static Future<Float32List> decode(String path) async {
    final tmp = await Directory.systemTemp.createTemp('minerva-audio');
    try {
      final wav = '${tmp.path}/audio.wav';
      final errors = <String>[];
      for (final (cmd, args) in [
        ('afconvert', ['-f', 'WAVE', '-d', 'LEI16@$sampleRate', '-c', '1', path, wav]),
        ('ffmpeg', ['-nostdin', '-loglevel', 'error', '-y', '-i', path, '-vn', '-ac', '1', '-ar', '$sampleRate', '-c:a', 'pcm_s16le', wav]),
      ]) {
        final exe = _find(cmd, Platform.environment['PATH'] ?? '');
        if (exe == null) {
          errors.add('$cmd not found');
          continue;
        }
        final r = await Process.run(exe, args);
        if (r.exitCode == 0 && File(wav).existsSync()) return parseWav(await File(wav).readAsBytes());
        errors.add('$cmd: ${'${r.stderr}'.trim().split('\n').last}');
      }
      throw AudioFileException('could not decode ${path.split('/').last} (${errors.join('; ')})');
    } finally {
      await tmp.delete(recursive: true);
    }
  }

  static String? _find(String cmd, String path) {
    for (final dir in [...path.split(':'), '/usr/bin', '/opt/homebrew/bin', '/usr/local/bin']) {
      if (dir.isEmpty) continue;
      final f = File('$dir/$cmd');
      if (f.existsSync()) return f.path;
    }
    return null;
  }

  /// The samples (-1..1) of a 16-bit PCM WAV file, mono or the first channel.
  static Float32List parseWav(Uint8List bytes) {
    final d = ByteData.sublistView(bytes);
    String tag(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));
    if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') throw AudioFileException('not a WAV file');
    int? channels, bits;
    var at = 12;
    while (at + 8 <= bytes.length) {
      final id = tag(at);
      var size = d.getUint32(at + 4, Endian.little);
      final body = at + 8;
      if (id == 'fmt ') {
        final format = d.getUint16(body, Endian.little);
        channels = d.getUint16(body + 2, Endian.little);
        bits = d.getUint16(body + 14, Endian.little);
        // 0xFFFE: WAVE_FORMAT_EXTENSIBLE, PCM in practice here.
        if ((format != 1 && format != 0xFFFE) || bits != 16) throw AudioFileException('not 16-bit PCM');
      } else if (id == 'data') {
        if (channels == null || bits == null) throw AudioFileException('data before format');
        // Streams written while converting can leave the size unset (0 or 0xFFFFFFFF).
        if (size == 0 || body + size > bytes.length) size = bytes.length - body;
        final frames = size ~/ (2 * channels);
        final out = Float32List(frames);
        for (var i = 0; i < frames; i++) {
          out[i] = d.getInt16(body + i * 2 * channels, Endian.little) / 32768;
        }
        return out;
      }
      at = body + size + (size & 1);
    }
    throw AudioFileException('no audio data');
  }
}
