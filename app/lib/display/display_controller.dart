/// The display's tool layer: implements the MCP display tools on top of the
/// genui adapter, keeps the current view, ordinals and user events.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Size;

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

/// One view of the display (a `show`, `form`, `video` or `html`). Each new one replaces the
/// one on screen.
class DisplayViewEntry {
  DisplayViewEntry._(this.seq, this.kind) : surfaceId = 'v$seq';

  final int seq;

  /// 'view', 'form', 'video' or 'html'.
  final String kind;

  /// Drawn edge to edge, without the title (videos and full custom pages).
  bool edgeToEdge = false;

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

/// A credential typed into a vault form (from vault_request). It goes to the vault, never to
/// the brain: [DisplayController.userEvents] gets nothing for it.
class VaultSubmission {
  const VaultSubmission(this.name, this.description, this.fields);

  final String name;
  final String description;

  /// (field name, value, secret).
  final List<(String, String, bool)> fields;

  List<String> get fieldNames => [for (final f in fields) f.$1];

  /// For the phone remote's encrypted link.
  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'fields': [
      for (final (n, v, secret) in fields)
        {'name': n, 'value': v, 'secret': secret},
    ],
  };

  static VaultSubmission? fromJson(Map<String, dynamic> j) {
    final Object? name = j['name'];
    final Object? fields = j['fields'];
    if (name is! String || fields is! List) return null;
    return VaultSubmission(name, '${j['description'] ?? ''}', [
      for (final Object? f in fields)
        if (f is Map) ('${f['name']}', '${f['value'] ?? ''}', f['secret'] != false),
    ]);
  }
}

class _Action {
  _Action(this.text) : at = DateTime.now();
  final String text;
  final DateTime at;
}

class DisplayController extends ChangeNotifier implements DisplayRuntime {
  DisplayController();

  static List<DisplayToolSpec> get toolSpecs => displayToolSpecs;

  final GenuiSurfaceAdapter _adapter = GenuiSurfaceAdapter();
  DisplayViewEntry? _current;
  int _seq = 0;

  /// The last view replaced, whose surface stays until the next replacement so it can fade out.
  DisplayViewEntry? _outgoing;

  final StreamController<String> _events = StreamController.broadcast();
  final StreamController<VaultSubmission> _vault = StreamController.broadcast();
  final List<_Action> _actions = [];

  final ValueNotifier<VideoCommand?> _videoCommands = ValueNotifier(null);
  final Map<String, VideoStatus> _videoStatus = {};
  final Map<String, HtmlStatus> _htmlStatus = {};
  int _videoSeq = 0;

  // Progressive rendering state.
  DisplayViewEntry? _partial;

  /// The view the streaming one replaces, back on screen if the stream is cancelled.
  DisplayViewEntry? _beforePartial;
  String? _pendingTool;
  String? _pendingJson;
  Timer? _partialTimer;
  DateTime _lastPartialApply = DateTime(0);
  static const Duration _partialInterval = Duration(milliseconds: 50);

  bool _disposed = false;

  // -------------------------------------------------------------------------
  // Read API for the view.

  bool get isEmpty => _current == null;

  DisplayViewEntry? get current => _current;

  /// The [DisplayViewEntry.seq] of the newest view so far (0 before the first).
  int get lastSeq => _seq;

  /// How many logical pixels of the current view do not fit on screen (the display never
  /// scrolls: what does not fit is cut). Reported by the view after layout.
  double get overflow => _overflow;
  double _overflow = 0;

  void reportOverflow(double px) => _overflow = px;

  Stream<String> get userEvents => _events.stream;

  /// Credentials submitted in vault forms (their values must go to the vault only).
  Stream<VaultSubmission> get vaultSubmissions => _vault.stream;

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

  @override
  void reportHtml(String componentId, HtmlStatus status) {
    _htmlStatus[componentId] = status;
  }

  /// Waits (up to [timeout]) for the custom pages of the current view to load, then a moment
  /// for their first errors, and describes them: what the tool result tells the model. Empty
  /// when the view has no page.
  Future<String> settleHtml({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    List<DisplayNode> pages() => [
      ...?current?.root.walk().where((n) => n.type == 'html'),
    ];
    if (pages().isEmpty) return '';
    bool ready(DisplayNode n) {
      final HtmlStatus? st = _htmlStatus[n.id];
      return st != null && st.html == n.props['html'] && st.loaded;
    }

    final DateTime until = DateTime.now().add(timeout);
    while (!pages().every(ready) && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    // Scripts that run after load (timers, module imports) fail a little later.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return [for (final n in pages()) _htmlLine(n)].join('\n');
  }

  String _htmlLine(DisplayNode n) {
    final HtmlStatus? st = _htmlStatus[n.id];
    if (st == null || st.html != n.props['html']) {
      return 'page ${n.id}: not rendered yet';
    }
    final parts = <String>[st.loaded ? 'loaded' : 'still loading'];
    final Size? c = st.content, v = st.viewport;
    if (c != null && v != null && v.height > 0) {
      parts.add('viewport ${v.width.round()}x${v.height.round()}');
      if (c.height > v.height + 4 || c.width > v.width + 4) {
        parts.add(
          'content ${c.width.round()}x${c.height.round()} does not fit (the page scrolls)',
        );
      }
    }
    if (st.state != null) parts.add('state ${_clipText(st.state!, 400)}');
    if (st.errors.isNotEmpty) {
      parts.add('JS ERRORS: ${st.errors.join(' | ')}');
    } else if (st.loaded) {
      parts.add('no errors');
    }
    return 'page ${n.id}: ${parts.join('; ')}';
  }

  static String _clipText(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max - 1)}…';

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
        case 'html':
          return _html(args);
        case 'clear':
          return _clear();
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
    if (p != null && p.kind == kind) {
      _partial = null;
      p.partial = false;
      final DisplayViewEntry? before = _beforePartial;
      _beforePartial = null;
      if (before != null) _retire(before);
      return p;
    }
    _unwindPartial();
    return _newEntry(kind);
  }

  /// A new view, on screen in place of the current one.
  DisplayViewEntry _newEntry(String kind) {
    final entry = DisplayViewEntry._(++_seq, kind);
    _adapter.createSurface(entry.surfaceId);
    _replace(entry);
    return entry;
  }

  /// Puts [entry] on screen (null: nothing) and drops the view it replaces, unless that one
  /// waits behind a streaming view.
  void _replace(DisplayViewEntry? entry) {
    final DisplayViewEntry? old = _current;
    _current = entry;
    if (old != null && old != entry && old != _beforePartial) _retire(old);
  }

  /// Deletes [e]'s surface one replacement later, so the view can still fade out.
  void _retire(DisplayViewEntry e) {
    final DisplayViewEntry? prev = _outgoing;
    _outgoing = e;
    if (prev != null && prev != e) _adapter.deleteSurface(prev.surfaceId);
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
    return 'ok: shown ${quote(e.title)}. '
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
    return 'ok: form "${form.id}" shown (fields: $names). The submission will arrive as a '
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
      // Filled, so the form gets the page's height: its fields scroll and the submit button
      // stays visible.
      ..root = DisplayNode(
        id: 'root',
        type: 'column',
        props: {'fill': true},
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
    return 'ok: playing ${quote(title)} full-window (id video1)';
  }

  String _html(Map<String, dynamic> args) {
    final String? html = str(args['html'] ?? args['content'] ?? args['code']);
    if (html == null || html.trim().isEmpty) {
      return 'error: html needs the page (html: HTML with its CSS and JS)';
    }
    _dropPartial();
    final DisplayViewEntry e = _newEntry('html');
    final bool full = args['full'] == true;
    final DisplayNode page = DisplayNode(
      id: str(args['id'])?.trim().isNotEmpty == true
          ? str(args['id'])!.trim()
          : 'page1',
      type: 'html',
      props: NodeParser.normalizeProps('html', {...args, 'fill': true}),
    );
    e
      ..title = str(args['title']) ?? ''
      ..edgeToEdge = full
      ..root = DisplayNode(
        id: 'root',
        type: 'column',
        props: {'fill': true},
        children: [page],
      )
      ..shownAt = DateTime.now();
    _render(e);
    _notify();
    return 'ok: page "${page.id}" shown${full ? ' (edge to edge)' : ''}.';
  }

  /// Wipes the display (before a replay of the display calls, when the display moves between
  /// the desktop and the phone remote).
  void reset() {
    _dropPartial();
    _replace(null);
    _overflow = 0;
    _notify();
  }

  String _clear() {
    _dropPartial();
    if (isEmpty) return 'ok: already empty';
    _replace(null);
    _notify();
    return 'ok: cleared';
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

    // A credential form stays as vault_request made it (so its values keep going to the vault).
    if (str(node.props['vault']) != null && (args['set'] ?? args['props'] ?? args['values'] ?? args['append']) != null) {
      return 'error: "$id" is a credential form; it cannot be changed (call vault_request again)';
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
        if (e != null) _unwindPartial();
        _beforePartial = _current;
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
    if (_unwindPartial()) _notify();
  }

  /// Takes the streaming view off the screen and puts back the view it was replacing. False
  /// when there was none.
  bool _unwindPartial() {
    _cancelPendingPartial();
    final DisplayViewEntry? p = _partial;
    if (p == null) return false;
    _partial = null;
    final DisplayViewEntry? before = _beforePartial;
    _beforePartial = null;
    _current = before;
    _retire(p);
    return true;
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
    final DisplayViewEntry? e = _current;
    if (e == null || e.surfaceId != surfaceId) return;
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
      case DisplayActions.message:
        final String said = cellText(context['text']);
        text =
            'page ${quote(e.title.isEmpty ? node.id : e.title)} '
            '(${node.id}) sent: ${_clipText(said, 2000)}';
      case DisplayActions.submit when str(node.props['vault']) != null:
        _submitVault(e, node);
        return;
      case DisplayActions.cancel:
        final String? vault = str(node.props['vault']);
        text = vault != null
            ? 'credential request $vault cancelled'
            : 'form ${quote(e.title.isEmpty ? node.id : e.title)} cancelled';
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

  /// Hands a vault form's values to [vaultSubmissions] and wipes them from the form.
  void _submitVault(DisplayViewEntry e, DisplayNode form) {
    final Object? raw = _adapter.getData(e.surfaceId, formPath(form.id));
    final Map values = raw is Map ? raw : const {};
    final fields = <(String, String, bool)>[];
    for (final Object? f in listOf(form.props['fields'])) {
      if (f is! Map) continue;
      final String name = '${f['name']}';
      final Object? v = values[name];
      if (v != null && '$v'.isNotEmpty) {
        fields.add((name, '$v', f['type'] == 'secret'));
      }
      _adapter.setData(e.surfaceId, '${formPath(form.id)}/$name', null);
    }
    final submission = VaultSubmission(
      str(form.props['vault'])!,
      str(form.props['vaultDescription']) ?? '',
      fields,
    );
    form.props = {...form.props, 'submitted': true};
    _render(e);
    _notify();
    _actions.add(
      _Action(
        'credential form ${submission.name} submitted '
        '(fields ${submission.fieldNames.join(', ')}; the values went to the vault)',
      ),
    );
    if (_actions.length > 5) _actions.removeAt(0);
    if (!_vault.isClosed) _vault.add(submission);
  }

  /// A form's values for the brain. Secret fields are left out: only vault forms have them.
  Map<String, Object?> _formValues(DisplayViewEntry e, DisplayNode form) {
    final Object? raw = _adapter.getData(e.surfaceId, formPath(form.id));
    final Map values = raw is Map ? raw : const {};
    final out = <String, Object?>{};
    for (final Object? f in listOf(form.props['fields'])) {
      if (f is! Map || f['type'] == 'secret') continue;
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
        '${e.kind} ${quote(e.title)} '
        '(shown ${_ago(e.shownAt)}${e.partial ? ', still rendering' : ''})',
      );
      if (e.subtitle != null) buf.writeln('  subtitle ${quote(e.subtitle!)}');
      if (_overflow > 0) {
        buf.writeln(
          '  OVERFLOW: ~${_overflow.round()} px at the bottom are cut off (the display '
          'never scrolls). Show less.',
        );
      }
      for (final DisplayNode n in e.root.children) {
        _describe(buf, e, n, 1);
      }
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
      case 'html':
        buf.writeln('$pad${_htmlLine(n)}');
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
          '${pad}form ${n.id}'
          '${p['vault'] != null ? ' (credential ${p['vault']} for the vault; you never see its values)' : ''} '
          '(${p['submitted'] == true ? 'submitted' : 'not submitted yet'})',
        );
        for (final Object? f in listOf(p['fields'])) {
          if (f is! Map) continue;
          final Object? v = values[f['name']];
          final String value = v == null || v == ''
              ? 'empty'
              : f['type'] == 'secret' || p['vault'] != null
              ? '= ••• (typed, hidden)'
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
    _vault.close();
    _videoCommands.dispose();
    _adapter.dispose();
    super.dispose();
  }
}
