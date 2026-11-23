import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'presence_fallback_painter.dart';
import 'presence_signal.dart';

/// Default HUD accent: violet.
const Color kPresenceAccent = Color(0xFFA87CFF);

/// Accent the presence fades to while the microphone is muted.
const Color kPresenceMutedAccent = Color(0xFFFF2A2A);

/// Near-black background used behind the full-window presence.
const Color kPresenceBackground = Color(0xFF040206);

/// Per-frame values shared by the shader and fallback painters.
class PresenceFrame extends ChangeNotifier {
  double time = 0;
  double spin = 0;
  double level = 0;
  double activity = 0;
  final Float32List bands = Float32List(PresenceSignal.bandCount);

  /// Cross-fade weights for idle, listening, thinking, speaking (sum = 1).
  final Float32List state = Float32List(4)..[0] = 1;

  /// Mute blend, 0 (normal accent) .. 1 (muted red), eased over time.
  double muted = 0;

  /// [accent] blended toward [kPresenceMutedAccent] by [muted].
  Color tint(Color accent) =>
      muted <= 0 ? accent : Color.lerp(accent, kPresenceMutedAccent, muted)!;

  void markDirty() => notifyListeners();
}

/// The app's "face": a full-window audio-reactive HUD animation, or a small
/// orb when [compact] is true. Driven by [signal].
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

class _PresenceViewState extends State<PresenceView>
    with SingleTickerProviderStateMixin {
  // Seconds for a state cross-fade to get ~63% of the way.
  static const double _fadeTau = 0.28;

  // Seconds for the muted color fade to get ~63% of the way.
  static const double _muteTau = 0.3;

  final PresenceFrame _frame = PresenceFrame();
  late final Ticker _ticker;
  Duration _lastElapsed = Duration.zero;
  ui.FragmentShader? _shader;
  _RenderPath _path = _RenderPath.loading;

  @override
  void initState() {
    super.initState();
    _frame.state
      ..fillRange(0, 4, 0)
      ..[widget.signal.mode.index] = 1;
    _frame.muted = widget.signal.muted ? 1 : 0;
    _ticker = createTicker(_onTick)..start();
    _load();
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

  void _onTick(Duration elapsed) {
    final dt = math.min((elapsed - _lastElapsed).inMicroseconds / 1e6, 0.1);
    _lastElapsed = elapsed;
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
      ..time = elapsed.inMicroseconds / 1e6
      ..level = signal.level
      ..activity = signal.activity
      // Integrated rotation phase: speeding up never makes the rings jump.
      ..spin +=
          dt *
          // Resting (idle, or listening in silence) turns slowly; voice, thinking and speaking
          // make the rings spin and orbit visibly faster.
          // Roughly 8x at rest -> speaking and 12x at rest -> thinking.
          (1.0 +
              0.3 * w[1] +
              8.0 * w[3] +
              12.0 * w[2] +
              4.0 * w[2] * signal.activity +
              6.0 * react * signal.level);
    _frame.bands.setAll(0, signal.bands);
    _frame.markDirty();
  }

  @override
  void dispose() {
    _ticker.dispose();
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
  }) : super(repaint: frame);

  /// Number of float uniforms in shaders/presence.frag.
  static const int floatCount = 22;

  final PresenceFrame frame;
  final ui.FragmentShader shader;
  final Color accent;
  final bool compact;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final b = frame.bands;
    final s = frame.state;
    final accent = frame.tint(this.accent);
    shader
      ..setFloat(0, frame.time)
      ..setFloat(1, size.width)
      ..setFloat(2, size.height)
      ..setFloat(3, frame.level)
      ..setFloat(4, b[0])
      ..setFloat(5, b[1])
      ..setFloat(6, b[2])
      ..setFloat(7, b[3])
      ..setFloat(8, b[4])
      ..setFloat(9, b[5])
      ..setFloat(10, b[6])
      ..setFloat(11, b[7])
      ..setFloat(12, s[0])
      ..setFloat(13, s[1])
      ..setFloat(14, s[2])
      ..setFloat(15, s[3])
      ..setFloat(16, accent.r)
      ..setFloat(17, accent.g)
      ..setFloat(18, accent.b)
      ..setFloat(19, frame.spin)
      ..setFloat(20, frame.activity)
      ..setFloat(21, compact ? 1 : 0);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_ShaderPainter old) =>
      old.shader != shader ||
      old.accent != accent ||
      old.compact != compact ||
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
