import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// How an utterance's voice compares with the owner's ([VoiceProfile.hear]).
enum VoiceMatch { owner, unsure, foreign }

/// The owner's voice: the running mean of the speaker embeddings of what they say to Minerva,
/// learned on this Mac only (`<dataDir>/voice_profile.json`, mode 0600; never sent anywhere).
///
/// The first [enrollSamples] long utterances enroll it (each like the ones before); after that it
/// keeps learning only from utterances that clearly match, so other voices don't pollute it, and
/// it follows the owner's voice from day to day: a new utterance weighs at least 1 / [maxWeight].
/// Scores are cosine similarities of 3D-Speaker CAM++ (VoxCeleb) embeddings.
class VoiceProfile {
  VoiceProfile(this.path, {required this.model});

  final String path;

  /// The embedding model the profile was learned with; one from another model is dropped.
  final String model;

  static const enrollSamples = 5;
  static const maxWeight = 50;

  /// Shorter utterances are not judged (their embeddings are unreliable), nor learned from
  /// unless this long.
  static const minSeconds = 1.0;
  static const learnSeconds = 1.5;

  /// The owner from this score, learned from; a foreign voice below [foreignScore]; unsure between.
  static const learnScore = 0.55;
  static const foreignScore = 0.40;

  /// While enrolling, a sample this far from the ones before is skipped.
  static const enrollScore = 0.45;

  Float32List? _mean;
  int _count = 0;

  /// Utterances learned from so far.
  int get samples => _count;

  /// Enrolled: it can tell the owner from others.
  bool get ready => _count >= enrollSamples && _mean != null;

  /// Reads the saved profile (none, unreadable or from another model: starts over).
  Future<void> load() async {
    try {
      final f = File(path);
      if (!await f.exists()) return;
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      if (m['model'] != model) return;
      final mean = [for (final v in m['mean'] as List) (v as num).toDouble()];
      _mean = _unit(Float32List.fromList(mean));
      _count = (m['count'] as num).toInt();
    } catch (_) {
      _mean = null;
      _count = 0;
    }
  }

  /// Forgets the owner's voice: the next utterances enroll it again.
  Future<void> reset() async {
    _mean = null;
    _count = 0;
    await (_saving = _saving.then((_) async {
      final f = File(path);
      if (await f.exists()) await f.delete();
    }));
  }

  /// Judges an utterance ([embedding] of [seconds] of speech) and learns from it while enrolling
  /// or when it clearly is the owner. Unsure while not [ready].
  VoiceMatch hear(Float32List embedding, double seconds) {
    if (seconds < minSeconds || embedding.isEmpty) return VoiceMatch.unsure;
    final e = _unit(embedding);
    final mean = _mean;
    if (mean != null && mean.length != e.length) return VoiceMatch.unsure;
    if (!ready) {
      if (seconds >= learnSeconds && (mean == null || score(mean, e) >= enrollScore)) _learn(e);
      return VoiceMatch.unsure;
    }
    final s = score(mean!, e);
    if (s < foreignScore) return VoiceMatch.foreign;
    if (s < learnScore) return VoiceMatch.unsure;
    if (seconds >= learnSeconds) _learn(e);
    return VoiceMatch.owner;
  }

  /// Cosine similarity of two unit vectors.
  static double score(Float32List a, Float32List b) {
    var s = 0.0;
    for (var i = 0; i < a.length; i++) {
      s += a[i] * b[i];
    }
    return s;
  }

  void _learn(Float32List e) {
    final mean = _mean;
    final w = math.min(_count, maxWeight - 1);
    if (mean == null) {
      _mean = e;
    } else {
      _mean = _unit(Float32List.fromList([for (var i = 0; i < e.length; i++) mean[i] * w + e[i]]));
    }
    _count++;
    _save();
  }

  Future<void> _saving = Future.value();

  void _save() {
    final json = jsonEncode({'model': model, 'count': _count, 'updated': DateTime.now().toIso8601String(), 'mean': _mean});
    _saving = _saving.then((_) async {
      try {
        final tmp = File('$path.tmp');
        await tmp.writeAsString(json, flush: true);
        await Process.run('/bin/chmod', ['600', tmp.path]);
        await tmp.rename(path);
      } catch (_) {
        // Kept in memory; written again with the next sample.
      }
    });
  }

  /// Done writing (tests).
  Future<void> get saved => _saving;

  static Float32List _unit(Float32List v) {
    var n = 0.0;
    for (final x in v) {
      n += x * x;
    }
    n = math.sqrt(n);
    if (n == 0) return v;
    return Float32List.fromList([for (final x in v) x / n]);
  }
}
