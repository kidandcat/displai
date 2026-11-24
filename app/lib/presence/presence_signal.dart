import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'fft.dart';

/// What the assistant is doing; drives the presence animation's look.
enum PresenceMode { idle, listening, thinking, speaking }

/// Audio-reactive state shared between the audio pipeline and [PresenceView].
///
/// The integrator sets [mode] and feeds PCM through [addAudio] (mic samples
/// while listening, the TTS samples currently playing while speaking). The
/// view reads [level] and [bands] every frame and calls [tick] so values decay
/// to zero when audio stops arriving.
///
/// Only [mode] changes notify listeners; audio updates are polled by the view's
/// frame loop to avoid rebuilding widgets 30 times a second.
class PresenceSignal extends ChangeNotifier {
  /// [clock] returns a monotonic time; injectable for tests.
  PresenceSignal({Duration Function()? clock})
    : _clock = clock ?? _defaultClock() {
    _lastTick = _clock();
  }

  static const int fftSize = 512;
  static const int bandCount = 8;

  /// Lowest / highest band edge in Hz (log-spaced in between).
  static const double minFrequency = 100;
  static const double maxFrequency = 8000;

  // Envelope time constants, seconds.
  static const double _levelAttack = 0.025;
  static const double _levelRelease = 0.30;
  static const double _bandAttack = 0.035;
  static const double _bandRelease = 0.20;
  static const double _activityRelease = 0.8;

  /// After this long without [addAudio], [tick] starts decaying to zero.
  static const Duration staleAfter = Duration(milliseconds: 120);

  // dB mapping to 0..1.
  static const double _levelFloorDb = -55;
  static const double _levelCeilDb = -10;
  static const double _bandFloorDb = -70;
  static const double _bandCeilDb = -12;

  /// Per-band dB tilt that compensates the natural spectral roll-off of voice,
  /// so high bands are visible too.
  static const double _bandTiltDb = 2.0;

  final Duration Function() _clock;
  final Fft _fft = Fft(fftSize);
  final Float64List _history = Float64List(fftSize);
  final Float64List _frame = Float64List(fftSize);
  final Float64List _mags = Float64List(fftSize ~/ 2);
  final Float32List _bands = Float32List(bandCount);
  int _historyPos = 0;

  int _binsRate = 0;
  final Int32List _binLo = Int32List(bandCount);
  final Int32List _binHi = Int32List(bandCount);

  double _level = 0;
  double _activity = 0;
  Duration? _lastAudio;
  late Duration _lastTick;

  PresenceMode _mode = PresenceMode.idle;

  static Duration Function() _defaultClock() {
    final sw = Stopwatch()..start();
    return () => sw.elapsed;
  }

  PresenceMode get mode => _mode;
  set mode(PresenceMode value) {
    if (value == _mode) return;
    _mode = value;
    notifyListeners();
  }

  bool _muted = false;

  /// Whether the microphone is muted; the view fades the accent to red.
  bool get muted => _muted;
  set muted(bool value) {
    if (value == _muted) return;
    _muted = value;
    notifyListeners();
  }

  /// Orbits of the gyroscope that can show a background worker.
  static const int maxWorkers = 3;

  final List<int?> _workerIds = List.filled(maxWorkers, null);
  final List<int> _workerEnds = List.filled(maxWorkers, 0);

  /// Whether a running background worker is on orbit [ring].
  bool workerOn(int ring) => _workerIds[ring] != null;

  /// How many workers have ended on orbit [ring]; a view flares the orbit
  /// when it grows.
  int workerEnds(int ring) => _workerEnds[ring];

  /// Ids of the running background workers, oldest first. Each takes a free
  /// orbit and keeps it while it runs; past [maxWorkers], newer ones wait for
  /// an orbit to free up.
  set workers(Iterable<int> running) {
    final ids = running.toSet();
    var changed = false;
    for (var i = 0; i < maxWorkers; i++) {
      final id = _workerIds[i];
      if (id == null || ids.contains(id)) continue;
      _workerIds[i] = null;
      _workerEnds[i]++;
      changed = true;
    }
    for (final id in ids) {
      if (_workerIds.contains(id)) continue;
      final free = _workerIds.indexOf(null);
      if (free < 0) break;
      _workerIds[free] = id;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Smoothed loudness, 0..1.
  double get level => _level;

  /// Smoothed spectrum, [bandCount] log-spaced bands, 0..1. Read-only view of
  /// internal storage: do not mutate.
  Float32List get bands => _bands;

  /// Stream activity (0..1) for the thinking state; decays on its own.
  double get activity => _activity;

  /// Call when text / tool deltas arrive while thinking; speeds up the sweep.
  void bumpActivity([double amount = 0.35]) {
    _activity = math.min(1.0, _activity + amount);
  }

  /// Feeds mono float PCM in [-1, 1] as it is heard / played.
  void addAudio(Float32List samples, int sampleRate) {
    if (samples.isEmpty || sampleRate <= 0) return;
    final now = _clock();
    final last = _lastAudio;
    if (last == null || now - last > staleAfter * 4) {
      // Old history belongs to a previous utterance; do not mix it in.
      _history.fillRange(0, fftSize, 0);
    }
    _lastAudio = now;

    final dt = samples.length / sampleRate;

    // Loudness: RMS of this chunk, mapped from dBFS to 0..1.
    var sum = 0.0;
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      sum += s * s;
    }
    final rms = math.sqrt(sum / samples.length);
    final levelTarget = _mapDb(_toDb(rms), _levelFloorDb, _levelCeilDb);
    _level = _envelope(_level, levelTarget, dt, _levelAttack, _levelRelease);

    // Spectrum: append to the 512-sample history and analyse the latest window.
    final start = samples.length > fftSize ? samples.length - fftSize : 0;
    for (var i = start; i < samples.length; i++) {
      _history[_historyPos] = samples[i];
      _historyPos = (_historyPos + 1) & (fftSize - 1);
    }
    for (var i = 0; i < fftSize; i++) {
      _frame[i] = _history[(_historyPos + i) & (fftSize - 1)];
    }
    _fft.magnitudes(_frame, _mags);
    _ensureBins(sampleRate);
    for (var b = 0; b < bandCount; b++) {
      var power = 0.0;
      for (var k = _binLo[b]; k < _binHi[b]; k++) {
        power += _mags[k] * _mags[k];
      }
      final db = _toDb(math.sqrt(power)) + _bandTiltDb * b;
      final target = _mapDb(db, _bandFloorDb, _bandCeilDb);
      _bands[b] = _envelope(_bands[b], target, dt, _bandAttack, _bandRelease);
    }
  }

  /// Advances time-based decay. Safe to call from several views in the same
  /// frame: it uses the wall clock, so extra calls see a near-zero delta.
  void tick() {
    final now = _clock();
    final dt = (now - _lastTick).inMicroseconds / 1e6;
    _lastTick = now;
    if (dt <= 0) return;
    _activity *= math.exp(-dt / _activityRelease);
    final last = _lastAudio;
    if (last != null && now - last <= staleAfter) return;
    final k = 1 - math.exp(-dt / _levelRelease);
    _level -= _level * k;
    final kb = 1 - math.exp(-dt / _bandRelease);
    for (var b = 0; b < bandCount; b++) {
      _bands[b] -= _bands[b] * kb;
    }
  }

  /// Clears audio state immediately (e.g. barge-in).
  void reset() {
    _level = 0;
    _activity = 0;
    _bands.fillRange(0, bandCount, 0);
    _history.fillRange(0, fftSize, 0);
    _lastAudio = null;
  }

  void _ensureBins(int sampleRate) {
    if (sampleRate == _binsRate) return;
    _binsRate = sampleRate;
    final binHz = sampleRate / fftSize;
    final nyquistBin = fftSize ~/ 2;
    final top = math.min(maxFrequency, sampleRate / 2 * 0.98);
    final ratio = math.pow(top / minFrequency, 1 / bandCount).toDouble();
    var prevHi = math.max(1, (minFrequency / binHz).round());
    for (var b = 0; b < bandCount; b++) {
      final hiHz = minFrequency * math.pow(ratio, b + 1);
      final lo = prevHi;
      var hi = (hiHz / binHz).round();
      if (hi <= lo) hi = lo + 1;
      if (hi > nyquistBin) hi = nyquistBin;
      _binLo[b] = math.min(lo, nyquistBin - 1);
      _binHi[b] = math.max(hi, _binLo[b] + 1);
      prevHi = _binHi[b];
    }
  }

  static double _toDb(double amplitude) =>
      20 * math.log(math.max(amplitude, 1e-9)) / math.ln10;

  static double _mapDb(double db, double floor, double ceil) =>
      ((db - floor) / (ceil - floor)).clamp(0.0, 1.0);

  static double _envelope(
    double current,
    double target,
    double dt,
    double attack,
    double release,
  ) {
    final tau = target > current ? attack : release;
    return current + (target - current) * (1 - math.exp(-dt / tau));
  }
}
