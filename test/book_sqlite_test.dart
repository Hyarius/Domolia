import 'dart:io';

import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:domolia/chat/chat_protocol.dart';
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
    const session = BookSession(
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

    await second.deleteBook(book.id);
    expect(await second.findSession(session.id), isNull);
    expect(await second.profileIdForBook(book.id), isNull);
  });
}
