import 'package:displai/computer/computer.dart';
import 'package:displai/computer/computer_tools.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel(Computer.channelName);

const _tree = '''Mail window "Nuevo mensaje" (0,30 1200×800)
  [1] AXButton "Enviar" (20,40 60×24)
  [2] AXTextField "Para:" = "ana@example.com" (100,80 400×22)
  [3] AXTextArea "Send a message" (100,120 800×400)
  [4] AXButton "Adjuntar" (90,40 60×24)
  [5] AXButton (160,40 24×24)''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late Map<String, Object? Function(MethodCall)> replies;
  late ComputerTools tools;

  setUp(() {
    calls = [];
    replies = {
      'tree': (_) => {'text': _tree, 'count': 5, 'app': 'Mail', 'pid': 42},
      'screenshot': (_) => {
            'png': Uint8List.fromList([137, 80, 78, 71]),
            'width': 1280,
            'height': 800,
            'originX': 0.0,
            'originY': 25.0,
            'scale': 1.5,
          },
      'elementAt': (_) => {'line': 'AXButton "Comprar ahora" (10,10 80×30)', 'app': 'Safari', 'pid': 7},
      'click': (c) => 'clicked',
      'type': (c) => 'typed',
      'key': (c) => 'pressed',
      'scroll': (c) => 'scrolled',
      'open': (c) => 'opened',
      'activate': (c) => 'activated',
      'requestPermissions': (_) => {'accessibility': false, 'screen': false},
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (c) async {
      calls.add(c);
      final reply = replies[c.method];
      if (reply == null) throw MissingPluginException();
      return reply(c);
    });
    tools = ComputerTools(settle: Duration.zero);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
  });

  Map<Object?, Object?> argsOf(String method) => calls.lastWhere((c) => c.method == method).arguments as Map;

  group('click', () {
    test('by index runs at once, also on a send button, and maps args', () async {
      await tools.call('ui_tree', {});
      final r = await tools.call('click', {'index': 1});
      expect(r.isError, isFalse);
      expect(argsOf('click'), {'index': 1, 'button': 'left', 'count': 1});
    });

    test('double and right map to count/button', () async {
      await tools.call('ui_tree', {});
      await tools.call('click', {'index': 4, 'double': true});
      expect(argsOf('click'), {'index': 4, 'button': 'left', 'count': 2});
      await tools.call('click', {'index': 3, 'button': 'right'});
      expect(argsOf('click'), {'index': 3, 'button': 'right', 'count': 1});
    });

    test('unknown index fails without calling native', () async {
      final r = await tools.call('click', {'index': 1});
      expect(r.isError, isTrue);
      await tools.call('ui_tree', {});
      final r2 = await tools.call('click', {'index': 99});
      expect(r2.isError, isTrue);
      expect(calls.where((c) => c.method == 'click'), isEmpty);
    });

    test('pixels need a screenshot and convert to screen points', () async {
      final r = await tools.call('click', {'x': 10, 'y': 10});
      expect(r.isError, isTrue);
      expect(r.text, contains('call screen first'));

      final shot = await tools.call('screen', {});
      expect(shot.png, isNotNull);
      expect(shot.text, contains('1280×800'));

      final click = await tools.call('click', {'x': 100, 'y': 200});
      expect(argsOf('elementAt'), {'x': 150.0, 'y': 325.0});
      expect(argsOf('click'), {'x': 150.0, 'y': 325.0, 'button': 'left', 'count': 1});
      // The element under the point describes the click in the result.
      expect(click.text, contains('Comprar ahora'));
    });

    test('pixels outside the last screenshot are rejected', () async {
      await tools.call('screen', {});
      final r = await tools.call('click', {'x': 2000, 'y': 10});
      expect(r.isError, isTrue);
      expect(calls.where((c) => c.method == 'click'), isEmpty);
    });
  });

  group('keyboard', () {
    test('type_text maps text and index', () async {
      await tools.call('ui_tree', {});
      await tools.call('type_text', {'text': 'hola\n', 'index': 3});
      expect(argsOf('type'), {'text': 'hola\n', 'index': 3});
    });

    test('press_key maps the combo, destructive ones too', () async {
      await tools.call('press_key', {'combo': 'cmd+t'});
      expect(argsOf('key'), {'combo': 'cmd+t'});
      await tools.call('press_key', {'combo': 'cmd+delete'});
      expect(argsOf('key'), {'combo': 'cmd+delete'});
    });
  });

  test('scroll converts the optional point', () async {
    await tools.call('scroll', {'dy': 3});
    expect(argsOf('scroll'), {'dx': 0, 'dy': 3});
    await tools.call('screen', {});
    await tools.call('scroll', {'dy': -2, 'x': 10, 'y': 20});
    expect(argsOf('scroll'), {'dx': 0, 'dy': -2, 'x': 15.0, 'y': 55.0});
  });

  test('open and activate run directly', () async {
    await tools.call('open', {'target': 'Safari'});
    await tools.call('activate', {'pid': 42});
    expect(argsOf('open'), {'target': 'Safari'});
    expect(argsOf('activate'), {'pid': 42});
  });

  test('screen of a window passes windowId', () async {
    await tools.call('screen', {'window_id': 77});
    expect(argsOf('screenshot'), {'windowId': 77});
  });

  test('missing permission requests it once and tells the model', () async {
    replies['tree'] = (_) => throw PlatformException(code: 'no_accessibility', message: 'Accessibility permission missing');
    final r = await tools.call('ui_tree', {});
    expect(r.isError, isTrue);
    expect(r.text, contains('System Settings'));
    await tools.call('ui_tree', {});
    expect(calls.where((c) => c.method == 'requestPermissions').length, 1);
  });

  test('every tool is handled and has an object schema, without a risky flag', () {
    for (final t in tools.tools) {
      expect(tools.handles(t.name), isTrue);
      expect(t.inputSchema['type'], 'object');
      expect((t.inputSchema['properties'] as Map?)?.containsKey('risky') ?? false, isFalse, reason: t.name);
    }
    expect(tools.handles('show'), isFalse);
  });
}
