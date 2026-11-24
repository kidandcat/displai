import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'presence_fallback_painter.dart';
import 'presence_signal.dart';

/// Default HUD accent: violet. Minerva's own side of the palette (the core,
/// her voice).
const Color kPresenceAccent = Color(0xFFA87CFF);

/// Second accent: ice blue. The "input" side of the palette (the user's voice,
/// data being worked on).
const Color kPresenceAccent2 = Color(0xFF4FD8FF);

/// Accent the presence fades to while the microphone is muted.
const Color kPresenceMutedAccent = Color(0xFFFF2A2A);

/// What the second accent fades to while the microphone is muted.
const Color kPresenceMutedAccent2 = Color(0xFFFF6A3C);

/// Near-black background used behind the full-window presence.
const Color kPresenceBackground = Color(0xFF040206);

/// Per-frame values shared by the shader and fallback painters.
class PresenceFrame extends ChangeNotifier {
  /// [time] and [spin] wrap here, so they keep float precision however long
  /// the app runs. A wrap is seamless for every `sin(x * k)` whose `k` has at
  /// most three decimals (see the shader's header).
  static const double wrap = 2000 * math.pi;

  /// Number of orbits in the gyroscope.
  static const int ringCount = 3;

  // Per orbit: resting tilt away from the viewer (radians), starting heading,
  // and how fast it precesses, nods and runs its comet (per unit of spin).
  static const List<double> _ringTilt = [1.10, 0.86, 1.00];
  static const List<double> _ringYaw = [0.5, 2.5, 4.3];
  static const List<double> _ringPrecession = [0.05, -0.036, 0.06];
  static const List<double> _ringComet = [0.30, -0.21, 0.16];

  double time = 0;
  double spin = 0;
  double level = 0;
  double activity = 0;
  final Float32List bands = Float32List(PresenceSignal.bandCount);

  /// Cross-fade weights for idle, listening, thinking, speaking (sum = 1).
  final Float32List state = Float32List(4)..[0] = 1;

  /// Mute blend, 0 (normal accent) .. 1 (muted red), eased over time.
  double muted = 0;

  /// Rows of the shell's rotation matrix (view space -> the shell's own).
  final Float64List rotation = Float64List(9);

  /// Per orbit, two unit vectors spanning its plane (6 values: u.xyz, v.xyz),
  /// already turned so the comet's head sits at `-u`.
  final Float64List ringBasis = Float64List(ringCount * 6);

  /// Per orbit, the inverse of its plane's 2x2 screen projection (4 values:
  /// rows for the plane's two coordinates).
  final Float64List ringInverse = Float64List(ringCount * 4);

  /// The same inverse projection for the HUD plane.
  final Float64List hudInverse = Float64List(4);

  /// Per orbit, how much a running background worker is on it (0..1, eased).
  final Float64List work = Float64List(ringCount);

  /// Per orbit, the flare of a worker that just ended (1, fading to 0).
  final Float64List done = Float64List(ringCount);

  /// [accent] blended toward [kPresenceMutedAccent] by [muted].
  Color tint(Color accent) =>
      muted <= 0 ? accent : Color.lerp(accent, kPresenceMutedAccent, muted)!;

  /// [kPresenceAccent2] blended toward its muted color by [muted].
  Color get tint2 => muted <= 0
      ? kPresenceAccent2
      : Color.lerp(kPresenceAccent2, kPresenceMutedAccent2, muted)!;

  /// Advances the clock by [dt] seconds, [spinRate] times faster for [spin],
  /// and recomputes the orientation of every moving part. All trigonometry
  /// that is constant across a frame happens here, once, not per pixel.
  void advance(double dt, double spinRate) {
    time = (time + dt) % wrap;
    spin = (spin + dt * spinRate) % wrap;

    // The shell turns around its own axis, its north pole leaning to the viewer.
    final pitch = 0.40 + 0.08 * math.sin(time * 0.11);
    final yaw = time * 0.05 + spin * 0.03;
    final cp = math.cos(pitch), sp = math.sin(pitch);
    final cy = math.cos(yaw), sy = math.sin(yaw);
    rotation
      ..[0] = cy
      ..[1] = sy * sp
      ..[2] = -sy * cp
      ..[3] = 0
      ..[4] = cp
      ..[5] = sp
      ..[6] = sy
      ..[7] = -cy * sp
      ..[8] = cy * cp;

    for (var i = 0; i < ringCount; i++) {
      final tilt = _ringTilt[i] + 0.17 * math.sin(spin * 0.023 * (i + 1) + i * 2.1);
      final heading = _ringYaw[i] + time * 0.03 + spin * _ringPrecession[i];
      final phase = spin * _ringComet[i];
      final st = math.sin(tilt), ct = math.cos(tilt);
      final sh = math.sin(heading), ch = math.cos(heading);
      // u0 is the line where the orbit's plane crosses the screen, v0 the
      // direction that leans away from it; (u, v) is that pair turned by the
      // comet's phase.
      final c = math.cos(phase), s = math.sin(phase);
      final ux = sh * c + ct * ch * s, uy = -ch * c + ct * sh * s, uz = -st * s;
      final vx = -sh * s + ct * ch * c, vy = ch * s + ct * sh * c, vz = -st * c;
      ringBasis
        ..[i * 6] = ux
        ..[i * 6 + 1] = uy
        ..[i * 6 + 2] = uz
        ..[i * 6 + 3] = vx
        ..[i * 6 + 4] = vy
        ..[i * 6 + 5] = vz;
      // det = the plane normal's z = cos(tilt), never near zero by construction.
      ringInverse
        ..[i * 4] = vy / ct
        ..[i * 4 + 1] = -vx / ct
        ..[i * 4 + 2] = -uy / ct
        ..[i * 4 + 3] = ux / ct;
    }

    // The HUD plane leans a little, and the lean slowly travels around.
    const lean = 0.30;
    final around = time * 0.07;
    final nx = math.sin(lean) * math.cos(around);
    final ny = math.sin(lean) * math.sin(around);
    final nz = math.cos(lean);
    // u = screen x projected onto the plane (so angles keep a fixed origin).
    final ul = math.sqrt(1 - nx * nx);
    final ux = (1 - nx * nx) / ul, uy = -nx * ny / ul, uz = -nx * nz / ul;
    final vx = ny * uz - nz * uy, vy = nz * ux - nx * uz;
    final det = ux * vy - vx * uy;
    hudInverse
      ..[0] = vy / det
      ..[1] = -vx / det
      ..[2] = -uy / det
      ..[3] = ux / det;
  }

  void markDirty() => notifyListeners();
}

/// The app's "face": a full-window audio-reactive HUD animation, or a small
/// orb when [compact] is true. Driven by [signal].
///
/// It is on screen all day, so it is built to be cheap: it paints only a
/// square around the orb, and redraws at [calmFps] ([compactCalmFps] for the
/// small orb) while nothing happens and at [activeFps] while there is voice,
/// thinking or a transition. It stops entirely while an ancestor [TickerMode]
/// is disabled.
class PresenceView extends StatefulWidget {
  const PresenceView({
    super.key,
    required this.signal,
    this.compact = false,
    this.accent = kPresenceAccent,
    this.compactSize = 36,
  });

  final PresenceSignal signal;
  final bool compact;
  final Color accent;

  /// Orb diameter in logical pixels when [compact] is true.
  final double compactSize;

  static const String shaderAsset = 'shaders/presence.frag';

  /// Frames per second while the orb is calm (idle, or listening in silence).
  static const int calmFps = 30;

  /// The same for the small orb: its slow motion covers under a pixel a frame
  /// at this rate, and a frame costs the same however small the orb is.
  static const int compactCalmFps = 20;

  /// Frames per second while there is voice, thinking, speaking or a fade.
  static const int activeFps = 60;

  /// Side of the square the full orb is painted in, as a fraction of the
  /// shortest side of the view. The shell's radius is 0.19 of that square.
  static const double fullExtent = 0.8;

  /// The square the orb is painted in, for a view of [size].
  static Rect orbRect(Size size, {required bool compact}) {
    final side = size.shortestSide * (compact ? 1.0 : fullExtent);
    return Rect.fromCenter(
      center: size.center(Offset.zero),
      width: side,
      height: side,
    );
  }

  static Future<ui.FragmentProgram>? _program;

  /// Overrides how the fragment program is loaded (tests use it to force the
  /// fallback path).
  @visibleForTesting
  static Future<ui.FragmentProgram> Function()? debugProgramLoader;

  /// Drops the cached program so the next view loads it again.
  @visibleForTesting
  static void debugResetProgramCache() => _program = null;

  /// Loads the shader once per process; every view shares the result.
  static Future<ui.FragmentProgram> loadProgram() {
    return _program ??= Future.sync(
      debugProgramLoader ?? () => ui.FragmentProgram.fromAsset(shaderAsset),
    );
  }

  @override
  State<PresenceView> createState() => _PresenceViewState();
}

enum _RenderPath { loading, shader, fallback }

class _PresenceViewState extends State<PresenceView> {
  // Seconds for a state cross-fade to get ~63% of the way.
  static const double _fadeTau = 0.28;

  // Seconds for the muted color fade to get ~63% of the way.
  static const double _muteTau = 0.3;

  // Seconds (~63%) for an orbit to light up for a worker, to let it go, and
  // for the flare of a worker that ended to fade.
  static const double _workRiseTau = 0.5;
  static const double _workFallTau = 1.0;
  static const double _doneTau = 0.5;

  // The timer that asks for the next frame fires this long before the frame
  // is due, so the request lands before that display refresh, not after it.
  static const int _leadMicros = 4000;

  final PresenceFrame _frame = PresenceFrame();
  ui.FragmentShader? _shader;
  _RenderPath _path = _RenderPath.loading;

  // The frame loop: a timer waits out the frame interval, then one frame
  // callback draws. Unlike a Ticker it never asks for a frame it will not
  // draw (a Ticker would run the pipeline at the display's 120 Hz).
  bool _running = false;
  bool _busy = true;
  Timer? _timer;
  int? _frameCallback;
  Duration? _lastStamp;

  // The signal's per-orbit count of ended workers, as last seen.
  final List<int> _workerEnds = List.filled(PresenceFrame.ringCount, 0);

  @override
  void initState() {
    super.initState();
    _frame.state
      ..fillRange(0, 4, 0)
      ..[widget.signal.mode.index] = 1;
    _frame.muted = widget.signal.muted ? 1 : 0;
    for (var i = 0; i < PresenceFrame.ringCount; i++) {
      _frame.work[i] = widget.signal.workerOn(i) ? 1 : 0;
      _workerEnds[i] = widget.signal.workerEnds(i);
    }
    _frame.advance(0, 0);
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Muted tickers (the window is hidden) stop the orb too.
    final enabled = TickerMode.valuesOf(context).enabled;
    if (enabled == _running) return;
    _running = enabled;
    if (enabled) {
      _lastStamp = null;
      _requestFrame();
    } else {
      _cancelPending();
    }
  }

  Future<void> _load() async {
    ui.FragmentShader? created;
    try {
      final program = await PresenceView.loadProgram();
      final shader = created = program.fragmentShader();
      // Throws if the compiled shader's uniform layout does not match ours.
      shader.setFloat(_ShaderPainter.floatCount - 1, 0);
      if (!mounted) {
        shader.dispose();
        return;
      }
      setState(() {
        _shader = shader;
        _path = _RenderPath.shader;
      });
    } catch (error) {
      created?.dispose();
      // Expected in environments without the compiled shader (tests, some
      // renderers): log and draw the Canvas fallback instead of crashing.
      debugPrint(
        'presence: ${PresenceView.shaderAsset} unavailable ($error); '
        'using the CustomPainter fallback',
      );
      if (mounted) setState(() => _path = _RenderPath.fallback);
    }
  }

  void _requestFrame() {
    _frameCallback ??= SchedulerBinding.instance.scheduleFrameCallback(
      _onFrame,
    );
  }

  void _cancelPending() {
    _timer?.cancel();
    _timer = null;
    final id = _frameCallback;
    if (id != null) SchedulerBinding.instance.cancelFrameCallbackWithId(id);
    _frameCallback = null;
  }

  void _onFrame(Duration stamp) {
    _frameCallback = null;
    if (!mounted || !_running) return;
    final last = _lastStamp;
    final dt = last == null
        ? 0.0
        : math.min((stamp - last).inMicroseconds / 1e6, 0.1);
    _lastStamp = stamp;
    _advance(dt);
    final fps = _busy
        ? PresenceView.activeFps
        : widget.compact
        ? PresenceView.compactCalmFps
        : PresenceView.calmFps;
    _timer = Timer(
      Duration(microseconds: 1000000 ~/ fps - _leadMicros),
      _requestFrame,
    );
  }

  void _advance(double dt) {
    final signal = widget.signal..tick();

    // Cross-fade state weights toward the current mode (exponential approach,
    // so a mode change mid-fade blends smoothly from wherever we are).
    final k = 1 - math.exp(-dt / _fadeTau);
    final target = signal.mode.index;
    final w = _frame.state;
    var sum = 0.0;
    for (var i = 0; i < 4; i++) {
      w[i] += ((i == target ? 1.0 : 0.0) - w[i]) * k;
      sum += w[i];
    }
    if (sum > 0) {
      for (var i = 0; i < 4; i++) {
        w[i] /= sum;
      }
    }

    final mutedTarget = signal.muted ? 1.0 : 0.0;
    _frame.muted +=
        (mutedTarget - _frame.muted) * (1 - math.exp(-dt / _muteTau));
    if ((_frame.muted - mutedTarget).abs() < 1e-3) _frame.muted = mutedTarget;

    final react = w[1] + w[3];
    _frame
      ..level = signal.level
      ..activity = signal.activity
      // Integrated rotation phase, so speeding up never makes anything jump.
      // Resting (idle, or listening in silence) turns slowly; speaking is
      // about 5x faster and thinking 13x to 17x, more with a loud voice.
      ..advance(
        dt,
        1.0 +
            0.3 * w[1] +
            4.0 * w[3] +
            12.0 * w[2] +
            4.0 * w[2] * signal.activity +
            5.0 * react * signal.level,
      );
    _frame.bands.setAll(0, signal.bands);

    // Background workers: each one lights an orbit; one that ends flares it.
    var settling = false;
    for (var i = 0; i < PresenceFrame.ringCount; i++) {
      final on = signal.workerOn(i) ? 1.0 : 0.0;
      final tau = on > _frame.work[i] ? _workRiseTau : _workFallTau;
      _frame.work[i] += (on - _frame.work[i]) * (1 - math.exp(-dt / tau));
      if ((_frame.work[i] - on).abs() < 1e-3) _frame.work[i] = on;
      final ends = signal.workerEnds(i);
      if (ends != _workerEnds[i]) {
        _workerEnds[i] = ends;
        _frame.done[i] = 1;
      } else if (_frame.done[i] > 0) {
        _frame.done[i] *= math.exp(-dt / _doneTau);
        if (_frame.done[i] < 1e-3) _frame.done[i] = 0;
      }
      settling = settling || _frame.work[i] != on || _frame.done[i] > 0;
    }

    // Calm = settled in idle or listening, in silence. Anything else moves
    // fast enough to deserve the higher frame rate.
    _busy =
        w[target] < 0.985 ||
        target >= PresenceMode.thinking.index ||
        signal.level > 0.02 ||
        _frame.muted != mutedTarget ||
        settling;
    _frame.markDirty();
  }

  @override
  void dispose() {
    _cancelPending();
    _shader?.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final CustomPainter painter = switch (_path) {
      _RenderPath.shader => _ShaderPainter(
        frame: _frame,
        shader: _shader!,
        accent: widget.accent,
        compact: widget.compact,
        pixelRatio: MediaQuery.devicePixelRatioOf(context),
      ),
      _RenderPath.fallback => PresenceFallbackPainter(
        frame: _frame,
        accent: widget.accent,
        compact: widget.compact,
      ),
      _RenderPath.loading => _BackgroundPainter(compact: widget.compact),
    };
    final paint = RepaintBoundary(
      child: CustomPaint(painter: painter, isComplex: true, willChange: true),
    );
    if (widget.compact) {
      return SizedBox.square(dimension: widget.compactSize, child: paint);
    }
    return SizedBox.expand(child: paint);
  }
}

class _ShaderPainter extends CustomPainter {
  _ShaderPainter({
    required this.frame,
    required this.shader,
    required this.accent,
    required this.compact,
    required this.pixelRatio,
  }) : super(repaint: frame);

  /// Number of float uniforms in shaders/presence.frag.
  static const int floatCount = 64;

  final PresenceFrame frame;
  final ui.FragmentShader shader;
  final Color accent;
  final bool compact;
  final double pixelRatio;

  final Paint _paint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    if (!compact) {
      canvas.drawRect(Offset.zero & size, Paint()..color = kPresenceBackground);
    }
    // Only the square around the orb runs the shader.
    final rect = PresenceView.orbRect(size, compact: compact);
    final b = frame.bands;
    final s = frame.state;
    final accent = frame.tint(this.accent);
    final accent2 = frame.tint2;
    var i = 0;
    void put(double v) => shader.setFloat(i++, v);
    put(frame.time);
    put(rect.left);
    put(rect.top);
    put(rect.width);
    put(pixelRatio);
    put(frame.level);
    for (var n = 0; n < 8; n++) {
      put(b[n]);
    }
    for (var n = 0; n < 4; n++) {
      put(s[n]);
    }
    put(accent.r);
    put(accent.g);
    put(accent.b);
    put(accent2.r);
    put(accent2.g);
    put(accent2.b);
    put(frame.spin);
    put(frame.activity);
    put(compact ? 1 : 0);
    for (var n = 0; n < 9; n++) {
      put(frame.rotation[n]);
    }
    for (var r = 0; r < PresenceFrame.ringCount; r++) {
      for (var n = 0; n < 4; n++) {
        put(frame.ringInverse[r * 4 + n]);
      }
      // Depth of a point of the plane: the z of its two basis vectors.
      put(frame.ringBasis[r * 6 + 2]);
      put(frame.ringBasis[r * 6 + 5]);
    }
    for (var n = 0; n < 4; n++) {
      put(frame.hudInverse[n]);
    }
    for (var n = 0; n < PresenceFrame.ringCount; n++) {
      put(frame.work[n]);
    }
    for (var n = 0; n < PresenceFrame.ringCount; n++) {
      put(frame.done[n]);
    }
    assert(i == floatCount);
    canvas.drawRect(rect, _paint..shader = shader);
  }

  @override
  bool shouldRepaint(_ShaderPainter old) =>
      old.shader != shader ||
      old.accent != accent ||
      old.compact != compact ||
      old.pixelRatio != pixelRatio ||
      old.frame != frame;
}

class _BackgroundPainter extends CustomPainter {
  const _BackgroundPainter({required this.compact});

  final bool compact;

  @override
  void paint(Canvas canvas, Size size) {
    if (compact) return;
    canvas.drawRect(Offset.zero & size, Paint()..color = kPresenceBackground);
  }

  @override
  bool shouldRepaint(_BackgroundPainter old) => old.compact != compact;
}
