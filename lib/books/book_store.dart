import '../chat/raw_generation.dart';
import '../memory/live_memory.dart';
import 'dart:convert';
import '../ai/ai_task_generation.dart';
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

/// Optional persistence protocol; test-only BookStore implementations remain valid.
abstract interface class NarrativeSnapshotStore {
  Future<List<RawGeneration>> listRawGenerations(String sessionId);
  Future<void> saveNarrativeSnapshot(
      BookSession session, List<RawGeneration> generations);
}

/// Optional Party-only memory persistence protocol for real and fake stores.
abstract interface class LiveMemoryStore {
  Future<List<List<LiveMemoryOperation>>> loadMemoryTurns(String sessionId);
  Future<List<LiveMemoryOverride>> loadMemoryOverrides(String sessionId);
  Future<void> commitMemoryTurn(String sessionId, RawGeneration source,
      List<LiveMemoryOperation> operations);
  Future<void> saveMemoryOverride(String sessionId, LiveMemoryOverride value);
  Future<void> clearGeneratedMemory(String sessionId);
  Future<Set<int>> analyzedMemoryTurns(String sessionId);
}

class SqliteBookStore implements BookStore, NarrativeSnapshotStore, LiveMemoryStore {
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

  static Future<void> _createRawGenerations(Database db) async {
    await db.execute(
      'CREATE TABLE raw_generations ('
      'session_id TEXT NOT NULL, player_event_id INTEGER NOT NULL, '
      'raw_text TEXT NOT NULL, compact_text TEXT, '
      'first_event_id INTEGER, last_event_id INTEGER, '
      'PRIMARY KEY(session_id, player_event_id), '
      'FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE)',
    );
  }

  static Future<void> _createMemoryTables(Database db) async {
    await db.execute(
      'CREATE TABLE live_memory_turns ('
      'session_id TEXT NOT NULL, player_event_id INTEGER NOT NULL, '
      'source_hash TEXT NOT NULL, operations_json TEXT NOT NULL, '
      'created_at INTEGER NOT NULL, '
      'PRIMARY KEY(session_id, player_event_id), '
      'FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE)',
    );
    await db.execute(
      'CREATE TABLE live_memory_overrides ('
      'session_id TEXT NOT NULL, fact_id TEXT NOT NULL, '
      'payload_json TEXT, deleted INTEGER NOT NULL DEFAULT 0, '
      'PRIMARY KEY(session_id, fact_id), '
      'FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE)',
    );
  }

  @override
  Future<Set<int>> analyzedMemoryTurns(String sessionId) async {
    final rows = await (await database).query('live_memory_turns',
      columns: ['player_event_id'], where: 'session_id = ?',
      whereArgs: [sessionId]);
    return {for (final row in rows) row['player_event_id'] as int};
  }

  @override
  Future<List<List<LiveMemoryOperation>>> loadMemoryTurns(
      String sessionId) async {
    final rows = await (await database).query('live_memory_turns',
      where: 'session_id = ?', whereArgs: [sessionId],
      orderBy: 'player_event_id ASC');
    return [
      for (final row in rows)
        LiveMemoryOperation.decodeSaved(row['operations_json'] as String),
    ];
  }

  @override
  Future<List<LiveMemoryOverride>> loadMemoryOverrides(
      String sessionId) async {
    final rows = await (await database).query('live_memory_overrides',
      where: 'session_id = ?', whereArgs: [sessionId]);
    return [
      for (final row in rows)
        LiveMemoryOverride(row['fact_id'] as String,
          deleted: row['deleted'] == 1,
          fact: row['payload_json'] == null ? null :
            LiveMemoryFact.fromJson(
              jsonDecode(row['payload_json'] as String))),
    ];
  }

  /// Re-check the durable, structured RAW source INSIDE the transaction.
  /// A delayed extractor can never resurrect a rewound or deleted turn.
  @override
  Future<void> commitMemoryTurn(String sessionId, RawGeneration source,
      List<LiveMemoryOperation> operations) async {
    if (!source.isStructured || operations.length > 24) {
      throw StateError('Unvalidated memory source.');
    }
    final db = await database;
    await db.transaction((txn) async {
      final sessions = await txn.query('sessions', columns: ['id'],
          where: 'id = ?', whereArgs: [sessionId], limit: 1);
      final raws = await txn.query('raw_generations',
          where: 'session_id = ? AND player_event_id = ?',
          whereArgs: [sessionId, source.playerEventId], limit: 1);
      if (sessions.isEmpty || raws.isEmpty) {
        throw StateError('Memory source or Party no longer exists.');
      }
      final row = raws.single;
      final persisted = RawGeneration(
        playerEventId: source.playerEventId,
        rawText: row['raw_text'] as String,
        firstEventId: row['first_event_id'] as int?,
        lastEventId: row['last_event_id'] as int?,
      );
      if (!persisted.isStructured ||
          liveMemorySourceHash(source) != liveMemorySourceHash(persisted) ||
          operations.any((op) =>
              op.fact.sourceTurnId != source.playerEventId)) {
        throw StateError('Obsolete memory source.');
      }
      await txn.insert('live_memory_turns', {
        'session_id': sessionId, 'player_event_id': source.playerEventId,
        'source_hash': liveMemorySourceHash(source),
        'operations_json': jsonEncode(
            operations.map((o) => o.toJson()).toList()),
        'created_at': DateTime.now().microsecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    });
  }

  @override
  Future<void> saveMemoryOverride(String sessionId,
      LiveMemoryOverride value) async {
    final db = await database;
    await db.transaction((txn) async {
      final sessions = await txn.query('sessions', columns: ['id'],
          where: 'id = ?', whereArgs: [sessionId], limit: 1);
      if (sessions.isEmpty) throw StateError('Partie supprimée.');
      await txn.insert('live_memory_overrides', {
        'session_id': sessionId, 'fact_id': value.id,
        'payload_json': value.fact == null ? null :
            jsonEncode(value.fact!.toJson()),
        'deleted': value.deleted ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  @override
  Future<void> clearGeneratedMemory(String sessionId) async {
    await (await database).delete('live_memory_turns',
      where: 'session_id = ?', whereArgs: [sessionId]);
  }

  @override
  Future<List<RawGeneration>> listRawGenerations(String sessionId) async {
    final rows = await (await database).query(
      'raw_generations', where: 'session_id = ?', whereArgs: [sessionId],
      orderBy: 'player_event_id ASC',
    );
    return [
      for (final row in rows)
        RawGeneration(
          playerEventId: row['player_event_id'] as int,
          rawText: row['raw_text'] as String,
          compactText: row['compact_text'] as String?,
          firstEventId: row['first_event_id'] as int?,
          lastEventId: row['last_event_id'] as int?,
        ),
    ];
  }

  /// Never publish a generated event without its source RAW in this same
  /// transaction. Rewind atomically prunes obsolete RAW source rows.
  @override
  Future<void> saveNarrativeSnapshot(
      BookSession session, List<RawGeneration> generations) async {
    final db = await database;
    await db.transaction((txn) async {
      final updated = await txn.update('sessions', {
        'timeline_json': session.encodeTimeline(),
        'updated_at': DateTime.now().microsecondsSinceEpoch,
      }, where: 'id = ? AND book_id = ?',
        whereArgs: [session.id, session.bookId]);
      if (updated != 1) {
        throw StateError('Partie supprimée ou introuvable.');
      }
      // Atomically invalidate memory from deleted/regenerated source turns.
      // Manual overrides live in a separate table and remain untouched.
      final valid = {
        for (final source in generations)
          if (source.isStructured)
            source.playerEventId: liveMemorySourceHash(source),
      };
      final memoryRows = await txn.query('live_memory_turns',
        where: 'session_id = ?', whereArgs: [session.id]);
      for (final row in memoryRows) {
        final id = row['player_event_id'] as int;
        if (valid[id] != row['source_hash']) {
          await txn.delete('live_memory_turns',
            where: 'session_id = ? AND player_event_id = ?',
            whereArgs: [session.id, id]);
        }
      }
      await txn.delete('raw_generations',
        where: 'session_id = ?', whereArgs: [session.id]);
      for (final raw in generations) {
        await txn.insert('raw_generations', {
          'session_id': session.id,
          'player_event_id': raw.playerEventId,
          'raw_text': raw.rawText,
          'compact_text': raw.compactText,
          'first_event_id': raw.firstEventId,
          'last_event_id': raw.lastEventId,
        });
      }
    });
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
      version: 10,
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
          'formatter_profile_id TEXT, optimizer_profile_id TEXT, '
          'optimized_lore TEXT, optimized_lore_hash TEXT, '
          'generation_options_json TEXT, '
          'tool_calling_enabled INTEGER NOT NULL DEFAULT 1, '
          'memory_profile_id TEXT, '
          'memory_enabled INTEGER NOT NULL DEFAULT 1, '
          'FOREIGN KEY(book_id) REFERENCES books(id) ON DELETE CASCADE)',
        );
        await db.execute(
          'CREATE INDEX sessions_by_book ON sessions(book_id, updated_at)',
        );
        await _createDiagnostics(db);
        await _createRawGenerations(db);
        await _createMemoryTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 9) await _createMemoryTables(db);
        if (oldVersion < 10) {
          final sessions = await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='sessions'");
          if (sessions.isNotEmpty) {
            await db.execute('ALTER TABLE sessions ADD COLUMN memory_profile_id TEXT');
            await db.execute('ALTER TABLE sessions ADD COLUMN '
                'memory_enabled INTEGER NOT NULL DEFAULT 1');
          }
        }
        if (oldVersion < 2) await _createDiagnostics(db);
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE sessions ADD COLUMN profile_id TEXT');
        }
        if (oldVersion < 4) await _createRawGenerations(db);
        if (oldVersion < 5) {
          await db.execute('ALTER TABLE sessions ADD COLUMN formatter_profile_id TEXT');
          await db.execute('ALTER TABLE sessions ADD COLUMN optimizer_profile_id TEXT');
          await db.execute('ALTER TABLE sessions ADD COLUMN optimized_lore TEXT');
          await db.execute('ALTER TABLE sessions ADD COLUMN optimized_lore_hash TEXT');
        }
        if (oldVersion < 6) {
          await db.execute('ALTER TABLE sessions ADD COLUMN generation_options_json TEXT');
        }
        if (oldVersion < 8) {
          // Historical RAW-only SQLite fixtures intentionally have no
          // sessions table. Do not fail their non-destructive migration.
          final sessions = await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name = 'sessions'",
          );
          if (sessions.isNotEmpty) {
            await db.execute('ALTER TABLE sessions ADD COLUMN '
                'tool_calling_enabled INTEGER NOT NULL DEFAULT 1');
          }
        }
        // Older migrations (<4) create the table using the new schema.
        if (oldVersion >= 4 && oldVersion < 7) {
          await db.execute(
            'ALTER TABLE raw_generations ADD COLUMN compact_text TEXT');
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
    formatterProfileId: row['formatter_profile_id'] as String?,
    optimizerProfileId: row['optimizer_profile_id'] as String?,
    memoryProfileId: row['memory_profile_id'] as String?,
    memoryEnabled: row['memory_enabled'] != 0,
    toolCallingEnabled: row['tool_calling_enabled'] != 0,
    generationOverrides: AiTaskGenerationOverride.decode(
        row['generation_options_json'] as String?),
    optimizedLore: row['optimized_lore'] as String?,
    optimizedLoreHash: row['optimized_lore_hash'] as String?,
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
      'formatter_profile_id': session.formatterProfileId,
      'optimizer_profile_id': session.optimizerProfileId,
      'memory_profile_id': session.memoryProfileId,
      'memory_enabled': session.memoryEnabled ? 1 : 0,
      'tool_calling_enabled': session.toolCallingEnabled ? 1 : 0,
      'generation_options_json': AiTaskGenerationOverride.encode(
          session.generationOverrides),
      'optimized_lore': session.optimizedLore,
      'optimized_lore_hash': session.optimizedLoreHash,
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
