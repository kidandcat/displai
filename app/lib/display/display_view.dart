/// The display widget: current view (a genui surface) with header and
/// transitions.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:genui/genui.dart';

import 'display_controller.dart';
import 'theme.dart';

/// Fills its parent with the current display view. Transparent while the
/// controller [DisplayController.isEmpty] (so an idle animation behind it
/// shows through).
class DisplayView extends StatelessWidget {
  const DisplayView({
    super.key,
    required this.controller,
    this.cornerReserve = Size.zero,
    this.scale,
  });

  final DisplayController controller;

  /// Area in the top-right corner, from the edges, covered by something on top of the
  /// display (the orb). The view's header leaves it free.
  final Size cornerReserve;

  /// The display's scale ([DisplayScale]); null: from the width.
  final double? scale;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final double s = scale ?? DisplayScale.forWidth(width);
        return Theme(
          data: displayThemeData(),
          child: DisplayScale(
            s: s,
            child: DisplayScope(
              runtime: controller,
              child: Material(
                type: MaterialType.transparency,
                child: DefaultTextStyle(
                  style: DisplayText(s).body,
                  child: ListenableBuilder(
                    listenable: controller,
                    builder: (context, _) => _build(context, s),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _build(BuildContext context, double s) {
    final DisplayViewEntry? entry = controller.current;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: entry == null
          ? const BoxDecoration()
          : const BoxDecoration(
              color: DisplayColors.background,
              gradient: RadialGradient(
                center: Alignment(-0.85, -1.0),
                radius: 1.6,
                colors: [Color(0xFF150F1F), DisplayColors.background],
              ),
            ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 320),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.025),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: entry == null
            ? const SizedBox.expand(key: ValueKey('display-empty'))
            : _ViewPage(
                key: ValueKey('view-${entry.seq}'),
                entry: entry,
                controller: controller,
                cornerReserve: cornerReserve,
              ),
      ),
    );
  }
}

/// Routes A2UI user actions to the controller.
class _ActionDelegate implements ActionDelegate {
  const _ActionDelegate(this.controller);

  final DisplayController controller;

  @override
  bool handleEvent(
    BuildContext context,
    UiEvent event,
    SurfaceContext genUiContext,
    Widget Function(SurfaceDefinition, Catalog, String, DataContext)
    buildWidget,
  ) {
    if (event is! UserActionEvent) return false;
    controller.handleAction(
      genUiContext.surfaceId,
      event.sourceComponentId,
      event.name,
      event.context,
    );
    return true;
  }
}

/// One view. It never scrolls: content that does not fit is cut (with a fade at the bottom),
/// and the overflow is reported to the controller so the model learns to show less.
class _ViewPage extends StatefulWidget {
  const _ViewPage({
    super.key,
    required this.entry,
    required this.controller,
    required this.cornerReserve,
  });

  final DisplayViewEntry entry;
  final DisplayController controller;
  final Size cornerReserve;

  @override
  State<_ViewPage> createState() => _ViewPageState();
}

class _ViewPageState extends State<_ViewPage> {
  final ScrollController _clip = ScrollController();
  bool _overflowing = false;

  DisplayViewEntry get entry => widget.entry;
  DisplayController get controller => widget.controller;

  void _measure() {
    if (!mounted || !_clip.hasClients || !_clip.position.hasContentDimensions) {
      return;
    }
    final double px = _clip.position.maxScrollExtent;
    // The outgoing page of a transition is still laid out; only the current one reports.
    if (controller.current?.seq == entry.seq) controller.reportOverflow(px);
    if ((px > 0) != _overflowing) setState(() => _overflowing = px > 0);
  }

  @override
  void dispose() {
    _clip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    final Widget surface = Surface(
      key: ValueKey('surface-${entry.surfaceId}'),
      surfaceContext: controller.surfaceContext(entry.surfaceId),
      actionDelegate: _ActionDelegate(controller),
    );
    if (entry.kind == 'video' || entry.edgeToEdge) return surface;

    final double s = DisplayScale.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final double hPad = (constraints.maxWidth * 0.045).clamp(
          28 * s,
          120 * s,
        );
        // Keep the header clear of whatever sits in the top-right corner (the orb): the title
        // wraps before it, and the body starts below it.
        final double rightGap =
            hPad +
            math.max(0, (constraints.maxWidth - 2 * hPad - 1560 * s) / 2);
        final Size reserve = widget.cornerReserve;
        final Widget header = Padding(
          padding: EdgeInsets.only(
            right: math.max(0, reserve.width - rightGap),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: math.max(0, reserve.height - 44 * s - 34 * s),
            ),
            child: _Header(entry: entry),
          ),
        );
        // A form gets the page's height and scrolls its own fields, so its submit button is
        // always visible; nothing is cut. A custom page fills it too.
        if (entry.kind == 'form' || entry.kind == 'html') {
          return Padding(
            padding: EdgeInsets.fromLTRB(hPad, 44 * s, hPad, 32 * s),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 1560 * s),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header,
                    SizedBox(height: 34 * s),
                    Expanded(child: surface),
                  ],
                ),
              ),
            ),
          );
        }
        final Widget page = SingleChildScrollView(
          controller: _clip,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(hPad, 44 * s, hPad, 48 * s),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 1560 * s),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  SizedBox(height: 34 * s),
                  surface,
                ],
              ),
            ),
          ),
        );
        if (!_overflowing) return page;
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white, Colors.white, Colors.transparent],
            stops: [0, 0.9, 1],
          ).createShader(rect),
          child: page,
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.entry});

  final DisplayViewEntry entry;

  @override
  Widget build(BuildContext context) {
    final t = DisplayText.of(context);
    final double s = t.s;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72 * s,
          height: 3 * s,
          child: entry.partial
              ? LinearProgressIndicator(
                  minHeight: 3 * s,
                  color: DisplayColors.accent,
                  backgroundColor: DisplayColors.border,
                )
              : const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        DisplayColors.accent,
                        DisplayColors.accentSecondary,
                      ],
                    ),
                  ),
                ),
        ),
        SizedBox(height: 18 * s),
        if (entry.title.isNotEmpty)
          Text(entry.title, style: t.title)
        else
          SizedBox(height: t.title.fontSize! * 1.15),
        if (entry.subtitle != null) ...[
          SizedBox(height: 10 * s),
          RichDisplayText(entry.subtitle!, style: t.subtitle),
        ],
      ],
    );
  }
}
