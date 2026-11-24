/// Thin adapter over genui's [SurfaceController] (A2UI v0.9 renderer core).
///
/// The rest of the display layer talks to genui only through this class, so
/// genui (alpha, 0.x) can be upgraded or swapped without touching the tool
/// layer. Each view of the display is one A2UI surface; the components are
/// diffed so only changed ones are sent with `updateComponents`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:a2ui_core/a2ui_core.dart' as a2ui;
import 'package:flutter/foundation.dart';
import 'package:genui/genui.dart';

import 'catalog.dart';

class GenuiSurfaceAdapter {
  GenuiSurfaceAdapter() {
    _errorSub = _controller.onSubmit.listen((message) {
      // genui reports schema validation and runtime errors here. We do not
      // forward them to the model; they are kept for debugging and tests.
      final String text = message.parts.map((p) => p.toString()).join(' ');
      errors.add(text);
      if (errors.length > 20) errors.removeAt(0);
      if (kDebugMode) debugPrint('[display] genui: $text');
    });
  }

  final SurfaceController _controller = SurfaceController(
    catalogs: [displayCatalog],
  );
  late final StreamSubscription<ChatMessage> _errorSub;
  // Last JSON sent per surface and component, for diffing.
  final Map<String, Map<String, String>> _sent = {};

  /// Recent genui error reports (validation, runtime).
  final List<String> errors = [];

  void createSurface(String surfaceId) {
    _controller.handleMessage(
      a2ui.CreateSurfaceMessage(
        surfaceId: surfaceId,
        catalogId: displayCatalogId,
      ),
    );
    _sent[surfaceId] = {};
  }

  void deleteSurface(String surfaceId) {
    if (_sent.remove(surfaceId) == null) return;
    _controller.handleMessage(a2ui.DeleteSurfaceMessage(surfaceId: surfaceId));
  }

  /// Sends the components that changed since the last call for [surfaceId].
  void render(String surfaceId, Map<String, Map<String, dynamic>> components) {
    final Map<String, String>? sent = _sent[surfaceId];
    if (sent == null) return;
    final changed = <Map<String, dynamic>>[];
    components.forEach((id, comp) {
      final String json = jsonEncode(comp);
      if (sent[id] != json) {
        // A decoded copy: genui never shares mutable lists with our model.
        changed.add(jsonDecode(json) as Map<String, dynamic>);
        sent[id] = json;
      }
    });
    if (changed.isEmpty) return;
    _controller.handleMessage(
      a2ui.UpdateComponentsMessage(surfaceId: surfaceId, components: changed),
    );
  }

  void setData(String surfaceId, String path, Object? value) {
    if (!_sent.containsKey(surfaceId)) return;
    _controller.handleMessage(
      a2ui.UpdateDataModelMessage(
        surfaceId: surfaceId,
        path: path,
        value: value,
      ),
    );
  }

  Object? getData(String surfaceId, String path) {
    if (!_sent.containsKey(surfaceId)) return null;
    return _controller
        .contextFor(surfaceId)
        .dataModel
        .getValue<Object>(DataPath(path));
  }

  SurfaceContext contextFor(String surfaceId) =>
      _controller.contextFor(surfaceId);

  void dispose() {
    _errorSub.cancel();
    _controller.dispose();
  }
}
