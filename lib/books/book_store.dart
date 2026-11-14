import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

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
  Future<void> deleteSession(String id);
}

class SqliteBookStore implements BookStore {
  SqliteBookStore({DatabaseFactory? factory, String? databasePath})
      : _factory = factory ?? databaseFactory,
        _databasePath = databasePath;

  final DatabaseFactory _factory;
  final String? _databasePath;
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final location = _databasePath ?? path.join(
      (await getApplicationSupportDirectory()).path, 'domolia_books.sqlite',
    );
    return _db ??= await _factory.openDatabase(
      location,
      options: OpenDatabaseOptions(
      version: 1,
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
          'updated_at INTEGER NOT NULL, '
          'FOREIGN KEY(book_id) REFERENCES books(id) ON DELETE CASCADE)',
        );
        await db.execute(
          'CREATE INDEX sessions_by_book ON sessions(book_id, updated_at)',
        );
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
    await (await database).insert('sessions', {
      'id': session.id,
      'book_id': session.bookId,
      'title': session.title,
      'timeline_json': session.encodeTimeline(),
      'updated_at': DateTime.now().microsecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> deleteSession(String id) async {
    await (await database).delete('sessions', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
