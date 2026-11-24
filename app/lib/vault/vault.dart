import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter/foundation.dart';

import '../mcp/display_mcp_server.dart';

/// One named value of a credential (e.g. username, password, token).
class VaultField {
  const VaultField(this.name, this.value, {this.secret = true});

  final String name;
  final String value;

  /// Secret values are scrubbed from every tool result (see [Vault.scrub]); plain ones (a
  /// username) are not, so they do not blank out ordinary text that happens to contain them.
  final bool secret;

  Map<String, Object?> toJson() => {'name': name, 'value': value, 'secret': secret};

  static VaultField fromJson(Map<String, Object?> j) =>
      VaultField('${j['name']}', '${j['value'] ?? ''}', secret: j['secret'] != false);
}

/// A saved credential: a slug name (`github`), a description and its fields.
class Credential {
  Credential(this.name, this.description, this.fields, {required this.updated});

  final String name;
  final String description;
  final List<VaultField> fields;
  final DateTime updated;

  Map<String, Object?> toJson() => {
        'name': name,
        'description': description,
        'fields': [for (final f in fields) f.toJson()],
        'updated': updated.millisecondsSinceEpoch,
      };

  static Credential fromJson(Map<String, Object?> j) => Credential(
        '${j['name']}',
        '${j['description'] ?? ''}',
        [for (final f in (j['fields'] as List? ?? const [])) VaultField.fromJson((f as Map).cast<String, Object?>())],
        updated: DateTime.fromMillisecondsSinceEpoch((j['updated'] as num?)?.toInt() ?? 0),
      );
}

class VaultException implements Exception {
  const VaultException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Minerva's own credential vault (design §3.9).
///
/// The brain never sees a value: it asks the user for credentials with a display form whose
/// submission goes straight here, refers to them as `{{vault:name.field}}` placeholders that the
/// app fills in ([substitute], [commandWithEnv]), and every tool result is scrubbed of the stored
/// secret values ([scrub]).
///
/// On disk (`<dataDir>/vault/`, mode 0700): `vault.bin` is the JSON of all credentials sealed
/// with AES-256-GCM (magic, 12-byte nonce, ciphertext, 16-byte tag); `key` is the random 32-byte
/// key (mode 0600), created on the first save. Writes are atomic (temp file + rename).
class Vault extends ChangeNotifier {
  Vault._(this.dir);

  /// The vault directory (`<dataDir>/vault`).
  final String dir;

  String get keyPath => '$dir/key';
  String get dataPath => '$dir/vault.bin';

  static final _magic = utf8.encode('MNV1');
  static final _aad = utf8.encode('minerva-vault-v1');
  static final _aes = DartAesGcm.with256bits();

  /// `{{vault:name.field}}`.
  static final placeholder = RegExp(r'\{\{\s*vault:([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)\s*\}\}');

  /// Credential and field names: slugs.
  static final _slug = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');
  static final _fieldName = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  /// Secret values shorter than this are not scrubbed (they would match everywhere).
  static const minScrubLength = 4;

  final Map<String, Credential> _items = {};
  SecretKey? _key;

  /// Why the vault could not be read (its file is then left untouched), or null.
  String? loadError;

  /// (text to find, placeholder), longest first.
  List<(String, String)> _scrubs = const [];

  Future<void> _writes = Future.value();

  /// Opens the vault in [dir] (nothing is created until the first save).
  static Future<Vault> open(String dir) async {
    final v = Vault._(dir);
    try {
      await v._load();
    } catch (e) {
      v.loadError = 'the vault could not be read: $e';
      debugPrint('vault: ${v.loadError}');
    }
    v._rebuildScrubs();
    return v;
  }

  static String normalizeName(String name) => name.trim().toLowerCase();
  static bool validName(String name) => _slug.hasMatch(name);
  static bool validFieldName(String name) => _fieldName.hasMatch(name);

  List<Credential> get credentials => _items.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  Credential? operator [](String name) => _items[normalizeName(name)];

  /// The value of `name.field`, or null.
  String? value(String name, String field) {
    final c = this[name];
    if (c == null) return null;
    for (final f in c.fields) {
      if (f.name == field) return f.value;
    }
    return null;
  }

  // ---------------------------------------------------------------- storage

  Future<void> _load() async {
    final data = File(dataPath);
    if (!data.existsSync()) return;
    final keyFile = File(keyPath);
    if (!keyFile.existsSync()) throw const VaultException('vault.bin exists but its key file is missing');
    final keyBytes = await keyFile.readAsBytes();
    if (keyBytes.length != 32) throw const VaultException('the key file is not 32 bytes');
    _key = SecretKey(keyBytes);
    final plain = await decrypt(await data.readAsBytes(), _key!);
    final json = jsonDecode(utf8.decode(plain)) as Map<String, Object?>;
    for (final c in (json['credentials'] as List? ?? const [])) {
      final cred = Credential.fromJson((c as Map).cast<String, Object?>());
      _items[cred.name] = cred;
    }
  }

  /// AES-256-GCM: magic + nonce + ciphertext + tag.
  static Future<Uint8List> encrypt(List<int> plain, SecretKey key) async {
    final box = await _aes.encrypt(plain, secretKey: key, aad: _aad);
    return Uint8List.fromList([..._magic, ...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  static Future<List<int>> decrypt(Uint8List sealed, SecretKey key) async {
    const nonceLen = 12, tagLen = 16;
    final m = _magic.length;
    if (sealed.length < m + nonceLen + tagLen || !listEquals(sealed.sublist(0, m), _magic)) {
      throw const VaultException('not a Minerva vault file');
    }
    final box = SecretBox(
      sealed.sublist(m + nonceLen, sealed.length - tagLen),
      nonce: sealed.sublist(m, m + nonceLen),
      mac: Mac(sealed.sublist(sealed.length - tagLen)),
    );
    try {
      return await _aes.decrypt(box, secretKey: key, aad: _aad);
    } on SecretBoxAuthenticationError {
      throw const VaultException('the vault file does not match its key (or was modified)');
    }
  }

  Future<SecretKey> _ensureKey() async {
    final k = _key;
    if (k != null) return k;
    await _ensureDir();
    final r = Random.secure();
    final bytes = Uint8List.fromList(List<int>.generate(32, (_) => r.nextInt(256)));
    await _atomicWrite(keyPath, bytes);
    return _key = SecretKey(bytes);
  }

  Future<void> _ensureDir() async {
    final d = Directory(dir);
    if (!d.existsSync()) await d.create(recursive: true);
    await _chmod('700', dir);
  }

  /// Writes [bytes] to a temp file with mode 0600 and renames it over [path].
  static Future<void> _atomicWrite(String path, List<int> bytes) async {
    final tmp = File('$path.tmp-${DateTime.now().microsecondsSinceEpoch}');
    // Created empty and restricted before any secret byte goes in.
    await tmp.writeAsBytes(const [], flush: true);
    await _chmod('600', tmp.path);
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(path);
  }

  static Future<void> _chmod(String mode, String path) async {
    final r = await Process.run('/bin/chmod', [mode, path]);
    if (r.exitCode != 0) throw VaultException('chmod $mode failed: ${r.stderr}');
  }

  Future<void> _persist() {
    final done = _writes.then((_) async {
      final key = await _ensureKey();
      await _ensureDir();
      final json = jsonEncode({
        'version': 1,
        'credentials': [for (final c in credentials) c.toJson()],
      });
      await _atomicWrite(dataPath, await encrypt(utf8.encode(json), key));
    });
    _writes = done.catchError((_) {});
    return done;
  }

  /// Saves [fields] under [name]: fields given replace the ones with the same name, the others
  /// are kept. Empty values are ignored.
  Future<Credential> save(String name, String description, List<VaultField> fields) async {
    if (loadError != null) throw VaultException(loadError!);
    name = normalizeName(name);
    if (!validName(name)) throw VaultException('invalid credential name "$name" (use a slug like github)');
    final old = _items[name];
    final merged = <String, VaultField>{for (final f in old?.fields ?? const <VaultField>[]) f.name: f};
    for (final f in fields) {
      if (!validFieldName(f.name)) throw VaultException('invalid field name "${f.name}"');
      if (f.value.isEmpty) continue;
      merged[f.name] = f;
    }
    final desc = description.trim().isNotEmpty ? description.trim() : (old?.description ?? '');
    final c = Credential(name, desc, merged.values.toList(), updated: DateTime.now());
    _items[name] = c;
    _rebuildScrubs();
    try {
      await _persist();
    } finally {
      notifyListeners();
    }
    return c;
  }

  Future<bool> delete(String name) async {
    if (loadError != null) throw VaultException(loadError!);
    if (_items.remove(normalizeName(name)) == null) return false;
    // Values stay in the scrub list until restart: a deleted secret may still be in outputs.
    try {
      await _persist();
    } finally {
      notifyListeners();
    }
    return true;
  }

  // ---------------------------------------------------------------- placeholders

  /// The placeholders in [text] that name no stored value.
  List<String> unknown(String text) => [
        for (final m in placeholder.allMatches(text))
          if (value(m[1]!, m[2]!) == null) m[0]!,
      ];

  VaultException _unknownError(List<String> missing) => VaultException(
      'unknown vault placeholder${missing.length > 1 ? 's' : ''} ${missing.toSet().join(', ')} '
      '(see vault_list, or ask the user with vault_request)');

  /// [text] with every placeholder replaced by its value. Throws [VaultException] naming the
  /// unknown ones.
  String substitute(String text) {
    if (!text.contains('{{')) return text;
    final missing = unknown(text);
    if (missing.isNotEmpty) throw _unknownError(missing);
    return text.replaceAllMapped(placeholder, (m) => value(m[1]!, m[2]!)!);
  }

  /// A shell command with its placeholders turned into references to environment variables,
  /// and those variables' values. The values reach the child process through its environment,
  /// so they are not in its arguments (`ps`) nor in any shell history.
  ///
  /// The reference fits the quoting where the placeholder is: `"${V}"` unquoted, `${V}` inside
  /// double quotes, and `'"${V}"'` (close, expand, reopen) inside single quotes. Inside a
  /// here-document the double quotes of the unquoted form would be literal: use write_file for
  /// files instead.
  (String, Map<String, String>) commandWithEnv(String command) {
    if (!command.contains('{{')) return (command, const {});
    final missing = unknown(command);
    if (missing.isNotEmpty) throw _unknownError(missing);
    final env = <String, String>{};
    final names = <String, String>{};
    final out = StringBuffer();
    var quote = '';
    var i = 0;
    while (i < command.length) {
      final m = placeholder.matchAsPrefix(command, i);
      if (m != null) {
        final v = names.putIfAbsent('${m[1]}.${m[2]}', () {
          final n = 'MINERVA_VAULT_${names.length + 1}';
          env[n] = value(m[1]!, m[2]!)!;
          return n;
        });
        out.write(switch (quote) {
          "'" => "'\"\${$v}\"'",
          '"' => '\${$v}',
          _ => '"\${$v}"',
        });
        i = m.end;
        continue;
      }
      final c = command[i];
      if (quote != "'" && c == r'\' && i + 1 < command.length) {
        out.write(command.substring(i, i + 2));
        i += 2;
        continue;
      }
      if (quote.isEmpty && (c == "'" || c == '"')) {
        quote = c;
      } else if (quote.isNotEmpty && c == quote) {
        quote = '';
      }
      out.write(c);
      i++;
    }
    return (out.toString(), env);
  }

  // ---------------------------------------------------------------- redaction

  void _rebuildScrubs() {
    final out = <String, String>{};
    for (final c in _items.values) {
      for (final f in c.fields) {
        if (!f.secret || f.value.length < minScrubLength) continue;
        final ph = '{{vault:${c.name}.${f.name}}}';
        // The value as it is, and as it shows up in JSON and in URLs.
        final json = jsonEncode(f.value);
        for (final s in {f.value, json.substring(1, json.length - 1), Uri.encodeComponent(f.value)}) {
          out.putIfAbsent(s, () => ph);
        }
      }
    }
    // Keep the values of deleted credentials too, until restart.
    for (final (s, ph) in _scrubs) {
      out.putIfAbsent(s, () => ph);
    }
    _scrubs = out.entries.map((e) => (e.key, e.value)).toList()..sort((a, b) => b.$1.length.compareTo(a.$1.length));
  }

  /// [text] with every stored secret value replaced by its placeholder.
  String scrub(String text) {
    for (final (s, ph) in _scrubs) {
      if (text.contains(s)) text = text.replaceAll(s, ph);
    }
    return text;
  }

  /// [r] with its text scrubbed (images cannot be).
  ToolResult scrubResult(ToolResult r) {
    final text = scrub(r.text);
    if (identical(text, r.text) || text == r.text) return r;
    return ToolResult(text, png: r.png, isError: r.isError);
  }
}
