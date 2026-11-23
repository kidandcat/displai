/// genui catalog of DisplAI's high-level components (A2UI custom catalog).
///
/// Each [CatalogItem] renders one node type of our compact tool schema with
/// the display's dark theme. Selectable items show ordinal badges and report
/// taps through `dispatchEvent` as A2UI user actions.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import 'form_widgets.dart';
import 'theme.dart';
import 'video_widgets.dart';
import 'view_model.dart';

const String displayCatalogId = 'https://displai.dev/catalogs/display_v0.json';

typedef _Json = Map<String, Object?>;

/// User action names dispatched by catalog widgets.
abstract final class DisplayActions {
  static const String tap = 'tap';
  static const String press = 'press';
  static const String submit = 'submit';
}

void _dispatch(CatalogItemContext ctx, String name, [int index = 0]) {
  ctx.dispatchEvent(
    UserActionEvent(
      name: name,
      sourceComponentId: ctx.id,
      context: {'index': index},
    ),
  );
}

Schema _schema(String description, List<String> props) => S.object(
  description: description,
  properties: {for (final p in props) p: S.any()},
);

CatalogItem _item(
  String type,
  String description,
  List<String> props,
  Widget Function(CatalogItemContext ctx, _Json data) build,
) {
  return CatalogItem(
    name: catalogNames[type]!,
    dataSchema: _schema(description, props),
    widgetBuilder: (ctx) => build(ctx, ctx.data as _Json),
  );
}

/// The catalog used by every display surface.
final Catalog displayCatalog = Catalog([
  _item('heading', 'Section heading.', ['text', 'level'], _heading),
  _item('text', 'Paragraph with inline emphasis.', ['text'], _text),
  _item('cards', 'Selectable cards.', ['items', 'layout', 'ord'], _cards),
  _item('table', 'Table with selectable rows.', [
    'columns',
    'rows',
    'ord',
  ], _table),
  _item('stats', 'Stat tiles.', ['items'], _stats),
  _item('kv', 'Key-value list.', ['items'], _keyValue),
  _item('chips', 'Selectable chips.', ['items', 'ord'], _chips),
  _item('buttons', 'Action buttons.', ['items', 'ord'], _buttons),
  _item('progress', 'Progress bar.', ['value', 'label'], _progress),
  _item('image', 'Image.', ['url', 'caption', 'height'], _image),
  _item('video', 'Video player.', ['url', 'caption', 'loop', 'full'], _video),
  _item('divider', 'Divider.', [], _divider),
  _item('row', 'Horizontal layout.', ['children', 'cols'], _row),
  _item('column', 'Vertical layout.', ['children', 'fill'], _column),
  _item('grid', 'Grid layout.', ['children', 'cols'], _grid),
  _item('form', 'Form.', [
    'title',
    'intro',
    'submit',
    'fields',
    'ord',
    'submitted',
  ], _form),
], catalogId: displayCatalogId);

// ---------------------------------------------------------------------------
// Helpers.

List<Object?> _list(Object? v) => v is List ? v : const [];
String _s(Object? v) => cellText(v);
int _ord(_Json data) => (data['ord'] as num?)?.toInt() ?? 0;

/// Image from https/http, file:// or an absolute path.
Widget displayImage(
  String url, {
  BoxFit fit = BoxFit.cover,
  double? width,
  double? height,
}) {
  Widget placeholder() => Container(
    width: width,
    height: height,
    color: DisplayColors.surfaceHigh,
    alignment: Alignment.center,
    child: const Icon(
      Icons.image_not_supported_outlined,
      color: DisplayColors.textFaint,
    ),
  );
  final String u = url.trim();
  if (u.startsWith('file://') || u.startsWith('/')) {
    final String path = u.startsWith('file://') ? Uri.parse(u).toFilePath() : u;
    return Image.file(
      File(path),
      fit: fit,
      width: width,
      height: height,
      errorBuilder: (_, _, _) => placeholder(),
    );
  }
  if (!u.startsWith('http://') && !u.startsWith('https://')) {
    return placeholder();
  }
  return Image.network(
    u,
    fit: fit,
    width: width,
    height: height,
    errorBuilder: (_, _, _) => placeholder(),
    frameBuilder: (context, child, frame, sync) => AnimatedOpacity(
      opacity: sync || frame != null ? 1 : 0,
      duration: const Duration(milliseconds: 300),
      child: child,
    ),
  );
}

// ---------------------------------------------------------------------------
// Text.

Widget _heading(CatalogItemContext ctx, _Json data) {
  final t = DisplayText.of(ctx.buildContext);
  final int level = (data['level'] as num?)?.toInt() ?? 1;
  final double s = t.s;
  return Padding(
    padding: EdgeInsets.only(top: 8 * s),
    child: RichDisplayText(
      _s(data['text']),
      style: level <= 1 ? t.heading : t.headingSmall,
    ),
  );
}

Widget _text(CatalogItemContext ctx, _Json data) {
  final t = DisplayText.of(ctx.buildContext);
  return ConstrainedBox(
    // Keep long paragraphs at a readable line length.
    constraints: BoxConstraints(maxWidth: 1100 * t.s),
    child: RichDisplayText(_s(data['text']), style: t.body),
  );
}

// ---------------------------------------------------------------------------
// Cards.

Widget _cards(CatalogItemContext ctx, _Json data) {
  final List<_Json> items = [
    for (final Object? it in _list(data['items']))
      if (it is Map) it.cast<String, Object?>(),
  ];
  final int ord = _ord(data);
  final String? layout = data['layout'] as String?;
  final bool grid =
      layout == 'grid' ||
      (layout == null && items.any((c) => c['image'] != null));
  return _CardsView(
    items: items,
    ord: ord,
    grid: grid,
    onTap: (i) => _dispatch(ctx, DisplayActions.tap, i),
  );
}

class _CardsView extends StatelessWidget {
  const _CardsView({
    required this.items,
    required this.ord,
    required this.grid,
    required this.onTap,
  });

  final List<_Json> items;
  final int ord;
  final bool grid;
  final void Function(int index) onTap;

  @override
  Widget build(BuildContext context) {
    final double s = DisplayScale.of(context);
    final double gap = 22 * s;
    if (!grid) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) SizedBox(height: 14 * s),
            _CardTile(
              data: items[i],
              number: ord > 0 ? ord + i : null,
              grid: false,
              onTap: () => onTap(i),
            ),
          ],
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final double w = constraints.maxWidth;
        final int cols = ((w + gap) / (340 * s + gap)).floor().clamp(1, 4);
        final double itemW = (w - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (var i = 0; i < items.length; i++)
              SizedBox(
                width: itemW,
                child: _CardTile(
                  data: items[i],
                  number: ord > 0 ? ord + i : null,
                  grid: true,
                  onTap: () => onTap(i),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CardTile extends StatelessWidget {
  const _CardTile({
    required this.data,
    required this.number,
    required this.grid,
    required this.onTap,
  });

  final _Json data;
  final int? number;
  final bool grid;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = DisplayText.of(context);
    final double s = t.s;
    final String? image = data['image'] as String?;
    final String? subtitle = data['subtitle'] as String?;
    final String? body = data['body'] as String?;
    final String? value = data['value'] as String?;

    final Widget texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: RichDisplayText(
                _s(data['title']),
                style: t.cardTitle,
                maxLines: grid ? 2 : 3,
              ),
            ),
            if (value != null) ...[
              SizedBox(width: 16 * s),
              Text(value, style: t.value),
            ],
          ],
        ),
        if (subtitle != null) ...[
          SizedBox(height: 6 * s),
          RichDisplayText(subtitle, style: t.bodyMuted, maxLines: 2),
        ],
        if (body != null) ...[
          SizedBox(height: 10 * s),
          RichDisplayText(
            body,
            style: t.body.copyWith(fontSize: 19 * s),
            maxLines: grid ? 4 : 6,
          ),
        ],
      ],
    );

    return Selectable(
      onTap: onTap,
      builder: (context, hover) {
        final double radius = 18 * s;
        final Widget badge = number == null
            ? const SizedBox.shrink()
            : OrdinalBadge(number!, filled: hover);
        Widget content;
        if (grid) {
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (image != null)
                ClipRRect(
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(radius - 1),
                  ),
                  child: AspectRatio(
                    aspectRatio: 16 / 10,
                    child: displayImage(image),
                  ),
                ),
              Padding(padding: EdgeInsets.all(22 * s), child: texts),
            ],
          );
          content = Stack(
            children: [
              content,
              if (number != null)
                Positioned(left: 14 * s, top: 14 * s, child: badge),
            ],
          );
          if (image == null && number != null) {
            content = Padding(
              padding: EdgeInsets.only(top: 34 * s),
              child: content,
            );
          }
        } else {
          content = Padding(
            padding: EdgeInsets.symmetric(horizontal: 22 * s, vertical: 18 * s),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (number != null) ...[badge, SizedBox(width: 20 * s)],
                if (image != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12 * s),
                    child: displayImage(image, width: 132 * s, height: 88 * s),
                  ),
                  SizedBox(width: 22 * s),
                ],
                Expanded(child: texts),
              ],
            ),
          );
        }
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: panelDecoration(s, highlight: hover),
          child: content,
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Table.

final RegExp _numeric = RegExp(
  r'^[-+−]?[\d.,\s]+\s?(%|€|\$|£|k|K|M|h|min|ms|s)?$',
);

Widget _table(CatalogItemContext ctx, _Json data) {
  final List<String> columns = [for (final c in _list(data['columns'])) _s(c)];
  final List<List<String>> rows = [
    for (final r in _list(data['rows']))
      if (r is List) [for (final c in r) _s(c)],
  ];
  return _TableView(
    columns: columns,
    rows: rows,
    ord: _ord(data),
    onTap: (i) => _dispatch(ctx, DisplayActions.tap, i),
  );
}

class _TableView extends StatelessWidget {
  const _TableView({
    required this.columns,
    required this.rows,
    required this.ord,
    required this.onTap,
  });

  final List<String> columns;
  final List<List<String>> rows;
  final int ord;
  final void Function(int) onTap;

  @override
  Widget build(BuildContext context) {
    final t = DisplayText.of(context);
    final double s = t.s;
    int nCols = columns.length;
    for (final r in rows) {
      if (r.length > nCols) nCols = r.length;
    }
    if (nCols == 0) return const SizedBox.shrink();
    // Flex per column from content length, so long text gets more room.
    final List<int> flex = List.generate(nCols, (j) {
      var len = j < columns.length ? columns[j].length : 0;
      for (final r in rows) {
        if (j < r.length && r[j].length > len) len = r[j].length;
      }
      return len.clamp(4, 36);
    });
    final List<bool> numericCol = List.generate(nCols, (j) {
      final cells = [
        for (final r in rows)
          if (j < r.length && r[j].isNotEmpty) r[j],
      ];
      return cells.isNotEmpty && cells.every(_numeric.hasMatch);
    });
    final double badgeW = 56 * s;
    final hPad = EdgeInsets.symmetric(horizontal: 24 * s);

    Widget cells(List<String> values, TextStyle style) => Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var j = 0; j < nCols; j++)
          Expanded(
            flex: flex[j],
            child: Padding(
              padding: EdgeInsets.only(right: 18 * s),
              child: Text(
                j < values.length ? values[j] : '',
                style: style,
                textAlign: numericCol[j] ? TextAlign.right : TextAlign.left,
              ),
            ),
          ),
      ],
    );

    return Container(
      decoration: panelDecoration(s),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (columns.isNotEmpty)
            Container(
              padding: hPad.add(EdgeInsets.symmetric(vertical: 16 * s)),
              color: const Color(0x0DA78BFA),
              child: Row(
                children: [
                  if (ord > 0) SizedBox(width: badgeW),
                  Expanded(
                    child: cells([
                      for (final c in columns) c.toUpperCase(),
                    ], t.label),
                  ),
                ],
              ),
            ),
          for (var i = 0; i < rows.length; i++)
            Selectable(
              onTap: () => onTap(i),
              builder: (context, hover) => AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                padding: hPad.add(EdgeInsets.symmetric(vertical: 14 * s)),
                decoration: BoxDecoration(
                  color: hover
                      ? const Color(0x1AA78BFA)
                      : (i.isOdd ? const Color(0x08FFFFFF) : null),
                  border: const Border(
                    top: BorderSide(color: DisplayColors.border, width: 0.6),
                  ),
                ),
                child: Row(
                  children: [
                    if (ord > 0)
                      SizedBox(
                        width: badgeW,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: OrdinalBadge(ord + i, filled: hover),
                        ),
                      ),
                    Expanded(child: cells(rows[i], t.cell)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Stats, key-value, chips, buttons, progress.

Widget _stats(CatalogItemContext ctx, _Json data) {
  final List<_Json> items = [
    for (final it in _list(data['items']))
      if (it is Map) it.cast<String, Object?>(),
  ];
  return Builder(
    builder: (context) {
      final t = DisplayText.of(context);
      final double s = t.s;
      final double gap = 22 * s;
      final bool anyDelta = items.any((it) => it['delta'] != null);
      return LayoutBuilder(
        builder: (context, c) {
          final int fit = ((c.maxWidth + gap) / (250 * s + gap)).floor();
          final int cols = fit.clamp(1, items.isEmpty ? 1 : items.length);
          final double w = (c.maxWidth - gap * (cols - 1)) / cols;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final it in items)
                Container(
                  width: w,
                  padding: EdgeInsets.all(26 * s),
                  decoration: panelDecoration(s),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_s(it['label']).toUpperCase(), style: t.label),
                      SizedBox(height: 12 * s),
                      // Fixed height so long values that scale down do not
                      // make tiles of the same row uneven.
                      SizedBox(
                        height: t.statValue.fontSize! * 1.15,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(_s(it['value']), style: t.statValue),
                        ),
                      ),
                      if (it['delta'] != null) ...[
                        SizedBox(height: 8 * s),
                        _Delta(_s(it['delta'])),
                      ] else if (anyDelta) ...[
                        SizedBox(height: 8 * s),
                        Opacity(opacity: 0, child: _Delta('+0')),
                      ],
                    ],
                  ),
                ),
            ],
          );
        },
      );
    },
  );
}

class _Delta extends StatelessWidget {
  const _Delta(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = DisplayText.of(context);
    final String v = text.trim();
    final bool down =
        v.startsWith('-') || v.startsWith('−') || v.startsWith('▼');
    final bool up = v.startsWith('+') || v.startsWith('▲');
    final Color color = down
        ? DisplayColors.negative
        : up
        ? DisplayColors.positive
        : DisplayColors.textMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (up || down)
          Icon(
            down ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
            color: color,
            size: 20 * t.s,
          ),
        SizedBox(width: 4 * t.s),
        Text(
          v.replaceFirst(RegExp(r'^[▲▼]\s*'), ''),
          style: t.bodyMuted.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

Widget _keyValue(CatalogItemContext ctx, _Json data) {
  final List<List<String>> items = [
    for (final it in _list(data['items']))
      if (it is List && it.isNotEmpty)
        [_s(it[0]), it.length > 1 ? _s(it[1]) : ''],
  ];
  return Builder(
    builder: (context) {
      final t = DisplayText.of(context);
      final double s = t.s;
      return Container(
        decoration: panelDecoration(s),
        padding: EdgeInsets.symmetric(horizontal: 26 * s, vertical: 8 * s),
        child: Column(
          children: [
            for (var i = 0; i < items.length; i++)
              Container(
                padding: EdgeInsets.symmetric(vertical: 14 * s),
                decoration: BoxDecoration(
                  border: i == 0
                      ? null
                      : const Border(
                          top: BorderSide(
                            color: DisplayColors.border,
                            width: 0.6,
                          ),
                        ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 2,
                      child: Text(
                        items[i][0],
                        style: t.bodyMuted.copyWith(fontSize: 20 * s),
                      ),
                    ),
                    SizedBox(width: 20 * s),
                    Expanded(
                      flex: 3,
                      child: RichDisplayText(items[i][1], style: t.cell),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );
}

Widget _chips(CatalogItemContext ctx, _Json data) {
  final List<String> items = [for (final c in _list(data['items'])) _s(c)];
  final int ord = _ord(data);
  return Builder(
    builder: (context) {
      final t = DisplayText.of(context);
      final double s = t.s;
      return Wrap(
        spacing: 14 * s,
        runSpacing: 14 * s,
        children: [
          for (var i = 0; i < items.length; i++)
            Selectable(
              onTap: () => _dispatch(ctx, DisplayActions.tap, i),
              builder: (context, hover) => AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                padding: EdgeInsets.fromLTRB(
                  ord > 0 ? 7 * s : 20 * s,
                  7 * s,
                  20 * s,
                  7 * s,
                ),
                decoration: BoxDecoration(
                  color: hover
                      ? const Color(0x26A78BFA)
                      : DisplayColors.surface,
                  borderRadius: BorderRadius.circular(40 * s),
                  border: Border.all(
                    color: hover
                        ? DisplayColors.borderStrong
                        : DisplayColors.border,
                    width: 1.2,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (ord > 0) ...[
                      OrdinalBadge(ord + i, filled: hover),
                      SizedBox(width: 12 * s),
                    ],
                    Text(items[i], style: t.body.copyWith(fontSize: 20 * s)),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}

Widget _buttons(CatalogItemContext ctx, _Json data) {
  final List<String> items = [for (final c in _list(data['items'])) _s(c)];
  final int ord = _ord(data);
  return Builder(
    builder: (context) {
      final t = DisplayText.of(context);
      final double s = t.s;
      return Wrap(
        spacing: 18 * s,
        runSpacing: 14 * s,
        children: [
          for (var i = 0; i < items.length; i++)
            Selectable(
              onTap: () => _dispatch(ctx, DisplayActions.press, i),
              builder: (context, hover) {
                final bool primary = i == 0;
                final Color fg = primary
                    ? DisplayColors.background
                    : DisplayColors.accent;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  padding: EdgeInsets.symmetric(
                    horizontal: 28 * s,
                    vertical: 16 * s,
                  ),
                  decoration: BoxDecoration(
                    color: primary
                        ? (hover
                              ? DisplayColors.accentSecondary
                              : DisplayColors.accent)
                        : (hover
                              ? const Color(0x26A78BFA)
                              : Colors.transparent),
                    borderRadius: BorderRadius.circular(14 * s),
                    border: Border.all(color: DisplayColors.accent, width: 1.4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (ord > 0) ...[
                        Text(
                          '${ord + i}',
                          style: TextStyle(
                            fontSize: 16 * s,
                            fontWeight: FontWeight.w700,
                            color: fg.withValues(alpha: 0.65),
                          ),
                        ),
                        SizedBox(width: 12 * s),
                      ],
                      Text(
                        items[i],
                        style: TextStyle(
                          fontSize: 21 * s,
                          fontWeight: FontWeight.w600,
                          color: fg,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      );
    },
  );
}

Widget _progress(CatalogItemContext ctx, _Json data) {
  final double? value = (data['value'] as num?)?.toDouble();
  final String? label = data['label'] as String?;
  return Builder(
    builder: (context) {
      final t = DisplayText.of(context);
      final double s = t.s;
      final double h = 12 * s;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(label ?? '', style: t.bodyMuted)),
              if (value != null)
                Text('${(value * 100).round()}%', style: t.value),
            ],
          ),
          SizedBox(height: 12 * s),
          ClipRRect(
            borderRadius: BorderRadius.circular(h),
            child: SizedBox(
              height: h,
              child: value == null
                  ? const LinearProgressIndicator(
                      backgroundColor: DisplayColors.surfaceHigh,
                      color: DisplayColors.accent,
                    )
                  : TweenAnimationBuilder<double>(
                      tween: Tween(end: value),
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeOutCubic,
                      builder: (context, v, _) => Stack(
                        children: [
                          const Positioned.fill(
                            child: ColoredBox(color: DisplayColors.surfaceHigh),
                          ),
                          FractionallySizedBox(
                            widthFactor: v.clamp(0, 1),
                            child: Container(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    DisplayColors.accentDim,
                                    DisplayColors.accent,
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ],
      );
    },
  );
}

// ---------------------------------------------------------------------------
// Media.

Widget _image(CatalogItemContext ctx, _Json data) {
  final String? url = data['url'] as String?;
  final String? caption = data['caption'] as String?;
  final double? height = (data['height'] as num?)?.toDouble();
  return Builder(
    builder: (context) {
      final t = DisplayText.of(context);
      final double s = t.s;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: (height ?? 520) * s),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18 * s),
              child: url == null
                  ? SizedBox(height: 200 * s)
                  : displayImage(url, fit: BoxFit.contain),
            ),
          ),
          if (caption != null) ...[
            SizedBox(height: 10 * s),
            Text(caption, style: t.bodyMuted),
          ],
        ],
      );
    },
  );
}

Widget _video(CatalogItemContext ctx, _Json data) {
  final String? url = data['url'] as String?;
  if (url == null) return const SizedBox.shrink();
  return DisplayVideo(
    componentId: ctx.id,
    url: url,
    caption: data['caption'] as String?,
    loop: data['loop'] == true,
    full: data['full'] == true,
  );
}

Widget _divider(CatalogItemContext ctx, _Json data) => Builder(
  builder: (context) => Container(
    height: 1,
    margin: EdgeInsets.symmetric(vertical: 6 * DisplayScale.of(context)),
    color: DisplayColors.border,
  ),
);

// ---------------------------------------------------------------------------
// Layouts.

List<String> _children(_Json data) => [
  for (final c in _list(data['children']))
    if (c is String) c,
];

Widget _column(CatalogItemContext ctx, _Json data) {
  final List<String> ids = _children(data);
  if (data['fill'] == true && ids.isNotEmpty) {
    return SizedBox.expand(child: ctx.buildChild(ids.first));
  }
  return Builder(
    builder: (context) {
      final double gap = 30 * DisplayScale.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < ids.length; i++) ...[
            if (i > 0) SizedBox(height: gap),
            ctx.buildChild(ids[i]),
          ],
        ],
      );
    },
  );
}

Widget _row(CatalogItemContext ctx, _Json data) {
  final List<String> ids = _children(data);
  return Builder(
    builder: (context) {
      final double gap = 26 * DisplayScale.of(context);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < ids.length; i++) ...[
            if (i > 0) SizedBox(width: gap),
            Expanded(child: ctx.buildChild(ids[i])),
          ],
        ],
      );
    },
  );
}

Widget _grid(CatalogItemContext ctx, _Json data) {
  final List<String> ids = _children(data);
  final int cols = (data['cols'] as num?)?.toInt() ?? 2;
  return Builder(
    builder: (context) {
      final double gap = 26 * DisplayScale.of(context);
      final rows = <Widget>[];
      for (var start = 0; start < ids.length; start += cols) {
        if (rows.isNotEmpty) rows.add(SizedBox(height: gap));
        rows.add(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var j = 0; j < cols; j++) ...[
                if (j > 0) SizedBox(width: gap),
                Expanded(
                  child: start + j < ids.length
                      ? ctx.buildChild(ids[start + j])
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: rows,
      );
    },
  );
}

// ---------------------------------------------------------------------------
// Form.

/// Data model path of a form's values.
String formPath(String formId) => '/forms/$formId';

Widget _form(CatalogItemContext ctx, _Json data) {
  return DisplayForm(
    formId: ctx.id,
    data: data,
    dataContext: ctx.dataContext,
    onSubmit: () => _dispatch(ctx, DisplayActions.submit),
  );
}
