import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minerva/computer/computer.dart';
import 'package:minerva/computer/computer_tools.dart';
import 'package:minerva/mcp/display_mcp_server.dart';
import 'package:minerva/tools/command_tools.dart';
import 'package:minerva/vault/vault.dart';
import 'package:minerva/vault/vault_tools.dart';

const _secret = 'S3cr3t-Test-123';

String _mode(String path) => Process.runSync('/usr/bin/stat', ['-f', '%Lp', path]).stdout.toString().trim();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String dir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('minerva-vault-test');
    dir = '${tmp.path}/vault';
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Future<Vault> github() async {
    final v = await Vault.open(dir);
    await v.save('GitHub', 'GitHub login', const [
      VaultField('username', 'jdoe', secret: false),
      VaultField('password', _secret),
    ]);
    return v;
  }

  group('storage', () {
    test('nothing is created until the first save', () async {
      final v = await Vault.open(dir);
      expect(v.credentials, isEmpty);
      expect(v.loadError, isNull);
      expect(Directory(dir).existsSync(), isFalse);
    });

    test('round trip: encrypted on disk, key 0600, dir 0700', () async {
      await github();
      final key = File('$dir/key');
      final data = File('$dir/vault.bin');
      expect(key.lengthSync(), 32);
      expect(_mode(dir), '700');
      expect(_mode(key.path), '600');
      expect(_mode(data.path), '600');
      // No plaintext on disk, and no temp files left over.
      final bytes = data.readAsBytesSync();
      expect(latin1.decode(bytes).contains(_secret), isFalse);
      expect(latin1.decode(bytes).contains('username'), isFalse);
      expect(Directory(dir).listSync().map((e) => e.path.split('/').last).toSet(), {'key', 'vault.bin'});

      final again = await Vault.open(dir);
      expect(again.loadError, isNull);
      expect(again.value('github', 'password'), _secret);
      expect(again.value('github', 'username'), 'jdoe');
      expect(again['github']!.description, 'GitHub login');
    });

    test('saving again merges fields and keeps the key', () async {
      final v = await github();
      final key = File('$dir/key').readAsBytesSync();
      await v.save('github', '', const [VaultField('token', 'ghp_abcdef'), VaultField('password', '')]);
      final again = await Vault.open(dir);
      expect(again['github']!.fields.map((f) => f.name), containsAll(['username', 'password', 'token']));
      expect(again.value('github', 'password'), _secret);
      expect(again['github']!.description, 'GitHub login');
      expect(File('$dir/key').readAsBytesSync(), key);
    });

    test('delete', () async {
      final v = await github();
      expect(await v.delete('github'), isTrue);
      expect(await v.delete('github'), isFalse);
      expect((await Vault.open(dir)).credentials, isEmpty);
    });

    test('a wrong key or a modified file does not open', () async {
      await github();
      final data = File('$dir/vault.bin');
      final good = data.readAsBytesSync();
      final bad = Uint8List.fromList(good)..[good.length - 1] ^= 1;
      data.writeAsBytesSync(bad);
      final v = await Vault.open(dir);
      expect(v.loadError, contains('does not match'));
      expect(v.credentials, isEmpty);
      await expectLater(v.save('x', '', const [VaultField('a', 'bbbb')]), throwsA(isA<VaultException>()));
      // The unreadable file is left alone.
      expect(data.readAsBytesSync(), bad);
    });

    test('encrypt and decrypt', () async {
      final key = SecretKey(List<int>.generate(32, (i) => i));
      final sealed = await Vault.encrypt(utf8.encode('hello'), key);
      expect(utf8.decode(await Vault.decrypt(sealed, key)), 'hello');
      final other = SecretKey(List<int>.generate(32, (i) => i + 1));
      await expectLater(Vault.decrypt(sealed, other), throwsA(isA<VaultException>()));
      // A fresh nonce every time.
      expect(await Vault.encrypt(utf8.encode('hello'), key), isNot(sealed));
    });
  });

  group('placeholders', () {
    test('substitute fills values and names unknown ones', () async {
      final v = await github();
      expect(v.substitute('user={{vault:github.username}} pass={{ vault:github.password }}'),
          'user=jdoe pass=$_secret');
      expect(
        () => v.substitute('{{vault:github.pin}} {{vault:gitlab.token}}'),
        throwsA(isA<VaultException>().having((e) => e.message, 'message',
            allOf(contains('{{vault:github.pin}}'), contains('{{vault:gitlab.token}}')))),
      );
      expect(v.substitute('no placeholders'), 'no placeholders');
    });

    test('commands get environment variable references that fit the quoting', () async {
      final v = await github();
      final (cmd, env) = v.commandWithEnv(
          "a {{vault:github.password}} \"b {{vault:github.password}}\" 'c {{vault:github.username}}'");
      expect(cmd, contains(r'a "${MINERVA_VAULT_1}" "b ${MINERVA_VAULT_1}"'));
      expect(cmd, contains(r"""'c '"${MINERVA_VAULT_2}"''"""));
      expect(cmd.contains(_secret), isFalse);
      expect(env, {'MINERVA_VAULT_1': _secret, 'MINERVA_VAULT_2': 'jdoe'});
    });

    test('run_command: the value reaches the command, not its text, and is scrubbed', () async {
      final v = await github();
      final tools = CommandTools(home: tmp.path, vault: v);
      var r = await tools.call('run_command', {'command': 'printf %s {{vault:github.password}} | wc -c'});
      expect(r.isError, isFalse, reason: r.text);
      expect(r.text.trim().split(RegExp(r'\s+')).last, '${_secret.length}');

      r = await tools.call('run_command', {
        'command': "echo {{vault:github.password}}; echo \"x{{vault:github.password}}\"; echo '{{vault:github.password}}'",
      });
      expect(r.text.contains(_secret), isFalse);
      expect('{{vault:github.password}}'.allMatches(r.text).length, 3, reason: r.text);

      // The command line itself does not hold the value.
      r = await tools.call('run_command', {'command': r'ps -o args= -p $$; echo {{vault:github.password}} >/dev/null'});
      expect(r.text.contains(_secret), isFalse);

      r = await tools.call('run_command', {'command': 'echo {{vault:github.pin}}'});
      expect(r.isError, isTrue);
      expect(r.text, contains('{{vault:github.pin}}'));
    });

    test('write_file writes the value; its result does not', () async {
      final v = await github();
      final tools = CommandTools(home: tmp.path, vault: v);
      final r = await tools.call('write_file', {'path': 'cfg.env', 'content': 'PASS={{vault:github.password}}\n'});
      expect(r.isError, isFalse);
      expect(r.text.contains(_secret), isFalse);
      expect(File('${tmp.path}/cfg.env').readAsStringSync(), 'PASS=$_secret\n');
      final read = v.scrubResult(await tools.call('read_file', {'path': 'cfg.env'}));
      expect(read.text, 'PASS={{vault:github.password}}');
      final bad = await tools.call('write_file', {'path': 'x', 'content': '{{vault:nope.x}}'});
      expect(bad.isError, isTrue);
      expect(File('${tmp.path}/x').existsSync(), isFalse);
    });

    test('type_text types the value and does not echo it', () async {
      final v = await github();
      const channel = MethodChannel(Computer.channelName);
      final typed = <String>[];
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (c) async {
        final text = (c.arguments as Map)['text'] as String;
        typed.add(text);
        return 'typed ${text.length} characters';
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final tools = ComputerTools(settle: Duration.zero, vault: v);
      final r = await tools.call('type_text', {'text': '{{vault:github.password}}\n'});
      expect(typed.single, '$_secret\n');
      expect(r.text.contains('${_secret.length + 1}'), isFalse);
      expect(r.text.contains(_secret), isFalse);
      final bad = await tools.call('type_text', {'text': '{{vault:github.nope}}'});
      expect(bad.isError, isTrue);
      expect(typed, hasLength(1));
    });
  });

  group('redaction', () {
    test('secret values become placeholders, also escaped; short and non-secret ones stay', () async {
      final v = await github();
      await v.save('pin', '', const [VaultField('code', '123')]);
      await v.save('api', '', const [VaultField('key', 'a"b/c d')]);
      expect(v.scrub('pw $_secret!'), 'pw {{vault:github.password}}!');
      expect(v.scrub(jsonEncode({'k': 'a"b/c d'})), '{"k":"{{vault:api.key}}"}');
      expect(v.scrub('https://x/?k=${Uri.encodeComponent('a"b/c d')}'), 'https://x/?k={{vault:api.key}}');
      expect(v.scrub('user jdoe code 123'), 'user jdoe code 123');
      final r = v.scrubResult(const ToolResult('out $_secret', isError: true));
      expect(r.text, 'out {{vault:github.password}}');
      expect(r.isError, isTrue);
    });

    test('deleted values are still scrubbed until restart', () async {
      final v = await github();
      await v.delete('github');
      expect(v.scrub(_secret), '{{vault:github.password}}');
    });
  });

  group('tools', () {
    test('vault_list shows names and fields, never values', () async {
      final v = await github();
      final r = await VaultTools(v).call('vault_list', {});
      expect(r.text, contains('github — GitHub login'));
      expect(r.text, contains('{{vault:github.password}}'));
      expect(r.text, contains('{{vault:github.username}} (not secret)'));
      expect(r.text.contains(_secret), isFalse);
      expect(r.text.contains('jdoe'), isFalse);
    });

    test('workers get no vault_delete', () async {
      final v = await Vault.open(dir);
      expect(VaultTools(v, readOnly: true).tools.map((t) => t.name), ['vault_list']);
      expect(VaultTools(v).tools.map((t) => t.name), ['vault_list', 'vault_delete']);
    });

    test('vault_request becomes a vault form', () {
      final form = VaultTools.requestForm({
        'name': 'GitHub',
        'description': 'Login',
        'fields': [
          {'name': 'username', 'label': 'User', 'secret': false},
          {'name': 'password', 'label': 'Password'},
        ],
      }) as Map;
      expect(form['vault'], 'github');
      expect(form['id'], 'vault-github');
      expect((form['fields'] as List).map((f) => (f as Map)['type']), ['text', 'secret']);
      expect(VaultTools.requestForm({'name': 'bad name', 'fields': []}), startsWith('error:'));
      expect(
        VaultTools.requestForm({
          'name': 'x',
          'fields': [
            {'name': 'a.b'},
          ],
        }),
        startsWith('error:'),
      );
    });
  });
}
