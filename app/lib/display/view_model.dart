/// The display's own view model: our compact, LLM-friendly node tree.
///
/// Tool arguments are normalized into [DisplayNode]s (tolerant to missing or
/// partial fields so streaming input can be rendered), ids and ordinals are
/// assigned here, and the tree is flattened into A2UI components for genui.
library;

import 'dart:convert';

/// Catalog component names (A2UI `component` values) per node type.
const Map<String, String> catalogNames = {
  'heading': 'DHeading',
  'text': 'DText',
  'cards': 'DCards',
  'table': 'DTable',
  'stats': 'DStats',
  'kv': 'DKeyValue',
  'chips': 'DChips',
  'buttons': 'DButtons',
  'progress': 'DProgress',
  'image': 'DImage',
  'video': 'DVideo',
  'divider': 'DDivider',
  'row': 'DRow',
  'column': 'DColumn',
  'grid': 'DGrid',
  'form': 'DForm',
};

const Set<String> layoutTypes = {'row', 'column', 'grid'};

const Map<String, String> _typeAliases = {
  'h': 'heading',
  'h1': 'heading',
  'h2': 'heading',
  'title': 'heading',
  'header': 'heading',
  'p': 'text',
  'paragraph': 'text',
  'markdown': 'text',
  'card': 'cards',
  'cardlist': 'cards',
  'card_list': 'cards',
  'list': 'cards',
  'stat': 'stats',
  'keyvalue': 'kv',
  'key_value': 'kv',
  'tags': 'chips',
  'chip': 'chips',
  'button': 'buttons',
  'actions': 'buttons',
  'progressbar': 'progress',
  'img': 'image',
  'hr': 'divider',
  'col': 'column',
  'stack': 'column',
};

const Map<String, String> _idPrefixes = {
  'heading': 'h',
  'text': 'text',
  'image': 'img',
  'divider': 'div',
  'column': 'col',
};

/// Keys whose string values must be complete before use while streaming.
const Set<String> atomicJsonKeys = {
  'type',
  'id',
  'url',
  'image',
  'img',
  'layout',
  'name',
  'control',
};

/// One node of a view.
class DisplayNode {
  DisplayNode({
    required this.id,
    required this.type,
    required this.props,
    List<DisplayNode>? children,
  }) : children = children ?? [];

  final String id;
  final String type;
  Map<String, dynamic> props;
  final List<DisplayNode> children;

  /// First ordinal of this node's selectable items (0 when none).
  int ord = 0;

  bool get isLayout => layoutTypes.contains(type);

  Iterable<DisplayNode> walk() sync* {
    yield this;
    for (final DisplayNode c in children) {
      yield* c.walk();
    }
  }

  /// Number of selectable items (cards, rows, chips, buttons).
  int get selectableCount => switch (type) {
    'cards' || 'chips' || 'buttons' => listOf(props['items']).length,
    'table' => listOf(props['rows']).length,
    _ => 0,
  };
}

/// A resolved ordinal: what the number badge `[n]` points to.
class OrdinalRef {
  const OrdinalRef({
    required this.ordinal,
    required this.nodeId,
    required this.index,
    required this.kind,
    required this.label,
    this.field,
  });

  final int ordinal;
  final String nodeId;
  final int index;

  /// 'item' (card), 'row', 'chip', 'button' or 'choice' (form option).
  final String kind;
  final String label;

  /// Form field name for choices.
  final String? field;
}

// ---------------------------------------------------------------------------
// Tolerant value helpers.

List<dynamic> listOf(Object? v) => v is List ? v : const [];

String? str(Object? v) {
  if (v == null) return null;
  if (v is String) return v;
  if (v is num || v is bool) return _fmtScalar(v);
  return null;
}

String _fmtScalar(Object v) {
  if (v is double && v == v.roundToDouble() && v.abs() < 1e15) {
    return v.toInt().toString();
  }
  return v.toString();
}

/// Stringifies any JSON value for display (cells, kv values, ...).
String cellText(Object? v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is num || v is bool) return _fmtScalar(v);
  if (v is Map) {
    return str(v['text'] ?? v['label'] ?? v['value'] ?? v['title']) ??
        jsonEncode(v);
  }
  return jsonEncode(v);
}

num? numOf(Object? v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v.trim().replaceAll('%', ''));
  return null;
}

String _clip(String s, [int max = 70]) {
  final String one = s.replaceAll('\n', ' ').trim();
  return one.length <= max ? one : '${one.substring(0, max - 1)}…';
}

String quote(String s, [int max = 70]) => '"${_clip(s, max)}"';

// ---------------------------------------------------------------------------
// Parsing.

/// Builds normalized node trees from tool arguments, assigning stable ids.
///
/// Auto ids are `<prefix><n>` per type, numbered in document order, so they
/// stay stable while a streamed call grows.
class NodeParser {
  final Map<String, int> _counters = {};
  final Set<String> _used = {'root'};
  final List<String> warnings = [];

  String _autoId(String type) {
    final String prefix = _idPrefixes[type] ?? type;
    while (true) {
      final int n = (_counters[prefix] ?? 0) + 1;
      _counters[prefix] = n;
      final String id = '$prefix$n';
      if (_used.add(id)) return id;
    }
  }

  String _takeId(Object? raw, String type) {
    final String? wanted = str(raw)?.trim();
    if (wanted != null && wanted.isNotEmpty && _used.add(wanted)) return wanted;
    return _autoId(type);
  }

  /// Registers ids already present in a tree (used when appending nodes).
  void reserve(DisplayNode root) {
    for (final DisplayNode n in root.walk()) {
      _used.add(n.id);
      final match = RegExp(r'^([a-z]+)(\d+)$').firstMatch(n.id);
      if (match != null) {
        final String p = match.group(1)!;
        final int k = int.parse(match.group(2)!);
        if ((_counters[p] ?? 0) < k) _counters[p] = k;
      }
    }
  }

  /// Parses the `body` of a view into a root column.
  DisplayNode parseRoot(Object? body) {
    final root = DisplayNode(id: 'root', type: 'column', props: {});
    root.children.addAll(parseList(body));
    return root;
  }

  List<DisplayNode> parseList(Object? raw) {
    final out = <DisplayNode>[];
    for (final Object? item in listOf(raw)) {
      final DisplayNode? n = parseNode(item);
      if (n != null) out.add(n);
    }
    return out;
  }

  static String? normalizeType(Object? raw) {
    final String? t = str(raw)?.trim().toLowerCase();
    if (t == null) return null;
    final String type = _typeAliases[t] ?? t;
    return catalogNames.containsKey(type) ? type : null;
  }

  DisplayNode? parseNode(Object? raw) {
    if (raw is String) {
      return DisplayNode(
        id: _autoId('text'),
        type: 'text',
        props: {'text': raw},
      );
    }
    if (raw is! Map) return null;
    final String? type = normalizeType(raw['type'] ?? raw['component']);
    if (type == null) {
      final Object? t = raw['type'];
      if (t != null) warnings.add('ignored unknown type "$t"');
      return null;
    }
    final String id = _takeId(raw['id'], type);
    final node = DisplayNode(
      id: id,
      type: type,
      props: normalizeProps(type, raw),
    );
    if (layoutTypes.contains(type)) {
      node.children.addAll(parseList(raw['children'] ?? raw['items']));
    }
    return node;
  }

  /// Normalizes the props of a node of [type] from raw JSON.
  static Map<String, dynamic> normalizeProps(String type, Map raw) {
    final p = <String, dynamic>{};
    void copyStr(String key, List<String> aliases) {
      for (final String k in [key, ...aliases]) {
        final String? v = str(raw[k]);
        if (v != null) {
          p[key] = v;
          return;
        }
      }
    }

    switch (type) {
      case 'heading':
      case 'text':
        copyStr('text', ['content', 'title', 'value', 'label']);
        if (type == 'heading') {
          final num? level = numOf(raw['level']);
          if (level != null) p['level'] = level.toInt();
        }
      case 'cards':
        p['items'] = [
          for (final Object? it in listOf(raw['items'])) ?_card(it),
        ];
        copyStr('layout', []);
      case 'stats':
        p['items'] = [
          for (final Object? it in listOf(raw['items'])) ?_stat(it),
        ];
      case 'kv':
        p['items'] = _kvItems(raw['items'] ?? raw['pairs']);
      case 'chips':
      case 'buttons':
        p['items'] = [
          for (final Object? it in listOf(raw['items'] ?? raw['labels']))
            ?_label(it),
        ];
        if (p['items'].isEmpty) {
          final String? single = str(raw['label'] ?? raw['text']);
          if (single != null) p['items'] = [single];
        }
      case 'table':
        final List<String> columns = [
          for (final Object? c in listOf(raw['columns'] ?? raw['headers']))
            cellText(c),
        ];
        p['columns'] = columns;
        p['rows'] = [
          for (final Object? r in listOf(raw['rows'])) ?_row(r, columns),
        ];
      case 'progress':
        num? v = numOf(raw['value'] ?? raw['progress']);
        if (v != null) {
          if (v > 1) v = v / 100;
          p['value'] = v.clamp(0, 1).toDouble();
        }
        copyStr('label', ['text', 'title']);
      case 'image':
        copyStr('url', ['src', 'image']);
        copyStr('caption', ['text', 'title']);
        final num? h = numOf(raw['height']);
        if (h != null) p['height'] = h.toDouble();
      case 'video':
        copyStr('url', ['src']);
        copyStr('caption', ['title', 'text']);
        if (raw['loop'] == true) p['loop'] = true;
        if (raw['full'] == true) p['full'] = true;
      case 'divider':
        break;
      case 'row':
      case 'column':
      case 'grid':
        final num? cols = numOf(raw['cols'] ?? raw['columns']);
        if (cols != null) p['cols'] = cols.toInt().clamp(1, 6);
      case 'form':
        copyStr('title', []);
        copyStr('intro', ['text']);
        copyStr('submit', ['submitLabel']);
        p['fields'] = [
          for (final Object? f in listOf(raw['fields'])) ?_field(f),
        ];
    }
    return p;
  }

  static Map<String, dynamic>? _card(Object? it) {
    if (it is String) return {'title': it};
    if (it is! Map) return null;
    final c = <String, dynamic>{};
    void put(String key, List<String> keys) {
      for (final String k in keys) {
        final String? v = str(it[k]);
        if (v != null) {
          c[key] = v;
          return;
        }
      }
    }

    put('title', ['title', 'name', 'label']);
    put('subtitle', ['subtitle', 'sub']);
    put('body', ['body', 'text', 'description']);
    put('image', ['image', 'img', 'imageUrl', 'url']);
    put('value', ['value', 'trailing', 'meta']);
    if (c.isEmpty) return null;
    return c;
  }

  static Map<String, dynamic>? _stat(Object? it) {
    if (it is! Map) return null;
    final s = <String, dynamic>{};
    final String? label = str(it['label'] ?? it['title'] ?? it['name']);
    final String? value = str(it['value']);
    final String? delta = str(it['delta'] ?? it['change']);
    if (label != null) s['label'] = label;
    if (value != null) s['value'] = value;
    if (delta != null) s['delta'] = delta;
    return s.isEmpty ? null : s;
  }

  static String? _label(Object? it) {
    if (it is Map) return str(it['label'] ?? it['text'] ?? it['title']);
    return str(it);
  }

  static List<List<String>> _kvItems(Object? raw) {
    if (raw is Map) {
      return [
        for (final MapEntry e in raw.entries)
          [e.key.toString(), cellText(e.value)],
      ];
    }
    final out = <List<String>>[];
    for (final Object? it in listOf(raw)) {
      if (it is List && it.isNotEmpty) {
        out.add([cellText(it[0]), it.length > 1 ? cellText(it[1]) : '']);
      } else if (it is Map) {
        final Object? k = it['key'] ?? it['label'] ?? it['k'];
        if (k != null) {
          out.add([cellText(k), cellText(it['value'] ?? it['v'])]);
        } else if (it.length == 1) {
          out.add([it.keys.first.toString(), cellText(it.values.first)]);
        }
      }
    }
    return out;
  }

  static List<String>? _row(Object? r, List<String> columns) {
    if (r is List) return [for (final Object? c in r) cellText(c)];
    if (r is Map) {
      if (columns.isNotEmpty) return [for (final c in columns) cellText(r[c])];
      return [for (final Object? v in r.values) cellText(v)];
    }
    if (r is String) return [r];
    return null;
  }

  static const Set<String> fieldTypes = {
    'text',
    'number',
    'date',
    'select',
    'checkbox',
    'slider',
  };

  static Map<String, dynamic>? _field(Object? f) {
    if (f is! Map) return null;
    final String? rawName = str(f['name'] ?? f['id']);
    if (rawName == null || rawName.isEmpty) return null;
    String type = str(f['type'])?.toLowerCase() ?? 'text';
    type = switch (type) {
      'choice' || 'radio' || 'dropdown' || 'choicepicker' => 'select',
      'bool' || 'boolean' || 'switch' || 'toggle' => 'checkbox',
      'int' || 'integer' || 'float' => 'number',
      'range' => 'slider',
      'datetime' || 'day' => 'date',
      _ => type,
    };
    if (!fieldTypes.contains(type)) type = 'text';
    final field = <String, dynamic>{
      'name': rawName.replaceAll('/', '_').replaceAll('~', '_'),
      'type': type,
      'label': str(f['label'] ?? f['title']) ?? rawName,
    };
    if (f['required'] == true) field['required'] = true;
    final String? placeholder = str(f['placeholder'] ?? f['hint']);
    if (placeholder != null) field['placeholder'] = placeholder;
    for (final String k in ['min', 'max', 'step']) {
      final num? v = numOf(f[k]);
      if (v != null) field[k] = v;
    }
    if (type == 'select') {
      field['options'] = [
        for (final Object? o in listOf(f['options'] ?? f['choices']))
          ?_label(o),
      ];
    }
    if (f.containsKey('default')) field['default'] = f['default'];
    return field;
  }
}

// ---------------------------------------------------------------------------
// Ordinals and flattening.

/// Assigns ordinals (1..N in document order) to selectable items of [root]
/// and returns the resolved table.
List<OrdinalRef> assignOrdinals(DisplayNode root) {
  final refs = <OrdinalRef>[];
  var next = 1;
  for (final DisplayNode n in root.walk()) {
    n.ord = 0;
    switch (n.type) {
      case 'cards' || 'chips' || 'buttons' || 'table':
        final List<dynamic> items = listOf(
          n.type == 'table' ? n.props['rows'] : n.props['items'],
        );
        if (items.isEmpty) continue;
        n.ord = next;
        for (var i = 0; i < items.length; i++) {
          refs.add(
            OrdinalRef(
              ordinal: next++,
              nodeId: n.id,
              index: i,
              kind: switch (n.type) {
                'cards' => 'item',
                'table' => 'row',
                'chips' => 'chip',
                _ => 'button',
              },
              label: _itemLabel(n.type, items[i]),
            ),
          );
        }
      case 'form':
        for (final Object? f in listOf(n.props['fields'])) {
          if (f is! Map || f['type'] != 'select') continue;
          final List<dynamic> options = listOf(f['options']);
          if (options.isEmpty) continue;
          f['_o'] = next;
          if (n.ord == 0) n.ord = next;
          for (var i = 0; i < options.length; i++) {
            refs.add(
              OrdinalRef(
                ordinal: next++,
                nodeId: n.id,
                index: i,
                kind: 'choice',
                label: cellText(options[i]),
                field: f['name'] as String?,
              ),
            );
          }
        }
    }
  }
  return refs;
}

String _itemLabel(String type, Object? item) {
  if (type == 'cards' && item is Map) {
    final String title = cellText(item['title']);
    final String? value = str(item['value']);
    return value == null ? title : '$title — $value';
  }
  if (type == 'table' && item is List) {
    return item.take(4).map(cellText).join(' | ');
  }
  return cellText(item);
}

/// Flattens [root] into A2UI v0.9 component maps keyed by id.
Map<String, Map<String, dynamic>> flattenToComponents(DisplayNode root) {
  final out = <String, Map<String, dynamic>>{};
  for (final DisplayNode n in root.walk()) {
    out[n.id] = {
      'id': n.id,
      'component': catalogNames[n.type]!,
      ...n.props,
      if (n.isLayout) 'children': [for (final c in n.children) c.id],
      if (n.ord > 0) 'ord': n.ord,
    };
  }
  return out;
}

/// Finds the node with [id] and its parent in [root].
(DisplayNode node, DisplayNode? parent)? findNode(DisplayNode root, String id) {
  if (root.id == id) return (root, null);
  for (final DisplayNode n in root.walk()) {
    for (final DisplayNode c in n.children) {
      if (c.id == id) return (c, n);
    }
  }
  return null;
}
