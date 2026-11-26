import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../display/display.dart';
import '../presence/presence.dart';
import 'assistant.dart';
import 'desktop_window.dart';
import 'main_view.dart';

/// Everything Minerva draws on the desktop window, which covers the whole main screen,
/// transparent and click-through (macos/Runner/MainFlutterWindow.swift):
///   - the full view: a panel the user moves (by its top strip) and resizes (by its corner),
///     holding the app's navigator ([child]), so its dialogs and menus stay inside it;
///   - the orb in the top-right corner while the window is the overlay (tap: mute, or the full
///     view back when the user only went to another app; drag: move; right click: Minerva's menu);
///   - the widget Minerva pops over the other apps while it works in them: the view it showed
///     last, on its own dark panel.
/// Going to the orb, the panel closes around its own orb and flies with it to the corner; coming
/// back it does the reverse.
/// Only those take clicks: their rects go to the native side, which lets the rest through.
class OverlayShell extends StatefulWidget {
  const OverlayShell({super.key, required this.window, required this.assistant, required this.child});

  final DesktopWindow window;
  final ValueListenable<Assistant?> assistant;
  final Widget child;

  @override
  State<OverlayShell> createState() => _OverlayShellState();
}

class _OverlayShellState extends State<OverlayShell> with SingleTickerProviderStateMixin {
  /// Height of the panel's top strip (drag it to move the panel; it holds the close button).
  static const double _bar = 30;
  static const double _orbSize = 122;
  static const double _margin = 24;
  static const Size _minPanel = Size(480, 360);

  /// Height of the full view's status bar (main_view.dart's [StatusBar]).
  static const double _statusBar = 52;

  /// The panel's way to the orb and back: 0 is the panel, 1 the orb.
  late final _morph = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))
    ..addStatusListener((s) => _window.panelShown.value = s != AnimationStatus.completed);

  /// The window's last overlay state.
  bool? _overlay;

  DesktopWindow get _window => widget.window;

  /// The panel while the user moves or resizes it.
  Rect? _panel;

  /// The orb while the user drags it.
  Offset? _orb;

  /// How far the user dragged the widget of [_widgetSeq].
  Offset _widgetShift = Offset.zero;
  int? _widgetSeq;

  List<Rect> _sentRects = const [];

  @override
  void initState() {
    super.initState();
    _window.addListener(_onWindow);
    _onWindow();
  }

  @override
  void dispose() {
    _window.removeListener(_onWindow);
    _morph.dispose();
    super.dispose();
  }

  /// Morphs the panel into the orb and back when the window goes to the overlay and back; it
  /// jumps when there is no panel on screen to morph.
  void _onWindow() {
    final overlay = _window.overlay, was = _overlay;
    _overlay = overlay;
    if (overlay == was) return;
    if (was == null || !_window.open) {
      _morph.value = overlay ? 1 : 0;
    } else if (overlay) {
      unawaited(_morph.forward());
    } else {
      unawaited(_morph.reverse());
    }
    _window.panelShown.value = _morph.status != AnimationStatus.completed;
  }

  /// Sends the clickable rects to the native side when they change (after the frame that drew
  /// them).
  void _report(List<Rect> rects) {
    if (listEquals(rects, _sentRects)) return;
    _sentRects = rects;
    SchedulerBinding.instance.addPostFrameCallback((_) => unawaited(_window.setHitRects(rects)));
  }

  static Rect _fit(Rect r, Rect area) {
    final w = math.min(r.width, area.width), h = math.min(r.height, area.height);
    return Rect.fromLTWH(
      r.left.clamp(area.left, area.right - w).toDouble(),
      r.top.clamp(area.top, area.bottom - h).toDouble(),
      w,
      h,
    );
  }

  Rect _panelRect(Rect usable) {
    final r = _panel ??
        _window.panel ??
        Rect.fromCenter(
          center: usable.center,
          width: math.min(1100, usable.width - 80),
          height: math.min(760, usable.height - 80),
        );
    return _fit(r, usable);
  }

  Rect _orbRect(Rect usable, Rect screen) {
    final p = _orb ?? _window.orb ?? Offset(usable.right - _margin - _orbSize, usable.top + _margin);
    return _fit(p & const Size.square(_orbSize), screen);
  }

  /// The orb inside the panel, as the circle the panel closes around: the full orb in the middle,
  /// or the big corner orb while something is on screen (main_view.dart). Its shell's radius is
  /// [r]: the visible orb reaches twice that (shaders/presence.frag).
  static ({Offset c, double r}) _panelOrb(Rect panel, bool showing) {
    final area = Rect.fromLTRB(panel.left, panel.top + _bar, panel.right, panel.bottom - _statusBar);
    if (!showing) return (c: area.center, r: 0.19 * PresenceView.fullExtent * area.shortestSide);
    const size = 180.0;
    return (c: Offset(area.right - 12 - size / 2, area.top + 12 + size / 2), r: 0.25 * size);
  }

  /// Where the widget goes for the tools' `at`.
  Rect _widgetRect(String at, Rect usable, Rect screen) {
    final center = at == 'center';
    final w = center
        ? math.min(usable.width * 0.6, 1100.0)
        : (usable.width * 0.32).clamp(440.0, 640.0).toDouble();
    final h = center
        ? math.min(usable.height * 0.72, 800.0)
        : (usable.height * 0.5).clamp(360.0, 620.0).toDouble();
    final left = usable.left + _margin, right = usable.right - _margin - w;
    final top = usable.top + _margin, bottom = usable.bottom - _margin - h;
    final middle = usable.center.dy - h / 2;
    final origin = switch (at) {
      'top-left' => Offset(left, top),
      'bottom-right' => Offset(right, bottom),
      'bottom-left' => Offset(left, bottom),
      'left' => Offset(left, middle),
      'right' => Offset(right, middle),
      'center' => Offset(usable.center.dx - w / 2, middle),
      // Under the orb.
      _ => Offset(right, top + _orbSize + 12),
    };
    return _fit((origin + _widgetShift) & Size(w, h), screen);
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Assistant?>(
        valueListenable: widget.assistant,
        builder: (context, a, _) => ListenableBuilder(
          listenable: Listenable.merge([_window, _window.panelShown, _morph, ?a, a?.display]),
          builder: (context, _) => _build(context, a),
        ),
      );

  Widget _build(BuildContext context, Assistant? a) {
    final mq = MediaQuery.of(context);
    final screen = Offset.zero & mq.size;
    final usable = _window.insets.deflateRect(screen);
    final orbMode = _window.overlay;
    final panel = _panelRect(usable);
    final orb = _orbRect(usable, screen);
    final t = _morph.value;
    final view = orbMode && !_window.panelShown.value ? a?.widgetView : null;
    if (view?.seq != _widgetSeq) {
      _widgetSeq = view?.seq;
      _widgetShift = Offset.zero;
    }
    final widgetRect = view == null ? null : _widgetRect(a!.widgetAt, usable, screen);
    // Nothing takes clicks halfway.
    _report([
      if (t == 0 && !orbMode && _window.open) panel,
      if (t == 1 && orbMode && a != null) orb,
      ?widgetRect,
    ]);
    // The morph: the panel's clip closes from its rounded rect to a circle around its orb (shape),
    // then the panel flies so that orb lands on the corner orb (flight), and fades into it.
    final shape = Curves.easeInOutCubic.transform(const Interval(0, 0.55).transform(t));
    final flight = Curves.easeInOutCubic.transform(const Interval(0.3, 1).transform(t));
    final from = _panelOrb(panel, a != null && !a.display.isEmpty);
    final local = from.c - panel.topLeft;
    final scale = 1 + (_orbSize / 4 / from.r - 1) * flight;
    final to = Offset.lerp(local, orb.center - panel.topLeft, flight)!;
    final clip = RRect.lerp(
      RRect.fromRectAndRadius(Offset.zero & panel.size, const Radius.circular(12)),
      RRect.fromRectAndRadius(Rect.fromCircle(center: local, radius: 2 * from.r), Radius.circular(2 * from.r)),
      shape,
    )!;
    // The shell sits above the navigator (MaterialApp.builder), so nothing gives its texts a
    // Material: this one does, with the theme's text style.
    return TickerMode(
      enabled: _window.open || orbMode,
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            Positioned.fromRect(
              rect: panel,
              child: Offstage(
                offstage: t == 1,
                child: TickerMode(
                  enabled: t < 1,
                  child: Opacity(
                    opacity: 1 - const Interval(0.8, 1).transform(t),
                    child: Transform(
                      transform: Matrix4.translationValues(to.dx, to.dy, 0)
                        ..multiply(Matrix4.diagonal3Values(scale, scale, 1))
                        ..multiply(Matrix4.translationValues(-local.dx, -local.dy, 0)),
                      child: ClipRRect(
                        clipper: _RRectClip(clip),
                        // Still, the panel's shadow shows.
                        clipBehavior: t == 0 ? Clip.none : Clip.antiAlias,
                        child: _Panel(
                          onMove: (d) => setState(() => _panel = _fit(panel.shift(d), usable)),
                          onResize: (d) => setState(() => _panel = _fit(
                                Rect.fromLTWH(
                                  panel.left,
                                  panel.top,
                                  math.max(_minPanel.width, panel.width + d.dx),
                                  math.max(_minPanel.height, panel.height + d.dy),
                                ),
                                usable,
                              )),
                          onDone: () {
                            final p = _panel;
                            if (p != null) _window.setPanel(p);
                          },
                          onClose: () => unawaited(_window.hide()),
                          child: MediaQuery(
                            data: mq.copyWith(
                              size: Size(panel.width, panel.height - _bar),
                              padding: EdgeInsets.zero,
                              viewPadding: EdgeInsets.zero,
                              viewInsets: EdgeInsets.zero,
                            ),
                            child: widget.child,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (widgetRect != null)
              Positioned.fromRect(
                rect: widgetRect,
                child: _Widget(
                  assistant: a!,
                  onMove: (d) => setState(() => _widgetShift += d),
                ),
              ),
            if (t > 0 && a != null)
              Positioned.fromRect(
                rect: orb,
                child: Opacity(
                  opacity: const Interval(0.75, 1).transform(t),
                  child: _Orb(
                    presence: a.presence,
                    onTap: _window.reason == 'away' ? () => unawaited(_window.show()) : a.toggleMute,
                    onMove: (d) => setState(() => _orb = _fit(orb.shift(d), screen).topLeft),
                    onDone: () {
                      final o = _orb;
                      if (o != null) _window.setOrb(o);
                    },
                    onMenu: () => unawaited(_window.contextMenu()),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The full view: a dark panel with a strip on top to move it and close it, and a grip in the
/// bottom-right corner to resize it.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.onMove,
    required this.onResize,
    required this.onDone,
    required this.onClose,
    required this.child,
  });

  final ValueChanged<Offset> onMove;
  final ValueChanged<Offset> onResize;
  final VoidCallback onDone;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: kBackground,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0x33A87CFF)),
          boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 30, offset: Offset(0, 10))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            children: [
              Column(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (d) => onMove(d.delta),
                    onPanEnd: (_) => onDone(),
                    child: SizedBox(
                      height: _OverlayShellState._bar,
                      child: Row(
                        children: [
                          const SizedBox(width: 10),
                          _CloseButton(onTap: onClose),
                          const Spacer(),
                          Text('Minerva',
                              style: TextStyle(
                                  fontSize: 12, letterSpacing: 2, color: kAccent.withValues(alpha: 0.6))),
                          const Spacer(),
                          const SizedBox(width: 32),
                        ],
                      ),
                    ),
                  ),
                  Expanded(child: child),
                ],
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeUpLeftDownRight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (d) => onResize(d.delta),
                    onPanEnd: (_) => onDone(),
                    child: const SizedBox.square(
                      dimension: 18,
                      child: CustomPaint(painter: _GripPainter()),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

class _CloseButton extends StatefulWidget {
  const _CloseButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _hover ? const Color(0x33FFFFFF) : Colors.transparent,
            ),
            child: Icon(Icons.close, size: 13, color: _hover ? Colors.white : Colors.white38),
          ),
        ),
      );
}

class _RRectClip extends CustomClipper<RRect> {
  const _RRectClip(this.rrect);

  final RRect rrect;

  @override
  RRect getClip(Size size) => rrect;

  @override
  bool shouldReclip(_RRectClip old) => old.rrect != rrect;
}

class _GripPainter extends CustomPainter {
  const _GripPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1.2;
    for (final k in [5.0, 9.0, 13.0]) {
      canvas.drawLine(Offset(size.width - 3, size.height - 3 - k + 3), Offset(size.width - 3 - k + 3, size.height - 3), p);
    }
  }

  @override
  bool shouldRepaint(_GripPainter old) => false;
}

/// The orb over the other apps, with nothing around it: the small orb's alpha follows its light
/// (shaders/presence.frag), so it shows on the window's transparent pixels and over light apps.
class _Orb extends StatelessWidget {
  const _Orb({
    required this.presence,
    required this.onTap,
    required this.onMove,
    required this.onDone,
    required this.onMenu,
  });

  final PresenceSignal presence;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMove;
  final VoidCallback onDone;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          onPanUpdate: (d) => onMove(d.delta),
          onPanEnd: (_) => onDone(),
          onSecondaryTap: onMenu,
          child: ClipOval(
            child: PresenceView(signal: presence, compact: true, compactSize: _OverlayShellState._orbSize),
          ),
        ),
      );
}

/// A view Minerva popped over the other apps: the display on its own dark panel, with a strip
/// to move it and close it.
class _Widget extends StatelessWidget {
  const _Widget({required this.assistant, required this.onMove});

  final Assistant assistant;
  final ValueChanged<Offset> onMove;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: DisplayColors.background,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x40A87CFF)),
          boxShadow: const [BoxShadow(color: Color(0xB3000000), blurRadius: 28, offset: Offset(0, 8))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Column(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) => onMove(d.delta),
                child: SizedBox(
                  height: 26,
                  child: Row(
                    children: [
                      const SizedBox(width: 8),
                      _CloseButton(onTap: assistant.closeWidget),
                      const Spacer(),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) => RepaintBoundary(
                    key: assistant.screenKey,
                    child: DisplayView(
                      controller: assistant.display,
                      scale: (box.maxWidth / 900).clamp(0.55, 0.8).toDouble(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
