import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

/// The phone app's camera, for the desktop brain's `camera` tool (see [RemoteProtocol]): one
/// photo, without a preview, while the app is open.
class PhoneCamera {
  /// The camera runs this long before the photo, so exposure and focus settle.
  static const warmUp = Duration(milliseconds: 800);

  static bool _busy = false;

  /// One JPEG (as the camera wrote it: the desktop turns it upright by its EXIF orientation).
  /// Throws a [String] saying what went wrong.
  static Future<Uint8List> capture({bool front = false}) async {
    // The first photo can wait on Android's permission prompt for longer than the desktop waits.
    if (_busy) throw 'the phone is still taking the previous photo (it may be asking the user to allow the camera)';
    _busy = true;
    try {
      return await _capture(front);
    } finally {
      _busy = false;
    }
  }

  static Future<Uint8List> _capture(bool front) async {
    final List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
    } on CameraException catch (e) {
      throw 'no camera: ${e.description ?? e.code}';
    }
    final want = front ? CameraLensDirection.front : CameraLensDirection.back;
    final camera = cameras.where((c) => c.lensDirection == want).firstOrNull ?? cameras.firstOrNull;
    if (camera == null) throw 'this phone has no camera';
    final controller = CameraController(camera, ResolutionPreset.veryHigh, enableAudio: false);
    try {
      await controller.initialize();
      await Future<void>.delayed(warmUp);
      final shot = await controller.takePicture();
      final bytes = await shot.readAsBytes();
      try {
        await File(shot.path).delete();
      } on FileSystemException {
        // A file in the app's cache: it goes with it.
      }
      return bytes;
    } on CameraException catch (e) {
      throw switch (e.code) {
        'CameraAccessDenied' || 'CameraAccessDeniedWithoutPrompt' || 'CameraAccessRestricted' =>
          'the phone app has no access to the camera: the user has to allow it in the phone\'s settings',
        _ => 'the camera failed: ${e.description ?? e.code}',
      };
    } finally {
      await controller.dispose();
    }
  }
}
