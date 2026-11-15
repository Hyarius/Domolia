import 'dart:convert';

import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/platform/production_services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('IndexedDB stores books, covers and conversation after database reopen',
      () async {
    final first = createProductionBookStore() as SqliteBookStore;
    const bookId = 'test-browser-indexeddb';
    const sessionId = 'test-browser-indexeddb-part';

    // Cleanup makes the test repeatable on the same browser origin.
    await first.deleteBook(bookId);
    const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVQIHWP4z8DwHwAFgAI/ScL/nwAAAABJRU5ErkJggg==';
    const book = BookDefinition(
      id: bookId,
      title: 'Livre enregistré dans IndexedDB',
      coverMime: 'image/png',
      coverBase64: png,
    );
    await first.putBook(book);
    await first.bindProfile(bookId, 'profile-browser');
    await first.putSession(const BookSession(
      id: sessionId,
      bookId: bookId,
      title: 'Partie persistante',
      timeline: [
        ChatEntry(id: 0, speaker: ChatSpeaker.player, name: 'Vous',
          text: 'Un message'),
        ChatSceneChange(id: 1),
      ],
    ));

    await first.close();

    // A brand new store must reload from persistent Web SQLite/IndexedDB.
    final reopened = createProductionBookStore() as SqliteBookStore;
    addTearDown(reopened.close);
    final restored = await reopened.findBook(bookId);
    expect(restored, isNotNull);
    expect(restored!.title, book.title);
    expect(base64Decode(restored.coverBase64!), base64Decode(png));
    expect(await reopened.profileIdForBook(bookId), 'profile-browser');
    final session = await reopened.findSession(sessionId);
    expect(session, isNotNull);
    expect(session!.timeline, hasLength(2));
    expect(session.timeline.last, isA<ChatSceneChange>());

    await reopened.deleteBook(bookId);
    expect(await reopened.findSession(sessionId), isNull);
  }, skip: !kIsWeb);
}
