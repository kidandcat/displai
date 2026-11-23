/// The display widget: current view (a genui surface) with header,
/// transitions and the timeline strip.
library;

import 'package:flutter/material.dart';
import 'package:genui/genui.dart';

import 'display_controller.dart';
import 'theme.dart';

/// Fills its parent with the current display view. Transparent while the
/// controller [DisplayController.isEmpty] (so an idle animation behind it
/// shows through), except for the timeline strip.
class DisplayView extends StatelessWidget {
  const DisplayView({super.key, required this.controller});

  final DisplayController controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final double s = DisplayScale.forWidth(width);
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
    final List<DisplayViewEntry> timeline = controller.timeline;
    final bool showStrip =
        timeline.length > 1 || (entry == null && timeline.isNotEmpty);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: entry == null
          ? const BoxDecoration()
          : const BoxDecoration(
              color: DisplayColors.background,
              gradient: RadialGradient(
                center: Alignment(-0.85, -1.0),
                radius: 1.6,
                colors: [Color(0xFF0B1B21), DisplayColors.background],
              ),
            ),
      child: Column(
        children: [
          Expanded(
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
                    ),
            ),
          ),
          if (showStrip)
            _TimelineStrip(
              entries: timeline,
              current: controller.currentIndex,
              onSelect: controller.goTo,
            ),
        ],
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
  const _ViewPage({super.key, required this.entry, required this.controller});

  final DisplayViewEntry entry;
  final DisplayController controller;

  @override
  State<_ViewPage> createState() => _ViewPageState();
}

class _ViewPageState extends State<_ViewPage> {
  final ScrollController _clip = ScrollController();
  bool _overflowing = false;

  DisplayViewEntry get entry => widget.entry;
  DisplayController get controller => widget.controller;

  void _measure() {
    if (!mounted || !_clip.hasClients || !_clip.position.hasContentDimensions) return;
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
    if (entry.kind == 'video') return surface;

    final double s = DisplayScale.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final double hPad = (constraints.maxWidth * 0.045).clamp(
          28 * s,
          120 * s,
        );
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
                  _Header(entry: entry),
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
                      colors: [DisplayColors.accent, DisplayColors.accentTeal],
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

class _TimelineStrip extends StatefulWidget {
  const _TimelineStrip({
    required this.entries,
    required this.current,
    required this.onSelect,
  });

  final List<DisplayViewEntry> entries;
  final int current;
  final ValueChanged<int> onSelect;

  @override
  State<_TimelineStrip> createState() => _TimelineStripState();
}

class _TimelineStripState extends State<_TimelineStrip> {
  final ScrollController _scroll = ScrollController();

  @override
  void didUpdateWidget(_TimelineStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entries.length != widget.entries.length ||
        oldWidget.current != widget.current) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  void _reveal() {
    if (!mounted || !_scroll.hasClients) return;
    final ScrollPosition p = _scroll.position;
    // Keep the newest entries in sight; the strip is short anyway.
    if (widget.current < 0 || widget.current >= widget.entries.length - 3) {
      _scroll.animateTo(
        p.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  static IconData _icon(String kind) => switch (kind) {
    'form' => Icons.edit_note_rounded,
    'video' => Icons.play_circle_outline_rounded,
    _ => Icons.dashboard_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final double s = DisplayScale.of(context);
    return Container(
      height: 62 * s,
      decoration: const BoxDecoration(
        color: Color(0xE6030607),
        border: Border(top: BorderSide(color: DisplayColors.border)),
      ),
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: 24 * s, vertical: 11 * s),
        itemCount: widget.entries.length,
        separatorBuilder: (_, _) => SizedBox(width: 10 * s),
        itemBuilder: (context, i) {
          final DisplayViewEntry e = widget.entries[i];
          final bool active = i == widget.current;
          return Selectable(
            key: ValueKey('timeline-$i'),
            onTap: () => widget.onSelect(i),
            builder: (context, hover) => AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              constraints: BoxConstraints(maxWidth: 260 * s),
              padding: EdgeInsets.symmetric(horizontal: 14 * s),
              decoration: BoxDecoration(
                color: active
                    ? const Color(0x2622D3EE)
                    : hover
                    ? DisplayColors.surfaceHigh
                    : DisplayColors.surface,
                borderRadius: BorderRadius.circular(20 * s),
                border: Border.all(
                  color: active
                      ? DisplayColors.accent
                      : hover
                      ? DisplayColors.borderStrong
                      : DisplayColors.border,
                  width: active ? 1.5 : 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _icon(e.kind),
                    size: 17 * s,
                    color: active
                        ? DisplayColors.accent
                        : DisplayColors.textMuted,
                  ),
                  SizedBox(width: 8 * s),
                  Flexible(
                    child: Text(
                      e.title.isEmpty ? '…' : e.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15 * s,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                        color: active
                            ? DisplayColors.text
                            : DisplayColors.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
