import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../presence/presence.dart';

/// The orb Minerva floats over the phone's other apps (android/.../OrbOverlay.kt runs it in its
/// own engine, on a transparent window): the Mac's corner orb, with nothing around it. It follows
/// the desktop's presence (channel minerva/orb: state) and the voices (audio).
class PhoneOrbApp extends StatefulWidget {
  const PhoneOrbApp({super.key});

  @override
  State<PhoneOrbApp> createState() => _PhoneOrbAppState();
}

class _PhoneOrbAppState extends State<PhoneOrbApp> {
  static const _channel = MethodChannel('minerva/orb');

  final _presence = PresenceSignal();

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler((call) async {
      final m = call.arguments;
      if (m is! Map) return;
      switch (call.method) {
        case 'state':
          final mode = PresenceMode.values.where((v) => v.name == m['mode']).firstOrNull;
          if (mode != null && _presence.mode != mode) _presence.mode = mode;
          _presence
            ..muted = m['muted'] == true
            ..workers = [for (final id in m['workers'] as List? ?? const []) (id as num).toInt()];
        case 'audio':
          final d = m['d'];
          if (d is Float32List) _presence.addAudio(d, (m['sr'] as num?)?.toInt() ?? 16000);
      }
    });
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    _presence.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.ltr,
        child: LayoutBuilder(
          builder: (context, box) => Center(
            child: ClipOval(
              child: PresenceView(signal: _presence, compact: true, compactSize: box.biggest.shortestSide),
            ),
          ),
        ),
      );
}
