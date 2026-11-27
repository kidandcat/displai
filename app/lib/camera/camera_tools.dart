import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../mcp/display_mcp_server.dart';
import '../tools/tool_provider.dart';

/// A photo made upright and ready by [MacCamera.prepare].
typedef PreparedPhoto = ({Uint8List full, Uint8List small, int width, int height});

/// Dart side of the `minerva/camera` method channel (macos/Runner/CameraCapture.swift).
///
/// Errors arrive as [PlatformException] with codes `no_camera` (access denied), `no_device`,
/// `bad_image`, `failed`.
class MacCamera {
  MacCamera({MethodChannel? channel}) : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'minerva/camera';

  final MethodChannel _channel;

  /// One JPEG from the Mac's camera, and the camera's name.
  Future<({Uint8List jpeg, String camera})> capture() async {
    final m = await _channel.invokeMapMethod<String, Object?>('capture');
    return (jpeg: m!['jpeg'] as Uint8List, camera: '${m['camera'] ?? ''}');
  }

  /// [data] (any image) upright as its EXIF orientation says, as JPEG: full size, and at most
  /// [maxSide] px a side for the model.
  Future<PreparedPhoto> prepare(Uint8List data, {int maxSide = CameraTools.modelSide}) async {
    final m = await _channel.invokeMapMethod<String, Object?>('prepare', {'data': data, 'maxSide': maxSide});
    return (
      full: m!['full'] as Uint8List,
      small: m['small'] as Uint8List,
      width: (m['width'] as num).toInt(),
      height: (m['height'] as num).toInt(),
    );
  }
}

/// Runs the `camera` tool on the phone app (the remote protocol's `tool` message, answered with
/// `{text, error?, jpeg?}`); null when the phone did not answer.
typedef PhoneCameraCall = Future<Map<String, dynamic>?> Function(Map<String, dynamic> args);

/// The brain's camera: a photo from the Mac's camera or from the phone app's, which the brain
/// looks at and which is saved as a JPEG (for telegram_send_file, or anything else).
class CameraTools extends ToolProvider {
  CameraTools({required this.onPhone, required this.phone, MacCamera? mac, String? dir, DateTime Function()? now})
      : mac = mac ?? MacCamera(),
        dir = dir ?? '${Directory.systemTemp.path}/minerva-camera',
        _now = now ?? DateTime.now;

  /// The user is on the phone app (it is connected): the default device is the phone.
  final bool Function() onPhone;

  /// Asks the phone app for a photo.
  final PhoneCameraCall phone;

  final MacCamera mac;

  /// Where the photos are saved.
  final String dir;

  final DateTime Function() _now;

  /// The longest side of the image the model gets (what the models look at anyway).
  static const modelSide = 1568;

  static const tool = McpTool(
    'camera',
    'Take a photo with a camera and look at it. device: mac (the Mac\'s camera) or phone (the '
        'phone app\'s camera, only while it is connected); default: where the user is (phone while '
        'messages carry "[phone WxH]"). facing, on the phone: back (default, what is in front of '
        'the user) or front (the user, a selfie). The photo is saved as a JPEG (path in the '
        'result) to send it with telegram_send_file.',
    {
      'type': 'object',
      'properties': {
        'device': {
          'type': 'string',
          'enum': ['mac', 'phone'],
        },
        'facing': {
          'type': 'string',
          'enum': ['back', 'front'],
        },
      },
    },
  );

  @override
  final List<McpTool> tools = const [tool];

  @override
  Future<ToolResult> call(String name, Map<String, dynamic> args) async {
    if (name != tool.name) return ToolResult.error('error: unknown tool $name');
    final device = args['device'] as String? ?? (onPhone() ? 'phone' : 'mac');
    if (device != 'mac' && device != 'phone') return const ToolResult.error('error: device must be mac or phone');
    final facing = args['facing'] as String? ?? 'back';
    if (facing != 'back' && facing != 'front') return const ToolResult.error('error: facing must be back or front');
    try {
      final Uint8List raw;
      final String what;
      if (device == 'phone') {
        if (!onPhone()) {
          return const ToolResult.error('error: the phone app is not connected; use device mac or ask the user to open it');
        }
        final m = await phone({'facing': facing});
        if (m == null) return const ToolResult.error('error: the phone did not answer (it may have left)');
        final jpeg = m['jpeg'];
        if (m['error'] == true || jpeg is! String) {
          final text = '${m['text'] ?? ''}';
          // A phone app from before the camera treats it as an unknown display tool.
          if (text.contains('unknown display tool')) {
            return const ToolResult.error('error: the phone app is too old to take photos: the user has to install '
                'the new version');
          }
          return ToolResult.error(text.startsWith('error') ? text : 'error: $text');
        }
        raw = base64Decode(jpeg);
        what = 'the phone\'s $facing camera';
      } else {
        final shot = await mac.capture();
        raw = shot.jpeg;
        what = shot.camera.isEmpty ? 'the Mac\'s camera' : 'the Mac\'s camera (${shot.camera})';
      }
      final photo = await mac.prepare(raw);
      final file = await _save(photo.full);
      return ToolResult('Photo from $what, ${photo.width}×${photo.height}, saved to ${file.path}', jpeg: photo.small);
    } on PlatformException catch (e) {
      if (e.code == 'no_camera') {
        return ToolResult.error('error: ${e.message}. Ask the user to allow Minerva there, then retry.');
      }
      return ToolResult.error('error: ${e.message ?? e.code}');
    }
  }

  Future<File> _save(Uint8List jpeg) async {
    await Directory(dir).create(recursive: true);
    final t = _now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
    var file = File('$dir/photo-$stamp.jpg');
    for (var i = 2; file.existsSync(); i++) {
      file = File('$dir/photo-$stamp-$i.jpg');
    }
    return file.writeAsBytes(jpeg, flush: true);
  }
}
