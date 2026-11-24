/// Look of the display: colors, scale-aware text styles, ordinal badges,
/// a tiny inline-markdown renderer and the scope that catalog widgets use to
/// reach the runtime.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Palette: near-black, violet/fuchsia accent.
abstract final class DisplayColors {
  static const Color background = Color(0xFF06040A);
  static const Color surface = Color(0xFF110D17);
  static const Color surfaceHigh = Color(0xFF181220);
  static const Color border = Color(0x2EA78BFA);
  static const Color borderStrong = Color(0x8CA78BFA);
  static const Color accent = Color(0xFFA78BFA);
  static const Color accentSecondary = Color(0xFFE879F9);
  static const Color accentDim = Color(0xFF6D28D9);
  static const Color text = Color(0xFFF1EDF7);
  static const Color textMuted = Color(0xFFA79DB3);
  static const Color textFaint = Color(0xFF6E6579);
  static const Color positive = Color(0xFF34D399);
  static const Color negative = Color(0xFFF87171);
}

/// UI strings of the display chrome (content strings come from the model).
abstract final class DisplayStrings {
  static String submit = 'Enviar';
  static String submitted = 'Enviado';
  static String required = 'Obligatorio';
  static String pickDate = 'Elegir fecha';
  static String videoError = 'No se puede reproducir el vídeo';
  static String yes = 'Sí';
  static String no = 'No';
}

/// Scale factor for a screen seen from a distance: 1.0 at 1440 px wide,
/// growing on large monitors.
class DisplayScale extends InheritedWidget {
  const DisplayScale({super.key, required this.s, required super.child});

  final double s;

  static double forWidth(double width) =>
      (width / 1440).clamp(0.8, 2.0).toDouble();

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DisplayScale>()?.s ?? 1.0;

  @override
  bool updateShouldNotify(DisplayScale oldWidget) => oldWidget.s != s;
}

/// Text styles scaled by [DisplayScale].
class DisplayText {
  DisplayText(this.s);

  factory DisplayText.of(BuildContext context) =>
      DisplayText(DisplayScale.of(context));

  final double s;

  /// Font family of the display text; null is the platform's font. Tests that render the display
  /// to images set a real font here (the test font has no glyphs).
  static String? family;

  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  TextStyle get title => TextStyle(
    fontFamily: family,
    fontSize: 46 * s,
    fontWeight: FontWeight.w300,
    color: DisplayColors.text,
    letterSpacing: -0.5,
    height: 1.15,
  );
  TextStyle get subtitle => TextStyle(
    fontFamily: family,
    fontSize: 22 * s,
    color: DisplayColors.textMuted,
    height: 1.4,
  );
  TextStyle get heading => TextStyle(
    fontFamily: family,
    fontSize: 32 * s,
    fontWeight: FontWeight.w500,
    color: DisplayColors.text,
    height: 1.25,
  );
  TextStyle get headingSmall => TextStyle(
    fontFamily: family,
    fontSize: 26 * s,
    fontWeight: FontWeight.w500,
    color: DisplayColors.text,
    height: 1.25,
  );
  TextStyle get body => TextStyle(
    fontFamily: family,
    fontSize: 22 * s,
    color: DisplayColors.text,
    height: 1.5,
  );
  TextStyle get bodyMuted => TextStyle(
    fontFamily: family,
    fontSize: 19 * s,
    color: DisplayColors.textMuted,
    height: 1.45,
  );
  TextStyle get cardTitle => TextStyle(
    fontFamily: family,
    fontSize: 24 * s,
    fontWeight: FontWeight.w600,
    color: DisplayColors.text,
    height: 1.25,
  );
  TextStyle get label => TextStyle(
    fontFamily: family,
    fontSize: 15 * s,
    fontWeight: FontWeight.w600,
    color: DisplayColors.textMuted,
    letterSpacing: 1.2,
  );
  TextStyle get value => TextStyle(
    fontFamily: family,
    fontSize: 22 * s,
    fontWeight: FontWeight.w600,
    color: DisplayColors.accent,
    fontFeatures: _tabular,
  );
  TextStyle get statValue => TextStyle(
    fontFamily: family,
    fontSize: 52 * s,
    fontWeight: FontWeight.w300,
    color: DisplayColors.text,
    fontFeatures: _tabular,
    height: 1.1,
  );
  TextStyle get cell => TextStyle(
    fontFamily: family,
    fontSize: 21 * s,
    color: DisplayColors.text,
    fontFeatures: _tabular,
    height: 1.35,
  );
}

/// Small numbered badge shown on every selectable item.
class OrdinalBadge extends StatelessWidget {
  const OrdinalBadge(
    this.number, {
    super.key,
    this.filled = false,
    this.solid = false,
  });

  final int number;
  final bool filled;

  /// An opaque dark backdrop, for badges drawn over images.
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final double s = DisplayScale.of(context);
    final double size = 30 * s;
    return Container(
      constraints: BoxConstraints(minWidth: size, minHeight: size),
      padding: EdgeInsets.symmetric(horizontal: 6 * s),
      decoration: BoxDecoration(
        color: filled
            ? DisplayColors.accent
            : solid
            ? const Color(0xE6120E1A)
            : const Color(0x1AA78BFA),
        borderRadius: BorderRadius.circular(size / 2),
        border: Border.all(color: DisplayColors.borderStrong, width: 1.2),
      ),
      // Shrink-wrapped: never stretch to the parent's width.
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Text(
          '$number',
          style: TextStyle(
            fontFamily: DisplayText.family,
            fontSize: 15 * s,
            fontWeight: FontWeight.w700,
            color: filled ? DisplayColors.background : DisplayColors.accent,
            fontFeatures: const [FontFeature.tabularFigures()],
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// Renders `**bold**`, `*italic*` / `_italic_` and `` `code` `` inline.
class RichDisplayText extends StatelessWidget {
  const RichDisplayText(
    this.text, {
    super.key,
    required this.style,
    this.textAlign,
    this.maxLines,
  });

  final String text;
  final TextStyle style;
  final TextAlign? textAlign;
  final int? maxLines;

  static final RegExp _token = RegExp(
    r'\*\*(.+?)\*\*|`([^`]+)`|\*([^*\s][^*]*?)\*|(?<![\w])_([^_\s][^_]*?)_(?![\w])',
  );

  static List<InlineSpan> spans(String text, TextStyle style) {
    final spans = <InlineSpan>[];
    var last = 0;
    for (final RegExpMatch m in _token.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      if (m.group(1) != null) {
        spans.add(
          TextSpan(
            text: m.group(1),
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: Color(0xFFFFFFFF),
            ),
          ),
        );
      } else if (m.group(2) != null) {
        spans.add(
          TextSpan(
            text: m.group(2),
            style: TextStyle(
              fontFamily: 'Menlo',
              fontSize: (style.fontSize ?? 20) * 0.9,
              color: DisplayColors.accentSecondary,
              backgroundColor: const Color(0x1AE879F9),
            ),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: m.group(3) ?? m.group(4),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      }
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(style: style, children: spans(text, style)),
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}

/// Command sent by the model to the current video.
@immutable
class VideoCommand {
  const VideoCommand(this.seq, {this.play, this.seekSeconds});

  final int seq;
  final bool? play;
  final double? seekSeconds;
}

/// Playback status reported by a video widget (for get_state).
@immutable
class VideoStatus {
  const VideoStatus({
    required this.playing,
    required this.position,
    required this.duration,
    this.error,
  });

  final bool playing;
  final Duration position;
  final Duration duration;
  final String? error;
}

/// Status of a custom HTML page (for get_state and the tool results): reported by the page
/// widget as it loads, fails and calls `minerva.state`.
class HtmlStatus {
  HtmlStatus({required this.html});

  /// The HTML this status belongs to.
  final String html;
  bool loaded = false;
  final List<String> errors = [];

  /// The last `minerva.state(...)` of the page.
  String? state;

  /// Size of the document and of the page's viewport, in CSS pixels, once loaded.
  Size? content;
  Size? viewport;
}

/// What catalog widgets need from the display runtime.
abstract interface class DisplayRuntime {
  ValueListenable<VideoCommand?> get videoCommands;
  void reportVideo(String componentId, VideoStatus status);
  void reportHtml(String componentId, HtmlStatus status);
}

/// Gives catalog widgets access to the [DisplayRuntime].
class DisplayScope extends InheritedWidget {
  const DisplayScope({super.key, required this.runtime, required super.child});

  final DisplayRuntime runtime;

  static DisplayRuntime? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DisplayScope>()?.runtime;

  @override
  bool updateShouldNotify(DisplayScope oldWidget) =>
      oldWidget.runtime != runtime;
}

/// Standard rounded panel used by cards, tables and tiles.
BoxDecoration panelDecoration(double s, {bool highlight = false}) =>
    BoxDecoration(
      color: highlight ? DisplayColors.surfaceHigh : DisplayColors.surface,
      borderRadius: BorderRadius.circular(18 * s),
      border: Border.all(
        color: highlight ? DisplayColors.borderStrong : DisplayColors.border,
        width: 1.2,
      ),
    );

/// Dark Material theme used inside the display (form inputs, pickers).
ThemeData displayThemeData() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: const ColorScheme.dark(
      primary: DisplayColors.accent,
      onPrimary: DisplayColors.background,
      secondary: DisplayColors.accentSecondary,
      surface: DisplayColors.surface,
      onSurface: DisplayColors.text,
    ),
    scaffoldBackgroundColor: DisplayColors.background,
  );
  return base.copyWith(
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: DisplayColors.accent,
      inactiveTrackColor: DisplayColors.border,
      thumbColor: DisplayColors.accent,
    ),
  );
}

/// Hover/press feedback for selectable items.
class Selectable extends StatefulWidget {
  const Selectable({super.key, required this.onTap, required this.builder});

  final VoidCallback onTap;
  final Widget Function(BuildContext context, bool hover) builder;

  @override
  State<Selectable> createState() => _SelectableState();
}

class _SelectableState extends State<Selectable> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: widget.builder(context, _hover),
      ),
    );
  }
}
