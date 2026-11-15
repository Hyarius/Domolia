import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../ai/ai_diagnostics.dart';
import '../logging/app_logger.dart';
import 'book_definition.dart';
import 'book_session.dart';

/// Durable local data lives in SQLite. Credentials stay in the existing
/// encrypted AI store. Only a profile ID is stored as a local book binding.
abstract interface class BookStore {
  Future<List<BookDefinition>> listBooks();
  Future<BookDefinition?> findBook(String id);
  Future<void> putBook(BookDefinition book);
  Future<void> deleteBook(String id);
  Future<String?> profileIdForBook(String bookId);
  Future<void> bindProfile(String bookId, String? profileId);
  Future<List<BookSession>> listSessions(String bookId);
  Future<BookSession?> findSession(String id);
  Future<void> putSession(BookSession session);
  /// Update a saved session without recreating it after deletion.
  Future<void> updateSession(BookSession session);
  Future<void> deleteSession(String id);
  Future<void> putDiagnostic(StoredAiDiagnostic diagnostic, int retentionLimit);
  Future<List<StoredAiDiagnostic>> listDiagnostics(String sessionId);
  Future<void> clearDiagnostics(String sessionId);
  Future<void> pruneDiagnostics(int retentionLimit);
}

class SqliteBookStore implements BookStore {
  SqliteBookStore({DatabaseFactory? factory, this.databasePath})
      : _factoryOverride = factory;

  final DatabaseFactory? _factoryOverride;
  final String? databasePath;
  Database? _db;

  static Future<void> _createDiagnostics(Database db) async {
    await db.execute(
      'CREATE TABLE ai_diagnostics (id TEXT PRIMARY KEY, '
      'session_id TEXT NOT NULL, created_at INTEGER NOT NULL, '
      'payload_json TEXT NOT NULL, '
      'FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE)',
    );
    await db.execute(
      'CREATE INDEX ai_diagnostics_by_session '
      'ON ai_diagnostics(session_id, created_at DESC)',
    );
  }

  static Future<void> _pruneSession(
      DatabaseExecutor db, String sessionId, int limit) async {
    await db.rawDelete(
      'DELETE FROM ai_diagnostics WHERE session_id = ? AND id NOT IN '
      '(SELECT id FROM ai_diagnostics WHERE session_id = ? '
      'ORDER BY created_at DESC, id DESC LIMIT ?)',
      [sessionId, sessionId, limit],
    );
  }

  Future<Database> get database async {
    if (_db != null) return _db!;
    final location = databasePath ?? path.join(
      (await getApplicationSupportDirectory()).path, 'domolia_books.sqlite',
    );
    AppLogger.debug('Ouverture du stockage SQLite', component: 'books');
    return _db ??= await (_factoryOverride ?? databaseFactory).openDatabase(
      location,
      options: OpenDatabaseOptions(
      version: 3,
      onConfigure: (db) async =>
          db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE books (id TEXT PRIMARY KEY, definition_json TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE book_bindings (book_id TEXT PRIMARY KEY, '
          'profile_id TEXT, FOREIGN KEY(book_id) REFERENCES books(id) '
          'ON DELETE CASCADE)',
        );
        await db.execute(
          'CREATE TABLE sessions (id TEXT PRIMARY KEY, book_id TEXT NOT NULL, '
          'title TEXT NOT NULL, timeline_json TEXT NOT NULL, '
          'updated_at INTEGER NOT NULL, profile_id TEXT, '
          'FOREIGN KEY(book_id) REFERENCES books(id) ON DELETE CASCADE)',
        );
        await db.execute(
          'CREATE INDEX sessions_by_book ON sessions(book_id, updated_at)',
        );
        await _createDiagnostics(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await _createDiagnostics(db);
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE sessions ADD COLUMN profile_id TEXT');
        }
      },
      ),
    );
  }

  @override
  Future<List<BookDefinition>> listBooks() async {
    final rows = await (await database).query('books', orderBy: 'rowid DESC');
    return [for (final row in rows)
      BookDefinition.importJson(row['definition_json'] as String)];
  }

  @override
  Future<BookDefinition?> findBook(String id) async {
    final rows = await (await database).query(
      'books', where: 'id = ?', whereArgs: [id], limit: 1,
    );
    return rows.isEmpty ? null :
        BookDefinition.importJson(rows.single['definition_json'] as String);
  }

  @override
  Future<void> putBook(BookDefinition book) async {
    final json = book.exportJson();
    final db = await database;
    final updated = await db.update('books', {'definition_json': json},
      where: 'id = ?', whereArgs: [book.id]);
    if (updated == 0) {
      await db.insert('books', {'id': book.id, 'definition_json': json});
    }
  }

  @override
  Future<void> deleteBook(String id) async {
    await (await database).delete('books', where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<String?> profileIdForBook(String bookId) async {
    final rows = await (await database).query('book_bindings',
      columns: ['profile_id'], where: 'book_id = ?',
      whereArgs: [bookId], limit: 1,
    );
    return rows.isEmpty ? null : rows.single['profile_id'] as String?;
  }

  @override
  Future<void> bindProfile(String bookId, String? profileId) async {
    await (await database).insert('book_bindings', {
      'book_id': bookId, 'profile_id': profileId,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<List<BookSession>> listSessions(String bookId) async {
    final rows = await (await database).query('sessions',
      where: 'book_id = ?', whereArgs: [bookId], orderBy: 'updated_at DESC',
    );
    return rows.map(_session).toList(growable: false);
  }

  BookSession _session(Map<String, Object?> row) => BookSession(
    id: row['id'] as String,
    bookId: row['book_id'] as String,
    title: row['title'] as String,
    timeline: BookSession.decodeTimeline(row['timeline_json'] as String),
    aiProfileId: row['profile_id'] as String?,
    updatedAtUtc: DateTime.fromMicrosecondsSinceEpoch(
        row['updated_at'] as int, isUtc: true),
  );

  @override
  Future<BookSession?> findSession(String id) async {
    final rows = await (await database).query('sessions',
      where: 'id = ?', whereArgs: [id], limit: 1,
    );
    return rows.isEmpty ? null : _session(rows.single);
  }

  @override
  Future<void> putSession(BookSession session) async {
    final db = await database;
    final values = <String, Object?>{
      'book_id': session.bookId,
      'title': session.title,
      'timeline_json': session.encodeTimeline(),
      'updated_at': DateTime.now().microsecondsSinceEpoch,
      'profile_id': session.aiProfileId,
    };
    // REPLACE deletes the existing SQLite row and cascades into diagnostics.
    // An in-place update preserves every retained AI exchange for this part.
    await db.transaction((txn) async {
      final updated = await txn.update(
        'sessions', values, where: 'id = ?', whereArgs: [session.id],
      );
      if (updated == 0) {
        await txn.insert('sessions', {'id': session.id, ...values});
      }
    });
  }

  @override
  Future<void> updateSession(BookSession session) async {
    // A late autosave must never reinsert a session the user has deleted.
    await (await database).update('sessions', {
      'title': session.title,
      'timeline_json': session.encodeTimeline(),
      'updated_at': DateTime.now().microsecondsSinceEpoch,
    }, where: 'id = ? AND book_id = ?',
      whereArgs: [session.id, session.bookId]);
  }

  @override
  Future<void> deleteSession(String id) async {
    await (await database).delete('sessions', where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> putDiagnostic(
      StoredAiDiagnostic diagnostic, int retentionLimit) async {
    if (retentionLimit < 0 || retentionLimit > 50) {
      throw RangeError.range(retentionLimit, 0, 50, 'retentionLimit');
    }
    final db = await database;
    await db.transaction((txn) async {
      if (retentionLimit > 0) {
        await txn.insert('ai_diagnostics', {
          'id': diagnostic.id,
          'session_id': diagnostic.sessionId,
          'created_at': diagnostic.createdAtUtc.microsecondsSinceEpoch,
          'payload_json': diagnostic.content,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await _pruneSession(txn, diagnostic.sessionId, retentionLimit);
    });
  }

  @override
  Future<List<StoredAiDiagnostic>> listDiagnostics(String sessionId) async {
    final rows = await (await database).query(
      'ai_diagnostics',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'created_at DESC, id DESC',
    );
    return [
      for (final row in rows)
        StoredAiDiagnostic(
          id: row['id'] as String,
          sessionId: row['session_id'] as String,
          createdAtUtc: DateTime.fromMicrosecondsSinceEpoch(
            row['created_at'] as int, isUtc: true),
          content: row['payload_json'] as String,
        ),
    ];
  }

  @override
  Future<void> clearDiagnostics(String sessionId) async {
    final db = await database;
    final removed = await db.delete(
      'ai_diagnostics', where: 'session_id = ?', whereArgs: [sessionId],
    );
    // Purge explicitly requests a smaller footprint, not merely reusable
    // SQLite free pages. VACUUM runs outside transactions.
    if (removed > 0) await db.execute('VACUUM');
  }

  @override
  Future<void> pruneDiagnostics(int retentionLimit) async {
    if (retentionLimit < 0 || retentionLimit > 50) {
      throw RangeError.range(retentionLimit, 0, 50, 'retentionLimit');
    }
    final db = await database;
    await db.transaction((txn) async {
      if (retentionLimit == 0) {
        await txn.delete('ai_diagnostics');
      } else {
        final sessions = await txn.rawQuery(
          'SELECT DISTINCT session_id FROM ai_diagnostics',
        );
        for (final row in sessions) {
          await _pruneSession(txn, row['session_id'] as String, retentionLimit);
        }
      }
    });
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
