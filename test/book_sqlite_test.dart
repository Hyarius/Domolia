import 'dart:io';

import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show OpenDatabaseOptions;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('SQLite preserves books, profile references and timelines across restart',
      () async {
    final directory = await Directory.systemTemp.createTemp('domolia-book-test-');
    final databasePath = '${directory.path}/books.sqlite';
    final first = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: databasePath,
    );
    addTearDown(() async {
      await first.close();
      await directory.delete(recursive: true);
    });
    const book = BookDefinition(id: 'book-test', title: 'Une histoire',
      narrativeStyle: 'Style A', detailLevel: 4);
    await first.putBook(book);
    await first.bindProfile(book.id, 'local-profile-id');
    final session = BookSession(
      id: 'session-test', bookId: book.id, title: 'Première partie',
      timeline: [
        ChatEntry(id: 0, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Le début'),
        ChatSceneChange(id: 1),
      ],
    );
    await first.putSession(session);
    await first.close();

    final second = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: databasePath,
    );
    addTearDown(second.close);
    expect((await second.listBooks()).single.narrativeStyle, 'Style A');
    expect(await second.profileIdForBook(book.id), 'local-profile-id');
    final restored = (await second.listSessions(book.id)).single;
    expect(restored.timeline, hasLength(2));
    expect(restored.timeline.last, isA<ChatSceneChange>());

    // Updating a book must not destroy child sessions or profile bindings.
    await second.putBook(book.copyWith(title: 'Titre changé'));
    expect(await second.profileIdForBook(book.id), 'local-profile-id');
    expect(await second.findSession(session.id), isNotNull);

    // Removing a single conversation must persist without deleting the book.
    await second.deleteSession(session.id);
    expect(await second.findSession(session.id), isNull);
    expect((await second.listSessions(book.id)), isEmpty);
    expect((await second.findBook(book.id))!.title, 'Titre changé');
    await second.putSession(session);

    await second.deleteBook(book.id);
    expect(await second.findSession(session.id), isNull);
    expect(await second.profileIdForBook(book.id), isNull);
  });

  test('AI traces are capped per conversation, purge one part and cascade on deletion',
      () async {
    final dir = await Directory.systemTemp.createTemp('domolia-diagnostics-');
    final file = '${dir.path}/diagnostics.sqlite';
    final db = SqliteBookStore(factory: databaseFactoryFfi, databasePath: file);
    addTearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });
    const book = BookDefinition(id: 'b', title: 'Test');
    await db.putBook(book);
    const s1 = BookSession(id: 's1', bookId: 'b', title: 'Une');
    const s2 = BookSession(id: 's2', bookId: 'b', title: 'Deux');
    await db.putSession(s1);
    await db.putSession(s2);
    StoredAiDiagnostic trace(String id, String sessionId, int n) =>
        StoredAiDiagnostic(
          id: id,
          sessionId: sessionId,
          createdAtUtc: DateTime.utc(2026, 1, 1).add(Duration(seconds: n)),
          content: '{"format":"test","request":{"body":{"model":"m"}},"response":{"statusCode":200}}',
        );

    await db.putDiagnostic(trace('first', 's1', 1), 2);
    await db.putDiagnostic(trace('second', 's1', 2), 2);
    await db.putDiagnostic(trace('third', 's1', 3), 2);
    await db.putDiagnostic(trace('other', 's2', 4), 2);
    expect((await db.listDiagnostics('s1')).map((d) => d.id),
        ['third', 'second']);
    expect((await db.listDiagnostics('s2')).single.id, 'other');

    // Editing the timeline must not cascade-delete retained diagnostics.
    await db.putSession(s1.copyWith(title: 'Une partie éditée'));
    expect(await db.listDiagnostics('s1'), hasLength(2));

    await db.clearDiagnostics('s1');
    expect(await db.listDiagnostics('s1'), isEmpty);
    expect((await db.findSession('s1'))!.title, 'Une partie éditée');
    expect((await db.listDiagnostics('s2')).single.id, 'other');

    await db.putDiagnostic(trace('new', 's1', 5), 1);
    await db.pruneDiagnostics(0);
    expect(await db.listDiagnostics('s1'), isEmpty);
    expect(await db.listDiagnostics('s2'), isEmpty);

    await db.putDiagnostic(trace('last', 's2', 6), 5);
    await db.deleteSession('s2');
    expect(await db.listDiagnostics('s2'), isEmpty);
  });

  test('Existing v1 book database migrates without losing conversations',
      () async {
    final dir = await Directory.systemTemp.createTemp('domolia-migration-');
    final file = '${dir.path}/legacy.sqlite';
    addTearDown(() async => dir.delete(recursive: true));
    final old = await databaseFactoryFfi.openDatabase(
      file,
      options: OpenDatabaseOptions(version: 1, onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE books (id TEXT PRIMARY KEY, definition_json TEXT NOT NULL)');
        await db.execute(
          'CREATE TABLE book_bindings (book_id TEXT PRIMARY KEY, profile_id TEXT)');
        await db.execute(
          'CREATE TABLE sessions (id TEXT PRIMARY KEY, book_id TEXT NOT NULL, '
          'title TEXT NOT NULL, timeline_json TEXT NOT NULL, '
          'updated_at INTEGER NOT NULL)');
        await db.execute(
          'CREATE INDEX sessions_by_book ON sessions(book_id, updated_at)');
      }),
    );
    const book = BookDefinition(id: 'legacy', title: 'Ancien Livre');
    await old.insert('books', {
      'id': book.id,
      'definition_json': book.exportJson(),
    });
    await old.insert('sessions', {
      'id': 'legacy-session', 'book_id': 'legacy',
      'title': 'Partie intacte', 'timeline_json': '[]',
      'updated_at': 100,
    });
    await old.close();

    final migrated = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: file,
    );
    addTearDown(migrated.close);
    expect((await migrated.findBook('legacy'))!.title, 'Ancien Livre');
    expect((await migrated.findSession('legacy-session'))!.title,
        'Partie intacte');
    await migrated.putDiagnostic(StoredAiDiagnostic(
      id: 'new', sessionId: 'legacy-session',
      createdAtUtc: DateTime.utc(2026), content: '{"format":"test"}',
    ), 5);
    expect(await migrated.listDiagnostics('legacy-session'), hasLength(1));
  });

}
