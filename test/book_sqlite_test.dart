import 'dart:io';

import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/raw_generation.dart';
import 'package:flutter_test/flutter_test.dart';
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
    // A delayed timeline save is update-only and cannot recreate deletion.
    await second.updateSession(session.copyWith(title: 'Late write'));
    expect(await second.findSession(session.id), isNull);
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


  test('RAW pending survives restart and a retry commits events atomically',
      () async {
    final dir = await Directory.systemTemp.createTemp('domolia-raw-');
    final file = '${dir.path}/raw.sqlite';
    final first = SqliteBookStore(factory: databaseFactoryFfi, databasePath: file);
    addTearDown(() async {
      await first.close();
      await dir.delete(recursive: true);
    });
    await first.putBook(const BookDefinition(id: 'b', title: 'Livre'));
    const session = BookSession(id: 's', bookId: 'b', title: 'Partie', timeline: [
      ChatEntry(id: 0, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Je quitte la grotte'),
    ]);
    await first.putSession(session);
    await first.saveNarrativeSnapshot(session, const [
      RawGeneration(playerEventId: 0, rawText: 'Le temple apparaît.'),
    ]);
    await first.close();

    final second = SqliteBookStore(factory: databaseFactoryFfi, databasePath: file);
    addTearDown(second.close);
    final pending = await second.listRawGenerations('s');
    expect(pending.single.rawText, 'Le temple apparaît.');
    expect(pending.single.isStructured, false);
    expect((await second.findSession('s'))!.timeline, hasLength(1));

    final committed = session.copyWith(timeline: [
      ...session.timeline,
      const ChatSceneChange(id: 1),
      const ChatEntry(id: 2, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Le temple apparaît.'),
    ]);
    await second.saveNarrativeSnapshot(committed, [
      pending.single.structured(1, 2),
    ]);
    await second.close();

    final third = SqliteBookStore(factory: databaseFactoryFfi, databasePath: file);
    addTearDown(third.close);
    expect((await third.findSession('s'))!.timeline, hasLength(3));
    expect((await third.listRawGenerations('s')).single.isStructured, true);
    await third.saveNarrativeSnapshot(session, const []);
    expect(await third.listRawGenerations('s'), isEmpty);
    expect((await third.findSession('s'))!.timeline, hasLength(1));
  });

  test('Invalid RAW insert rolls back timeline and preserves diagnostics',
      () async {
    final dir = await Directory.systemTemp.createTemp('domolia-raw-txn-');
    final file = '${dir.path}/txn.sqlite';
    final db = SqliteBookStore(factory: databaseFactoryFfi, databasePath: file);
    addTearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });
    await db.putBook(const BookDefinition(id: 'b', title: 'Livre'));
    const session = BookSession(id: 's', bookId: 'b', title: 'Partie', timeline: [
      ChatEntry(id: 10, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Une action'),
    ]);
    await db.putSession(session);
    await db.putDiagnostic(StoredAiDiagnostic(
      id: 'trace', sessionId: 's', createdAtUtc: DateTime.utc(2026),
      content: '{"format":"test"}',
    ), 5);
    final changed = session.copyWith(timeline: [
      ...session.timeline,
      const ChatEntry(id: 11, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Réponse'),
    ]);
    await expectLater(db.saveNarrativeSnapshot(changed, const [
      RawGeneration(playerEventId: 10, rawText: 'Réponse'),
      RawGeneration(playerEventId: 10, rawText: 'Conflit'),
    ]), throwsA(isA<Exception>()));
    expect((await db.findSession('s'))!.timeline, hasLength(1));
    expect(await db.listRawGenerations('s'), isEmpty);
    expect(await db.listDiagnostics('s'), hasLength(1));

    await db.deleteSession('s');
    expect(await db.listRawGenerations('s'), isEmpty);
    expect(await db.listDiagnostics('s'), isEmpty);
    await expectLater(db.saveNarrativeSnapshot(changed, const []),
        throwsStateError);
  });

  test('Manual scene insertion can be reloaded with stable nonmonotonic IDs', () {
    const original = BookSession(id: 's', bookId: 'b', title: 'Partie', timeline: [
      ChatEntry(id: 1, speaker: ChatSpeaker.player, name: 'Vous', text: 'Oui'),
      ChatSceneChange(id: 7),
      ChatEntry(id: 3, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Un temple'),
    ]);
    final restored = BookSession.decodeTimeline(original.encodeTimeline());
    expect(restored.map((e) => e.id), [1, 7, 3]);
    expect(() => BookSession.decodeTimeline(
      '[{"id":1,"type":"scene_change"},{"id":1,"type":"scene_change"}]'),
      throwsFormatException);
  });

}
