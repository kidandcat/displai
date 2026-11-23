/// The display's tool layer: implements the MCP display tools on top of the
/// genui adapter, keeps the timeline, ordinals and user events.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:genui/genui.dart' show SurfaceContext;

import 'catalog.dart' show DisplayActions, formPath;
import 'form_widgets.dart' show formatFieldValue;
import 'genui_adapter.dart';
import 'partial_json.dart';
import 'theme.dart';
import 'tool_specs.dart';
import 'video_widgets.dart';
import 'view_model.dart';

/// One view of the timeline (a `show`, `form` or `video`).
class DisplayViewEntry {
  DisplayViewEntry._(this.seq, this.kind) : surfaceId = 'v$seq';

  final int seq;

  /// 'view', 'form' or 'video'.
  final String kind;

  /// The A2UI surface rendering this view.
  final String surfaceId;

  String title = '';
  String? subtitle;
  DisplayNode root = DisplayNode(id: 'root', type: 'column', props: {});
  List<OrdinalRef> ordinals = const [];
  DateTime shownAt = DateTime.now();

  /// True while the view is being built from a streaming tool call.
  bool partial = false;

  final Set<String> _defaultsApplied = {};
}

class _Action {
  _Action(this.text) : at = DateTime.now();
  final String text;
  final DateTime at;
}

class DisplayController extends ChangeNotifier implements DisplayRuntime {
  DisplayController();

  /// Maximum number of views kept in the timeline.
  static const int maxTimeline = 20;

  static List<DisplayToolSpec> get toolSpecs => displayToolSpecs;

  final GenuiSurfaceAdapter _adapter = GenuiSurfaceAdapter();
  final List<DisplayViewEntry> _entries = [];
  int _cursor = -1;
  int _lastCursor = -1;
  int _seq = 0;

  final StreamController<String> _events = StreamController.broadcast();
  final List<_Action> _actions = [];

  final ValueNotifier<VideoCommand?> _videoCommands = ValueNotifier(null);
  final Map<String, VideoStatus> _videoStatus = {};
  int _videoSeq = 0;

  // Progressive rendering state.
  DisplayViewEntry? _partial;
  int _partialPrevCursor = -1;
  String? _pendingTool;
  String? _pendingJson;
  Timer? _partialTimer;
  DateTime _lastPartialApply = DateTime(0);
  static const Duration _partialInterval = Duration(milliseconds: 50);

  bool _disposed = false;

  // -------------------------------------------------------------------------
  // Read API for the view.

  bool get isEmpty => _cursor < 0;

  DisplayViewEntry? get current => isEmpty ? null : _entries[_cursor];

  List<DisplayViewEntry> get timeline => List.unmodifiable(_entries);

  int get currentIndex => _cursor;

  /// How many logical pixels of the current view do not fit on screen (the display never
  /// scrolls: what does not fit is cut). Reported by the view after layout.
  double get overflow => _overflow;
  double _overflow = 0;

  void reportOverflow(double px) => _overflow = px;

  Stream<String> get userEvents => _events.stream;

  /// genui error reports (schema validation, runtime); for diagnostics.
  List<String> get rendererErrors => List.unmodifiable(_adapter.errors);

  SurfaceContext surfaceContext(String surfaceId) =>
      _adapter.contextFor(surfaceId);

  @override
  ValueListenable<VideoCommand?> get videoCommands => _videoCommands;

  @override
  void reportVideo(String componentId, VideoStatus status) {
    _videoStatus[componentId] = status;
  }

  // -------------------------------------------------------------------------
  // Navigation.

  void back() => _back(1);

  /// Shows timeline entry [index] (strip click).
  void goTo(int index) {
    if (index < 0 || index >= _entries.length) return;
    _dropPartial();
    _cursor = index;
    _notify();
  }

  /// Keyboard navigation: previous / next view in the timeline.
  void previous() => goTo(isEmpty ? _entries.length - 1 : _cursor - 1);

  void next() => goTo(_cursor + 1);

  String _back(int steps) {
    _dropPartial();
    if (_entries.isEmpty) return 'error: the timeline is empty';
    if (isEmpty) {
      final int target = (_lastCursor >= 0 ? _lastCursor : _entries.length)
          .clamp(0, _entries.length - 1);
      _cursor = (target - (steps - 1)).clamp(0, _entries.length - 1);
    } else {
      if (_cursor == 0) return 'error: already at the first view';
      _cursor = (_cursor - steps).clamp(0, _entries.length - 1);
    }
    _notify();
    final DisplayViewEntry e = _entries[_cursor];
    return 'ok: showing view ${_cursor + 1}/${_entries.length} '
        '${quote(e.title)}';
  }

  // -------------------------------------------------------------------------
  // Tools.

  String callTool(String name, Map<String, dynamic> args) {
    final String tool = _bareName(name);
    try {
      switch (tool) {
        case 'show':
          return _show(args);
        case 'update':
          return _update(args);
        case 'form':
          return _form(args);
        case 'video':
          return _video(args);
        case 'clear':
          return _clear();
        case 'back':
          final int steps = numOf(args['steps'])?.toInt() ?? 1;
          return _back(steps < 1 ? 1 : steps);
        case 'get_state':
          return getState();
      }
      return 'error: unknown display tool "$name"';
    } catch (e) {
      return 'error: $e';
    }
  }

  static String _bareName(String name) {
    final int i = name.lastIndexOf('__');
    return i >= 0 ? name.substring(i + 2) : name;
  }

  DisplayViewEntry _takeEntry(String kind) {
    _cancelPendingPartial();
    final DisplayViewEntry? p = _partial;
    _partial = null;
    if (p != null && p.kind == kind) {
      p.partial = false;
      return p;
    }
    if (p != null) _removeEntry(p, _partialPrevCursor);
    return _newEntry(kind);
  }

  DisplayViewEntry _newEntry(String kind) {
    final entry = DisplayViewEntry._(++_seq, kind);
    _adapter.createSurface(entry.surfaceId);
    _entries.add(entry);
    while (_entries.length > maxTimeline) {
      final DisplayViewEntry old = _entries.removeAt(0);
      _adapter.deleteSurface(old.surfaceId);
      if (_lastCursor > 0) _lastCursor--;
      if (_partialPrevCursor > 0) _partialPrevCursor--;
    }
    _cursor = _entries.length - 1;
    return entry;
  }

  void _removeEntry(DisplayViewEntry e, int restoreCursor) {
    final int idx = _entries.indexOf(e);
    if (idx < 0) return;
    _entries.removeAt(idx);
    _adapter.deleteSurface(e.surfaceId);
    _cursor = restoreCursor < _entries.length ? restoreCursor : -1;
  }

  String _show(Map<String, dynamic> args) {
    final String? title = str(args['title']);
    final Object? body = args['body'] ?? args['children'] ?? args['components'];
    if (title == null && listOf(body).isEmpty) {
      _dropPartial();
      return 'error: show needs a title and a body (list of nodes)';
    }
    final DisplayViewEntry e = _takeEntry('view');
    final parser = NodeParser();
    e
      ..title = title ?? ''
      ..subtitle = str(args['subtitle'])
      ..root = parser.parseRoot(body)
      ..shownAt = DateTime.now();
    _render(e);
    _notify();
    final String warn = parser.warnings.isEmpty
        ? ''
        : ' warnings: ${parser.warnings.toSet().join('; ')}.';
    return 'ok: shown view ${_cursor + 1} ${quote(e.title)}. '
        'components: ${_componentSummary(e)}.$warn';
  }

  String _form(Map<String, dynamic> args) {
    final List<dynamic> fields = listOf(args['fields']);
    if (fields.isEmpty) {
      _dropPartial();
      return 'error: form needs fields';
    }
    final DisplayViewEntry e = _takeEntry('form');
    _fillForm(e, args);
    _notify();
    final DisplayNode form = e.root.children.first;
    final String names = [
      for (final f in listOf(form.props['fields'])) (f as Map)['name'],
    ].join(', ');
    return 'ok: form "${form.id}" shown as view ${_cursor + 1} '
        '(fields: $names). The submission will arrive as a '
        '"[display] form ..." message; read live values with get_state.';
  }

  void _fillForm(DisplayViewEntry e, Map<String, dynamic> args) {
    final parser = NodeParser();
    final DisplayNode? form = parser.parseNode({
      ...args,
      'type': 'form',
      'id': args['id'] ?? 'form',
    });
    e
      ..title = str(args['title']) ?? ''
      ..subtitle = null
      ..root = DisplayNode(
        id: 'root',
        type: 'column',
        props: {},
        children: [?form],
      )
      ..shownAt = DateTime.now();
    _render(e);
  }

  String _video(Map<String, dynamic> args) {
    final String? url = str(args['url'])?.trim();
    if (url == null || url.isEmpty) {
      final String? control = str(args['control']);
      final num? seek = numOf(args['seek']);
      if (control == null && seek == null) {
        return 'error: video needs a url (or control/seek for the current '
            'video)';
      }
      final DisplayViewEntry? e = current;
      final bool hasVideo =
          e != null && e.root.walk().any((n) => n.type == 'video');
      if (!hasVideo) return 'error: no video on screen';
      _videoCommands.value = VideoCommand(
        ++_videoSeq,
        play: control == null ? null : control == 'play',
        seekSeconds: seek?.toDouble(),
      );
      return 'ok: ${[?control, if (seek != null) 'seek ${seek}s'].join(', ')}';
    }
    if (isUnsupportedVideoPage(url)) {
      return 'error: only direct video files (mp4, mov, m3u8...) can be '
          'played; YouTube and other web pages are not supported';
    }
    if (!isPlayableVideoUrl(url)) {
      return 'error: video url must be https://, http://, file:// or an '
          'absolute path';
    }
    _dropPartial();
    final DisplayViewEntry e = _newEntry('video');
    final String title =
        str(args['title']) ?? Uri.tryParse(url)?.pathSegments.lastOrNull ?? url;
    e
      ..title = title
      ..root = DisplayNode(
        id: 'root',
        type: 'column',
        props: {'fill': true},
        children: [
          DisplayNode(
            id: 'video1',
            type: 'video',
            props: {
              'url': url,
              'caption': title,
              if (args['loop'] == true) 'loop': true,
              'full': true,
            },
          ),
        ],
      );
    _render(e);
    _notify();
    return 'ok: playing ${quote(title)} full-window as view ${_cursor + 1} '
        '(id video1)';
  }

  String _clear() {
    _dropPartial();
    if (isEmpty) return 'ok: already empty';
    _lastCursor = _cursor;
    _cursor = -1;
    _notify();
    return 'ok: cleared (the view stays in the timeline; back restores it)';
  }

  String _update(Map<String, dynamic> args) {
    final DisplayViewEntry? e = current;
    if (e == null) return 'error: nothing on screen';
    final String? id = str(args['id']);
    if (id == null) return 'error: update needs an id';
    final (DisplayNode, DisplayNode?)? found = findNode(e.root, id);
    if (found == null) {
      return 'error: no component "$id" in the current view. '
          'ids: ${_ids(e).join(', ')}';
    }
    DisplayNode node = found.$1;
    final DisplayNode? parent = found.$2;
    final changes = <String>[];

    if (args['remove'] == true) {
      if (parent == null) return 'error: cannot remove the root';
      parent.children.remove(node);
      _render(e);
      _notify();
      return 'ok: removed $id';
    }

    final parser = NodeParser()..reserve(e.root);
    final Object? set = args['set'] ?? args['props'];
    if (set is Map) {
      final String? newType = NodeParser.normalizeType(set['type']);
      if (newType != null && newType != node.type) {
        if (parent == null) return 'error: cannot change the root type';
        final replacement = DisplayNode(
          id: node.id,
          type: newType,
          props: NodeParser.normalizeProps(newType, set),
        );
        if (replacement.isLayout) {
          replacement.children.addAll(parser.parseList(set['children']));
        }
        parent.children[parent.children.indexOf(node)] = replacement;
        node = replacement;
      } else {
        node.props = NodeParser.normalizeProps(node.type, {
          ...node.props,
          ...set,
        });
        if (node.isLayout && set['children'] is List) {
          node.children
            ..clear()
            ..addAll(parser.parseList(set['children']));
        }
      }
      changes.add('set ${set.keys.join(', ')}');
    }

    final Object? append = args['append'];
    if (append is List && append.isNotEmpty) {
      if (node.isLayout) {
        node.children.addAll(parser.parseList(append));
      } else {
        final String key = switch (node.type) {
          'table' => 'rows',
          'form' => 'fields',
          _ => 'items',
        };
        if (!const {
          'cards',
          'stats',
          'kv',
          'chips',
          'buttons',
          'table',
          'form',
        }.contains(node.type)) {
          return 'error: cannot append to a ${node.type}';
        }
        node.props = NodeParser.normalizeProps(node.type, {
          ...node.props,
          key: [...listOf(node.props[key]), ...append],
        });
      }
      changes.add('appended ${append.length}');
    }

    final Object? values = args['values'];
    if (values is Map && values.isNotEmpty) {
      if (node.type != 'form') return 'error: "$id" is not a form';
      values.forEach((k, v) {
        _adapter.setData(e.surfaceId, '${formPath(node.id)}/$k', v);
      });
      changes.add('values ${values.keys.join(', ')}');
    }

    if (changes.isEmpty) {
      return 'error: nothing to update (use set, append, values or remove)';
    }
    _render(e);
    _notify();
    final String ords = node.selectableCount > 0 && node.ord > 0
        ? ' (ordinals ${node.ord}-${node.ord + node.selectableCount - 1})'
        : '';
    return 'ok: updated $id: ${changes.join('; ')}$ords';
  }

  /// Applies the entry's model to its genui surface.
  void _render(DisplayViewEntry e) {
    e.ordinals = assignOrdinals(e.root);
    _adapter.render(e.surfaceId, flattenToComponents(e.root));
    // Form defaults go into the data model once per field.
    for (final DisplayNode n in e.root.walk()) {
      if (n.type != 'form') continue;
      for (final Object? f in listOf(n.props['fields'])) {
        if (f is! Map || !f.containsKey('default')) continue;
        final String key = '${n.id}/${f['name']}';
        if (!e._defaultsApplied.add(key)) continue;
        _adapter.setData(
          e.surfaceId,
          '${formPath(n.id)}/${f['name']}',
          _coerceDefault(f),
        );
      }
    }
  }

  static Object? _coerceDefault(Map f) {
    final Object? v = f['default'];
    switch (f['type']) {
      case 'number':
      case 'slider':
        return numOf(v);
      case 'checkbox':
        return v == true || v == 'true';
      case 'select':
        final List<dynamic> options = listOf(f['options']);
        if (v is num && !options.contains(cellText(v))) {
          final int i = v.toInt() - 1;
          return i >= 0 && i < options.length ? options[i] : null;
        }
        return v == null ? null : cellText(v);
      default:
        return v == null ? null : cellText(v);
    }
  }

  // -------------------------------------------------------------------------
  // Progressive rendering.

  void streamPartial(String toolName, String partialArgsJson) {
    final String tool = _bareName(toolName);
    if (tool != 'show' && tool != 'form') return;
    _pendingTool = tool;
    _pendingJson = partialArgsJson;
    if (_partialTimer != null) return;
    final Duration since = DateTime.now().difference(_lastPartialApply);
    if (since >= _partialInterval) {
      _applyPartial();
    } else {
      _partialTimer = Timer(_partialInterval - since, () {
        _partialTimer = null;
        _applyPartial();
      });
    }
  }

  void cancelPartial() => _dropPartial();

  void _applyPartial() {
    final String? tool = _pendingTool;
    final String? json = _pendingJson;
    _pendingTool = _pendingJson = null;
    if (tool == null || json == null || _disposed) return;
    _lastPartialApply = DateTime.now();
    final Object? parsed;
    try {
      parsed = parsePartialJson(
        json,
        atomicKeys: {...atomicJsonKeys, 'default'},
      );
    } on FormatException {
      return;
    }
    if (parsed is! Map) return;
    final Map<String, dynamic> args = parsed.cast<String, dynamic>();
    final String kind = tool == 'form' ? 'form' : 'view';
    final String? title = str(args['title']);
    final bool hasContent = tool == 'form'
        ? listOf(args['fields']).isNotEmpty
        : listOf(args['body']).isNotEmpty;
    if (title == null && !hasContent) return;
    try {
      DisplayViewEntry? e = _partial;
      if (e == null || e.kind != kind) {
        if (e != null) _removeEntry(e, _partialPrevCursor);
        _partialPrevCursor = _cursor;
        e = _newEntry(kind)..partial = true;
        _partial = e;
      }
      if (kind == 'form') {
        _fillForm(e, args);
      } else {
        e
          ..title = title ?? ''
          ..subtitle = str(args['subtitle'])
          ..root = NodeParser().parseRoot(args['body']);
        _render(e);
      }
      _notify();
    } catch (err) {
      if (kDebugMode) debugPrint('[display] partial render failed: $err');
    }
  }

  void _cancelPendingPartial() {
    _partialTimer?.cancel();
    _partialTimer = null;
    _pendingTool = _pendingJson = null;
  }

  void _dropPartial() {
    _cancelPendingPartial();
    final DisplayViewEntry? p = _partial;
    if (p == null) return;
    _partial = null;
    _removeEntry(p, _partialPrevCursor);
    _notify();
  }

  // -------------------------------------------------------------------------
  // User actions.

  /// Called by the view for A2UI user actions dispatched by catalog widgets.
  void handleAction(
    String surfaceId,
    String componentId,
    String action,
    Map<String, Object?> context,
  ) {
    final DisplayViewEntry? e = _entries
        .where((x) => x.surfaceId == surfaceId)
        .firstOrNull;
    if (e == null) return;
    final DisplayNode? node = findNode(e.root, componentId)?.$1;
    if (node == null) return;
    final int index = numOf(context['index'])?.toInt() ?? 0;
    String? text;
    switch (action) {
      case DisplayActions.tap:
      case DisplayActions.press:
        final OrdinalRef? ref = e.ordinals
            .where((r) => r.nodeId == componentId && r.index == index)
            .firstOrNull;
        if (ref == null) return;
        final String what = switch (ref.kind) {
          'row' => 'tapped row',
          'chip' => 'tapped chip',
          'button' => 'pressed button',
          _ => 'tapped item',
        };
        text =
            '$what ${ref.ordinal} ${quote(ref.label, 120)} in '
            '${quote(e.title)}';
      case DisplayActions.submit:
        final Map<String, Object?> values = _formValues(e, node);
        text =
            'form ${quote(e.title.isEmpty ? node.id : e.title)} '
            'submitted: ${jsonEncode(values)}';
        node.props = {...node.props, 'submitted': true};
        _render(e);
        _notify();
    }
    if (text == null) return;
    _actions.add(_Action(text));
    if (_actions.length > 5) _actions.removeAt(0);
    if (!_events.isClosed) _events.add('[display] $text');
  }

  Map<String, Object?> _formValues(DisplayViewEntry e, DisplayNode form) {
    final Object? raw = _adapter.getData(e.surfaceId, formPath(form.id));
    final Map values = raw is Map ? raw : const {};
    final out = <String, Object?>{};
    for (final Object? f in listOf(form.props['fields'])) {
      if (f is! Map) continue;
      final Object? v = values[f['name']];
      if (v != null) out[f['name'] as String] = v;
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // get_state.

  String getState() {
    final buf = StringBuffer();
    final DisplayViewEntry? e = current;
    if (e == null) {
      buf.writeln('display empty (idle animation)');
    } else {
      buf.writeln(
        '${e.kind} ${_cursor + 1}/${_entries.length} ${quote(e.title)} '
        '(shown ${_ago(e.shownAt)}${e.partial ? ', still rendering' : ''})',
      );
      if (e.subtitle != null) buf.writeln('  subtitle ${quote(e.subtitle!)}');
      if (_overflow > 0) {
        buf.writeln('  OVERFLOW: ~${_overflow.round()} px at the bottom are cut off (the display '
            'never scrolls). Show less or split it into several views.');
      }
      for (final DisplayNode n in e.root.children) {
        _describe(buf, e, n, 1);
      }
    }
    if (_entries.isNotEmpty) {
      final String items = [
        for (var i = 0; i < _entries.length; i++)
          '${i + 1} ${quote(_entries[i].title, 40)}'
              '${i == _cursor ? ' (current)' : ''}',
      ].join(', ');
      buf.writeln('timeline: $items');
    }
    if (_actions.isNotEmpty) {
      buf.writeln('recent user actions:');
      for (final _Action a in _actions.reversed.take(3)) {
        buf.writeln('  ${a.text} (${_ago(a.at)})');
      }
    }
    return buf.toString().trimRight();
  }

  void _describe(
    StringBuffer buf,
    DisplayViewEntry e,
    DisplayNode n,
    int depth,
  ) {
    final String pad = '  ' * depth;
    final String pad2 = '  ' * (depth + 1);
    final Map<String, dynamic> p = n.props;
    switch (n.type) {
      case 'heading':
      case 'text':
        buf.writeln('$pad${n.type} ${n.id} ${quote(cellText(p['text']))}');
      case 'cards':
        buf.writeln('${pad}cards ${n.id}');
        for (final r in e.ordinals.where((r) => r.nodeId == n.id)) {
          buf.writeln('$pad2[${r.ordinal}] ${quote(r.label)}');
        }
      case 'table':
        final List<dynamic> cols = listOf(p['columns']);
        buf.writeln(
          '${pad}table ${n.id}${cols.isEmpty ? '' : ': ${cols.join(' | ')}'}',
        );
        final List<OrdinalRef> rows = e.ordinals
            .where((r) => r.nodeId == n.id)
            .toList();
        for (final r in rows.take(40)) {
          buf.writeln('$pad2[${r.ordinal}] ${r.label}');
        }
        if (rows.length > 40) {
          buf.writeln('$pad2… ${rows.length - 40} more rows');
        }
      case 'chips':
      case 'buttons':
        final String items = e.ordinals
            .where((r) => r.nodeId == n.id)
            .map((r) => '[${r.ordinal}] ${quote(r.label, 40)}')
            .join(' ');
        buf.writeln('$pad${n.type} ${n.id}: $items');
      case 'stats':
        final String items = listOf(p['items'])
            .whereType<Map>()
            .map((s) {
              final String delta = s['delta'] == null ? '' : ' (${s['delta']})';
              return '${s['label'] ?? ''}=${s['value'] ?? ''}$delta';
            })
            .join(', ');
        buf.writeln('${pad}stats ${n.id}: $items');
      case 'kv':
        final String items = listOf(p['items'])
            .whereType<List>()
            .map((kv) => '${kv[0]}=${kv.length > 1 ? kv[1] : ''}')
            .join('; ');
        buf.writeln('${pad}kv ${n.id}: $items');
      case 'progress':
        final num? v = p['value'] as num?;
        buf.writeln(
          '${pad}progress ${n.id}'
          '${p['label'] != null ? ' ${quote(p['label'] as String)}' : ''} '
          '${v == null ? 'indeterminate' : '${(v * 100).round()}%'}',
        );
      case 'image':
        buf.writeln(
          '${pad}image ${n.id}'
          '${p['caption'] != null ? ' ${quote(p['caption'] as String)}' : ''}',
        );
      case 'video':
        final VideoStatus? st = _videoStatus[n.id];
        final String status = st == null
            ? ''
            : st.error != null
            ? ' error'
            : ' ${st.playing ? 'playing' : 'paused'} '
                  '${_mmss(st.position)}/${_mmss(st.duration)}';
        buf.writeln('${pad}video ${n.id} ${p['url']}$status');
      case 'divider':
        break;
      case 'row':
      case 'column':
      case 'grid':
        buf.writeln('$pad${n.type} ${n.id}');
        for (final DisplayNode c in n.children) {
          _describe(buf, e, c, depth + 1);
        }
      case 'form':
        final Object? raw = _adapter.getData(e.surfaceId, formPath(n.id));
        final Map values = raw is Map ? raw : const {};
        buf.writeln(
          '${pad}form ${n.id} '
          '(${p['submitted'] == true ? 'submitted' : 'not submitted yet'})',
        );
        for (final Object? f in listOf(p['fields'])) {
          if (f is! Map) continue;
          final Object? v = values[f['name']];
          final String value = v == null
              ? 'empty'
              : v is String
              ? '= "$v"'
              : '= ${formatFieldValue(v)}';
          final String choices = f['type'] == 'select'
              ? ': ${e.ordinals.where((r) => r.nodeId == n.id && r.field == f['name']).map((r) => '[${r.ordinal}] ${r.label}').join(' ')}'
              : '';
          buf.writeln(
            '$pad2${f['name']} (${f['type']}'
            '${f['required'] == true ? ', required' : ''}) $value$choices',
          );
        }
    }
  }

  static String _mmss(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  static String _ago(DateTime t) {
    final Duration d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return '${d.inSeconds}s ago';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    return '${d.inHours}h ago';
  }

  List<String> _ids(DisplayViewEntry e) => [
    for (final DisplayNode n in e.root.walk())
      if (n.id != 'root') n.id,
  ];

  String _componentSummary(DisplayViewEntry e) {
    final parts = <String>[];
    for (final DisplayNode n in e.root.walk()) {
      if (n.id == 'root') continue;
      final int count = n.selectableCount;
      parts.add(
        count > 0 && n.ord > 0
            ? '${n.id} [${n.ord}-${n.ord + count - 1}]'
            : n.id,
      );
    }
    if (parts.length > 24) {
      return '${parts.take(24).join(', ')}, … (${parts.length - 24} more)';
    }
    return parts.isEmpty ? 'none' : parts.join(', ');
  }

  // -------------------------------------------------------------------------

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _partialTimer?.cancel();
    _events.close();
    _videoCommands.dispose();
    _adapter.dispose();
    super.dispose();
  }
}
