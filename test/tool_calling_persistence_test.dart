import 'dart:io';

import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('Party tool toggle persists independently of other Parties', () async {
    final dir = await Directory.systemTemp.createTemp('domolia-tools-');
    final file = '${dir.path}/books.sqlite';
    final first = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: file);
    addTearDown(() async {
      await first.close();
      await dir.delete(recursive: true);
    });
    const book = BookDefinition(id: 'book', title: 'Book');
    await first.putBook(book);
    await first.putSession(const BookSession(
        id: 'a', bookId: 'book', title: 'A', toolCallingEnabled: false));
    await first.putSession(const BookSession(
        id: 'b', bookId: 'book', title: 'B', toolCallingEnabled: true));
    await first.close();
    final second = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: file);
    addTearDown(second.close);
    expect((await second.findSession('a'))!.toolCallingEnabled, false);
    expect((await second.findSession('b'))!.toolCallingEnabled, true);
    final a = (await second.findSession('a'))!;
    await second.putSession(a.copyWith(toolCallingEnabled: true));
    expect((await second.findSession('a'))!.toolCallingEnabled, true);
    expect((await second.findSession('b'))!.toolCallingEnabled, true);
  });

  test('Existing v7 sessions migrate to tool enabled by default', () async {
    final dir = await Directory.systemTemp.createTemp('domolia-tool-migration-');
    final file = '${dir.path}/books.sqlite';
    addTearDown(() async => dir.delete(recursive: true));
    final old = await databaseFactoryFfi.openDatabase(
      file,
      options: OpenDatabaseOptions(version: 7, onCreate: (db, version) async {
        await db.execute('CREATE TABLE books (id TEXT PRIMARY KEY, '
            'definition_json TEXT NOT NULL)');
        await db.execute('CREATE TABLE sessions (id TEXT PRIMARY KEY, '
            'book_id TEXT NOT NULL, title TEXT NOT NULL, '
            'timeline_json TEXT NOT NULL, updated_at INTEGER NOT NULL, '
            'profile_id TEXT, formatter_profile_id TEXT, '
            'optimizer_profile_id TEXT, optimized_lore TEXT, '
            'optimized_lore_hash TEXT, generation_options_json TEXT)');
        await db.execute('CREATE TABLE raw_generations ('
            'session_id TEXT NOT NULL, player_event_id INTEGER NOT NULL, '
            'raw_text TEXT NOT NULL, compact_text TEXT, '
            'first_event_id INTEGER, last_event_id INTEGER, '
            'PRIMARY KEY(session_id, player_event_id))');
      }),
    );
    await old.insert('books', {'id': 'old-book',
      'definition_json': const BookDefinition(
          id: 'old-book', title: 'Legacy').exportJson()});
    await old.insert('sessions', {'id': 'old-part', 'book_id': 'old-book',
      'title': 'Legacy part', 'timeline_json': '[]',
      'updated_at': 100, 'profile_id': 'old-profile'});
    await old.close();
    final migrated = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: file);
    addTearDown(migrated.close);
    final session = (await migrated.findSession('old-part'))!;
    expect(session.aiProfileId, 'old-profile');
    expect(session.toolCallingEnabled, true);
    await migrated.putSession(session.copyWith(toolCallingEnabled: false));
    expect((await migrated.findSession('old-part'))!.toolCallingEnabled, false);
  });
}
