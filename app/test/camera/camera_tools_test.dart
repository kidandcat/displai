import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/camera/camera_tools.dart';
import 'package:minerva/remote/remote_assistant.dart';

const _channel = MethodChannel(MacCamera.channelName);

final _macJpeg = Uint8List.fromList([0xff, 0xd8, 1, 2, 3]);
final _phoneJpeg = Uint8List.fromList([0xff, 0xd8, 9, 8, 7]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late Object? Function(MethodCall) capture;
  late List<Map<String, dynamic>> phoneCalls;
  late Map<String, dynamic>? Function() phoneReply;
  late bool onPhone;
  late Directory dir;
  late CameraTools tools;

  setUp(() {
    calls = [];
    phoneCalls = [];
    onPhone = false;
    capture = (_) => {'jpeg': _macJpeg, 'camera': 'FaceTime HD Camera'};
    phoneReply = () => {'text': 'photo', 'jpeg': base64Encode(_phoneJpeg)};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (c) async {
      calls.add(c);
      switch (c.method) {
        case 'capture':
          return capture(c);
        case 'prepare':
          final data = (c.arguments as Map)['data'] as Uint8List;
          // Full: the photo as given; small: tagged so the test can tell them apart.
          return {'full': data, 'small': Uint8List.fromList([...data, 0]), 'width': 1920, 'height': 1080};
      }
      throw MissingPluginException();
    });
    dir = Directory.systemTemp.createTempSync('minerva-camera-test');
    tools = CameraTools(
      onPhone: () => onPhone,
      phone: (args) async {
        phoneCalls.add(args);
        return phoneReply();
      },
      dir: dir.path,
      now: () => DateTime(2026, 11, 27, 9, 5, 3),
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
    dir.deleteSync(recursive: true);
  });

  test('at the Mac it takes the photo with the Mac\'s camera and saves it', () async {
    final r = await tools.call('camera', {});
    expect(r.isError, false);
    expect([for (final c in calls) c.method], ['capture', 'prepare']);
    expect((calls.last.arguments as Map)['maxSide'], CameraTools.modelSide);
    final path = '${dir.path}/photo-20261127-090503.jpg';
    expect(r.text, 'Photo from the Mac\'s camera (FaceTime HD Camera), 1920×1080, saved to $path');
    expect(File(path).readAsBytesSync(), _macJpeg);
    expect(r.jpeg, [..._macJpeg, 0]);
    expect(r.png, isNull);
    expect(phoneCalls, isEmpty);
  });

  test('a second photo in the same second gets its own file', () async {
    await tools.call('camera', {});
    final r = await tools.call('camera', {});
    expect(r.text, endsWith('photo-20261127-090503-2.jpg'));
  });

  test('on the phone it uses the phone\'s camera, back by default', () async {
    onPhone = true;
    final r = await tools.call('camera', {});
    expect(r.isError, false);
    expect(phoneCalls, [
      {'facing': 'back'},
    ]);
    expect([for (final c in calls) c.method], ['prepare']);
    expect((calls.single.arguments as Map)['data'], _phoneJpeg);
    expect(r.text, startsWith('Photo from the phone\'s back camera, 1920×1080'));
    expect(r.jpeg, [..._phoneJpeg, 0]);
  });

  test('device and facing choose the camera', () async {
    onPhone = true;
    await tools.call('camera', {'facing': 'front'});
    expect(phoneCalls.last, {'facing': 'front'});
    final r = await tools.call('camera', {'device': 'mac'});
    expect(r.text, contains('Mac\'s camera'));
    expect(calls.where((c) => c.method == 'capture'), hasLength(1));
  });

  test('the phone only while it is connected', () async {
    final r = await tools.call('camera', {'device': 'phone'});
    expect(r.isError, true);
    expect(r.text, contains('not connected'));
    expect(phoneCalls, isEmpty);
  });

  test('phone errors and silence come back as errors', () async {
    onPhone = true;
    phoneReply = () => {'text': 'error: the phone app has no access to the camera', 'error': true};
    var r = await tools.call('camera', {});
    expect(r.isError, true);
    expect(r.text, 'error: the phone app has no access to the camera');

    phoneReply = () => null;
    r = await tools.call('camera', {});
    expect(r.text, contains('did not answer'));

    // A phone app from before the camera.
    phoneReply = () => {'text': 'error: unknown display tool "camera"', 'error': true};
    r = await tools.call('camera', {});
    expect(r.text, contains('too old'));
    expect(calls, isEmpty);
    expect(dir.listSync(), isEmpty);
  });

  test('no camera permission on the Mac says where to allow it', () async {
    capture = (_) => throw PlatformException(code: 'no_camera', message: 'Minerva has no access to the camera');
    final r = await tools.call('camera', {});
    expect(r.isError, true);
    expect(r.text, contains('Ask the user to allow'));
  });

  test('bad arguments', () async {
    expect((await tools.call('camera', {'device': 'tv'})).isError, true);
    expect((await tools.call('camera', {'facing': 'up'})).isError, true);
    expect(calls, isEmpty);
  });

  group('phone app', () {
    test('answers with the photo as base64 JPEG, or the error', () async {
      final a = RemoteAssistant(relay: 'wss://example.invalid', key: 'k' * 43);
      final fronts = <bool>[];
      a.capturePhoto = ({bool front = false}) async {
        fronts.add(front);
        return _phoneJpeg;
      };
      expect(await a.photoResult({'facing': 'back'}), {'text': 'photo', 'jpeg': base64Encode(_phoneJpeg)});
      await a.photoResult({'facing': 'front'});
      expect(fronts, [false, true]);
      a.capturePhoto = ({bool front = false}) async => throw 'the camera failed: busy';
      expect(await a.photoResult({}), {'text': 'error: the camera failed: busy', 'error': true});
    });
  });
}
