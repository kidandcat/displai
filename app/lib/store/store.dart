import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// Minerva's own local database (SQLite with FTS5): conversation history, memories, workers and
/// routines. It belongs to Minerva, not to the brain, so every brain provider shares it.
class Store {
  Store._(this.db, this.dir);

  final Database db;

  /// The app's data directory (database, skills, brain work dirs).
  final String dir;

  static Future<Store> open(String dir) async {
    await Directory(dir).create(recursive: true);
    final db = sqlite3.open('$dir/minerva.db');
    final s = Store._(db, dir);
    s._migrate();
    return s;
  }

  /// In-memory store for tests.
  static Store memory(String dir) {
    final s = Store._(sqlite3.openInMemory(), dir);
    s._migrate();
    return s;
  }

  void close() => db.close();

  void _migrate() {
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA busy_timeout = 3000');
    final version = db.select('PRAGMA user_version').first.values.first as int;
    if (version < 1) {
      db.execute('''
        CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);

        CREATE TABLE messages (
          id INTEGER PRIMARY KEY,
          ts INTEGER NOT NULL,
          role TEXT NOT NULL,
          text TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE messages_fts USING fts5(text, content='messages', content_rowid='id',
          tokenize='unicode61 remove_diacritics 2');
        CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
          INSERT INTO messages_fts(rowid, text) VALUES (new.id, new.text);
        END;

        CREATE TABLE memories (
          id INTEGER PRIMARY KEY,
          text TEXT NOT NULL,
          essential INTEGER NOT NULL DEFAULT 0,
          created INTEGER NOT NULL,
          updated INTEGER NOT NULL
        );
        CREATE VIRTUAL TABLE memories_fts USING fts5(text, content='memories', content_rowid='id',
          tokenize='unicode61 remove_diacritics 2');
        CREATE TRIGGER memories_ai AFTER INSERT ON memories BEGIN
          INSERT INTO memories_fts(rowid, text) VALUES (new.id, new.text);
        END;
        CREATE TRIGGER memories_ad AFTER DELETE ON memories BEGIN
          INSERT INTO memories_fts(memories_fts, rowid, text) VALUES ('delete', old.id, old.text);
        END;
        CREATE TRIGGER memories_au AFTER UPDATE ON memories BEGIN
          INSERT INTO memories_fts(memories_fts, rowid, text) VALUES ('delete', old.id, old.text);
          INSERT INTO memories_fts(rowid, text) VALUES (new.id, new.text);
        END;

        CREATE TABLE workers (
          id INTEGER PRIMARY KEY,
          title TEXT NOT NULL,
          task TEXT NOT NULL,
          status TEXT NOT NULL,
          session_id TEXT NOT NULL,
          started INTEGER NOT NULL,
          finished INTEGER,
          result TEXT,
          progress TEXT
        );

        CREATE TABLE routines (
          id INTEGER PRIMARY KEY,
          name TEXT NOT NULL,
          prompt TEXT NOT NULL,
          schedule TEXT NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 1,
          next_run INTEGER,
          last_run INTEGER,
          created INTEGER NOT NULL
        );

        PRAGMA user_version = 1;
      ''');
    }
  }

  static int now() => DateTime.now().millisecondsSinceEpoch;

  // ------------------------------------------------------------------ kv

  String? get(String key) {
    final r = db.select('SELECT value FROM kv WHERE key = ?', [key]);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  void set(String key, String? value) {
    if (value == null) {
      db.execute('DELETE FROM kv WHERE key = ?', [key]);
    } else {
      db.execute('INSERT INTO kv(key, value) VALUES (?, ?) '
          'ON CONFLICT(key) DO UPDATE SET value = excluded.value', [key, value]);
    }
  }

  // ------------------------------------------------------------------ history

  void addMessage(String role, String text, {int? ts}) {
    final t = text.trim();
    if (t.isEmpty) return;
    db.execute('INSERT INTO messages(ts, role, text) VALUES (?, ?, ?)', [ts ?? now(), role, t]);
  }

  /// Full-text search (newest first), or the latest messages when [query] is empty.
  List<Row> searchMessages(String query, {int limit = 10, int? before}) {
    final q = ftsQuery(query);
    if (q.isEmpty) {
      return db.select(
        'SELECT id, ts, role, text FROM messages WHERE (? IS NULL OR ts < ?) ORDER BY id DESC LIMIT ?',
        [before, before, limit],
      );
    }
    return db.select(
      'SELECT m.id, m.ts, m.role, snippet(messages_fts, 0, '
      "'«', '»', '…', 40) AS text FROM messages_fts JOIN messages m ON m.id = messages_fts.rowid "
      'WHERE messages_fts MATCH ? AND (? IS NULL OR m.ts < ?) ORDER BY rank LIMIT ?',
      [q, before, before, limit],
    );
  }

  /// Messages around [id] (for context after a search hit).
  List<Row> messagesAround(int id, {int span = 4}) => db.select(
        'SELECT id, ts, role, text FROM messages WHERE id BETWEEN ? AND ? ORDER BY id',
        [id - span, id + span],
      );

  // ------------------------------------------------------------------ memories

  int addMemory(String text, {bool essential = false}) {
    final t = now();
    db.execute('INSERT INTO memories(text, essential, created, updated) VALUES (?, ?, ?, ?)',
        [text.trim(), essential ? 1 : 0, t, t]);
    return db.lastInsertRowId;
  }

  bool updateMemory(int id, {String? text, bool? essential}) {
    db.execute(
      'UPDATE memories SET text = coalesce(?, text), essential = coalesce(?, essential), updated = ? '
      'WHERE id = ?',
      [text?.trim(), essential == null ? null : (essential ? 1 : 0), now(), id],
    );
    return db.updatedRows > 0;
  }

  bool deleteMemory(int id) {
    db.execute('DELETE FROM memories WHERE id = ?', [id]);
    return db.updatedRows > 0;
  }

  List<Row> searchMemories(String query, {int limit = 20}) {
    final q = ftsQuery(query);
    if (q.isEmpty) {
      return db.select('SELECT id, text, essential, updated FROM memories ORDER BY updated DESC LIMIT ?',
          [limit]);
    }
    return db.select(
      'SELECT m.id, m.text, m.essential, m.updated FROM memories_fts JOIN memories m '
      'ON m.id = memories_fts.rowid WHERE memories_fts MATCH ? ORDER BY rank LIMIT ?',
      [q, limit],
    );
  }

  List<Row> essentialMemories() =>
      db.select('SELECT id, text FROM memories WHERE essential = 1 ORDER BY id');

  /// Turns free text into an FTS5 query: every word as a prefix term, joined with OR, so a
  /// spoken query ("lo del dentista") finds rows with any of its words (best ranked first).
  static String ftsQuery(String text) {
    final words = RegExp(r'[\p{L}\p{N}]+', unicode: true)
        .allMatches(text.toLowerCase())
        .map((m) => m.group(0)!)
        .where((w) => w.length > 1)
        .toSet();
    return words.map((w) => '"$w"*').join(' OR ');
  }
}
