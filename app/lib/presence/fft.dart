import 'dart:math' as math;
import 'dart:typed_data';

/// Fixed-size real-input FFT (radix-2, iterative, in place) with a Hann window.
///
/// Twiddles, bit-reversal table and window are precomputed once, so
/// [magnitudes] does no allocation per call besides what the caller owns.
class Fft {
  Fft(this.size)
    : assert(size > 1 && (size & (size - 1)) == 0, 'size must be a power of 2'),
      _re = Float64List(size),
      _im = Float64List(size),
      _cos = Float64List(size ~/ 2),
      _sin = Float64List(size ~/ 2),
      _rev = Int32List(size),
      window = Float64List(size) {
    final bits = (math.log(size) / math.ln2).round();
    for (var i = 0; i < size; i++) {
      var r = 0;
      var x = i;
      for (var b = 0; b < bits; b++) {
        r = (r << 1) | (x & 1);
        x >>= 1;
      }
      _rev[i] = r;
      window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (size - 1));
    }
    for (var i = 0; i < size ~/ 2; i++) {
      _cos[i] = math.cos(-2 * math.pi * i / size);
      _sin[i] = math.sin(-2 * math.pi * i / size);
    }
  }

  final int size;
  final Float64List window;
  final Float64List _re;
  final Float64List _im;
  final Float64List _cos;
  final Float64List _sin;
  final Int32List _rev;

  /// Windows [input] (length [size]) and writes `size / 2` bin magnitudes to
  /// [out], normalized so a full-scale sine of amplitude A peaks at about A.
  void magnitudes(Float64List input, Float64List out) {
    final n = size;
    for (var i = 0; i < n; i++) {
      _re[_rev[i]] = input[i] * window[i];
      _im[_rev[i]] = 0;
    }
    for (var len = 2; len <= n; len <<= 1) {
      final half = len >> 1;
      final step = n ~/ len;
      for (var start = 0; start < n; start += len) {
        for (var k = 0; k < half; k++) {
          final wr = _cos[k * step];
          final wi = _sin[k * step];
          final a = start + k;
          final b = a + half;
          final tr = _re[b] * wr - _im[b] * wi;
          final ti = _re[b] * wi + _im[b] * wr;
          _re[b] = _re[a] - tr;
          _im[b] = _im[a] - ti;
          _re[a] += tr;
          _im[a] += ti;
        }
      }
    }
    // Hann window coherent gain is 0.5, and a real sine splits its energy
    // between +f and -f, so the peak bin is A * n / 4.
    final norm = 4.0 / n;
    for (var i = 0; i < n ~/ 2; i++) {
      out[i] = math.sqrt(_re[i] * _re[i] + _im[i] * _im[i]) * norm;
    }
  }
}
