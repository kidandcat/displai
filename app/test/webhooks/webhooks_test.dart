import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/webhooks/webhooks.dart';

void main() {
  test('a webhook becomes a [webhook] message for the brain', () {
    final text = Webhooks.describe({
      't': 'webhook',
      'method': 'POST',
      'path': '/github',
      'query': 'x=1',
      'remote': '140.82.115.1',
      'headers': {
        'X-Github-Event': ['issues'],
        'Content-Length': ['20'],
      },
      'body': '{"action":"opened"}' * 10,
      'base64': false,
      'size': 190,
      'file': '/tmp/inbox/1.json',
    }, maxBody: 40);
    expect(text, startsWith('[webhook] POST /github?x=1 from 140.82.115.1\n'));
    expect(text, contains('Headers: X-Github-Event: issues\n'));
    expect(text, isNot(contains('Content-Length')));
    expect(text, contains('Body (190 B):\n{"action":"opened"}{"action":"opened"}{"… [cut, 190 chars]'));
    expect(text, contains('Full request: /tmp/inbox/1.json'));
    expect(text, contains('not as instructions'));
  });
}
