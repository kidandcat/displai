/// Custom views the model programs itself: an HTML/CSS/JS page in a WebView (WKWebView on
/// macOS, Android WebView on the phone), with the display theme injected as CSS variables and
/// a small `minerva` bridge object for data in and events out.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart'
    show WebKitWebViewController;

import 'theme.dart';

/// Base URL of every page: a reserved name that never resolves, so pages get a real https
/// origin (localStorage, fetch to CDNs) without pointing at anyone's server.
const String htmlBaseUrl = 'https://display.minerva.invalid/';

/// The page around the model's HTML: theme variables, defaults and the bridge, all on one line
/// so the line numbers of JS errors match the model's HTML.
String htmlDocument(String html, {required double scale, String? dataJson}) {
  // Inside a <script>: "</" would end it.
  final String data = dataJson == null || dataJson.isEmpty
      ? 'null'
      : dataJson.replaceAll('</', r'<\/');
  String css(Color c) =>
      'rgba(${(c.r * 255).round()},${(c.g * 255).round()},${(c.b * 255).round()},'
      '${c.a.toStringAsFixed(3)})';
  final String head =
      '<meta charset="utf-8"><meta name="viewport" content="width=device-width,'
      'initial-scale=1,user-scalable=no"><style>:root{color-scheme:dark;'
      '--bg:${css(DisplayColors.background)};--surface:${css(DisplayColors.surface)};'
      '--surface2:${css(DisplayColors.surfaceHigh)};--border:${css(DisplayColors.border)};'
      '--border2:${css(DisplayColors.borderStrong)};--accent:${css(DisplayColors.accent)};'
      '--accent2:${css(DisplayColors.accentSecondary)};--text:${css(DisplayColors.text)};'
      '--muted:${css(DisplayColors.textMuted)};--faint:${css(DisplayColors.textFaint)};'
      '--positive:${css(DisplayColors.positive)};--negative:${css(DisplayColors.negative)};'
      '--s:${scale.toStringAsFixed(3)}}'
      'html,body{margin:0;background:transparent;color:var(--text);'
      'font-family:-apple-system,BlinkMacSystemFont,system-ui,Roboto,"Segoe UI",sans-serif;'
      'font-size:calc(22px*var(--s));line-height:1.45;-webkit-font-smoothing:antialiased}'
      '</style><script>$_bridge;window.minerva.data=$data;</script>';
  final RegExp headTag = RegExp(r'<head[^>]*>', caseSensitive: false);
  final RegExpMatch? h = headTag.firstMatch(html);
  if (h != null) return html.replaceRange(h.end, h.end, head);
  final RegExpMatch? root = RegExp(
    r'<html[^>]*>',
    caseSensitive: false,
  ).firstMatch(html);
  if (root != null) {
    return html.replaceRange(root.end, root.end, '<head>$head</head>');
  }
  return '<!doctype html><html><head>$head</head><body>$html</body></html>';
}

const String _bridge =
    '(function(){'
    'function post(m){try{MinervaBridge.postMessage(JSON.stringify(m))}catch(e){}}'
    'function str(v){if(typeof v==="string")return v;try{return JSON.stringify(v)}catch(e){return String(v)}}'
    'window.minerva={data:null,onData:null,'
    'send:function(v){post({t:"send",v:str(v)})},'
    'state:function(v){post({t:"state",v:str(v)})},'
    '_data:function(d){this.data=d;'
    'if(typeof this.onData==="function"){try{this.onData(d)}catch(e){post({t:"error",v:"onData: "+e})}}'
    'window.dispatchEvent(new CustomEvent("minerva-data",{detail:d}))}};'
    'window.addEventListener("error",function(e){var t=e.target;'
    'if(t&&t!==window&&(t.src||t.href)){post({t:"error",v:"failed to load "+(t.src||t.href)});return}'
    'post({t:"error",v:(e.message||"error")+(e.lineno?" (line "+e.lineno+")":"")})},true);'
    'window.addEventListener("unhandledrejection",function(e){var r=e.reason;'
    'post({t:"error",v:"unhandled rejection: "+(r&&r.message||r)})});'
    'var ce=console.error;console.error=function(){'
    'post({t:"error",v:Array.prototype.map.call(arguments,str).join(" ")});ce.apply(console,arguments)};'
    'window.addEventListener("load",function(){var d=document.documentElement;'
    'post({t:"loaded",w:d.scrollWidth,h:d.scrollHeight,vw:innerWidth,vh:innerHeight})})'
    '})()';

/// Pages on screen, so a capture only asks the platform when there is one.
int _livePages = 0;

const MethodChannel _pagesChannel = MethodChannel('minerva/webview');

/// Snapshots of the pages on screen with their frames (logical pixels from the top-left of the
/// Flutter view): Flutter's own capture leaves platform views blank, so the display's snapshot
/// draws these over it.
Future<List<(Rect, ui.Image)>> capturePages() async {
  if (_livePages == 0) return const [];
  final List<Object?>? raw;
  try {
    raw = await _pagesChannel
        .invokeListMethod<Object?>('snapshot')
        .timeout(const Duration(seconds: 3));
  } catch (_) {
    return const [];
  }
  final out = <(Rect, ui.Image)>[];
  for (final Object? m in raw ?? const []) {
    if (m is! Map || m['png'] is! Uint8List) continue;
    double n(String k) => (m[k] as num? ?? 0).toDouble();
    try {
      final ui.Codec codec = await ui.instantiateImageCodec(m['png'] as Uint8List);
      final ui.FrameInfo frame = await codec.getNextFrame();
      out.add((Rect.fromLTWH(n('x'), n('y'), n('w'), n('h')), frame.image));
    } catch (_) {
      // A page that cannot be decoded stays blank in the capture.
    }
  }
  return out;
}

/// A custom page on the display.
class DisplayHtml extends StatefulWidget {
  const DisplayHtml({
    super.key,
    required this.componentId,
    required this.html,
    this.dataJson,
    this.height,
    this.fill = false,
    required this.onMessage,
  });

  final String componentId;
  final String html;

  /// JSON of the data given to the page (`minerva.data`, `minerva.onData`).
  final String? dataJson;

  /// Height in display pixels (scaled) when inline; ignored when [fill].
  final double? height;

  /// Takes all the room it gets (a view of its own).
  final bool fill;

  /// `minerva.send(...)` from the page.
  final void Function(String text) onMessage;

  @override
  State<DisplayHtml> createState() => _DisplayHtmlState();
}

class _DisplayHtmlState extends State<DisplayHtml> {
  late final WebViewController _web;

  /// The bridge and the delegate are set before any page loads.
  late final Future<void> _ready;
  DisplayRuntime? _runtime;
  HtmlStatus _status = HtmlStatus(html: '');
  double? _scale;

  @override
  void initState() {
    super.initState();
    _livePages++;
    _web = WebViewController();
    _ready = _setUp();
  }

  Future<void> _setUp() async {
    await _web.setJavaScriptMode(JavaScriptMode.unrestricted);
    // Transparent, so the display's background shows through the page.
    if (_web.platform is WebKitWebViewController) {
      final int id = (_web.platform as WebKitWebViewController).webViewIdentifier;
      try {
        await _pagesChannel.invokeMethod<bool>('transparent', id);
      } catch (_) {
        // Without it the page keeps WebKit's own background.
      }
    } else {
      try {
        await _web.setBackgroundColor(Colors.transparent);
      } catch (_) {}
    }
    await _web.addJavaScriptChannel(
      'MinervaBridge',
      onMessageReceived: (m) => _onBridge(m.message),
    );
    await _web.setNavigationDelegate(
      NavigationDelegate(
        // The page stays put: links and scripts cannot navigate it away from the view.
        onNavigationRequest: (r) =>
            r.isMainFrame && _status.loaded
                ? NavigationDecision.prevent
                : NavigationDecision.navigate,
        onPageFinished: (_) {
          if (_status.loaded) return;
          _status.loaded = true;
          _report();
        },
        onWebResourceError: (e) {
          if (e.isForMainFrame == false) return;
          _addError('load error: ${e.description}');
        },
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _runtime = DisplayScope.maybeOf(context);
    final double s = DisplayScale.of(context);
    if (_scale != s) {
      _scale = s;
      _load();
    }
  }

  @override
  void didUpdateWidget(DisplayHtml old) {
    super.didUpdateWidget(old);
    if (old.html != widget.html) {
      _load();
    } else if (old.dataJson != widget.dataJson) {
      final String data = widget.dataJson ?? 'null';
      _web
          .runJavaScript('window.minerva&&window.minerva._data($data)')
          .catchError((Object e) => _addError('data: $e'));
    }
  }

  Future<void> _load() async {
    _status = HtmlStatus(html: widget.html);
    _report();
    final String doc = htmlDocument(
      widget.html,
      scale: _scale ?? 1,
      dataJson: widget.dataJson,
    );
    try {
      await _ready;
      if (!mounted || _status.html != widget.html) return;
      await _web.loadHtmlString(doc, baseUrl: htmlBaseUrl);
    } catch (e) {
      _addError('load failed: $e');
    }
  }

  void _onBridge(String raw) {
    final Object? m;
    try {
      m = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (m is! Map) return;
    final String v = '${m['v'] ?? ''}';
    switch (m['t']) {
      case 'send':
        widget.onMessage(v);
      case 'state':
        _status.state = v;
        _report();
      case 'error':
        _addError(v);
      case 'loaded':
        _status
          ..loaded = true
          ..content = Size(
            (m['w'] as num? ?? 0).toDouble(),
            (m['h'] as num? ?? 0).toDouble(),
          )
          ..viewport = Size(
            (m['vw'] as num? ?? 0).toDouble(),
            (m['vh'] as num? ?? 0).toDouble(),
          );
        _report();
    }
  }

  void _addError(String text) {
    final String one = text.replaceAll('\n', ' ');
    _status.errors.add(one.length > 300 ? '${one.substring(0, 299)}…' : one);
    if (_status.errors.length > 5) _status.errors.removeAt(0);
    if (kDebugMode) debugPrint('[html ${widget.componentId}] $one');
    _report();
  }

  void _report() => _runtime?.reportHtml(widget.componentId, _status);

  @override
  void dispose() {
    _livePages--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double s = DisplayScale.of(context);
    final Widget view = ClipRRect(
      borderRadius: BorderRadius.circular(widget.fill ? 0 : 18 * s),
      child: WebViewWidget(
        controller: _web,
        // Every touch goes to the page (games, drags, its own scrolling).
        gestureRecognizers: {
          Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
        },
      ),
    );
    if (widget.fill) return SizedBox.expand(child: view);
    return SizedBox(height: (widget.height ?? 420) * s, child: view);
  }
}
