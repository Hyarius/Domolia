import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../chat/narrator_settings.dart';
import 'book_definition.dart';
import 'book_session.dart';
import 'book_store.dart';

class BookLibraryController extends ChangeNotifier {
  BookLibraryController({required this.store, this.legacyNarrator});

  final BookStore store;
  final NarratorSettingsStore? legacyNarrator;
  final List<BookDefinition> _books = [];
  bool initialized = false;
  bool legacyAvailable = false;
  String? error;
  Future<void>? _loading;
  bool _closed = false;

  List<BookDefinition> get books => List.unmodifiable(_books);

  BookDefinition? byId(String id) {
    for (final book in _books) {
      if (book.id == id) return book;
    }
    return null;
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> initialize() => _loading ??= _load();

  Future<void> _load() async {
    try {
      _books
        ..clear()
        ..addAll(await store.listBooks());
      legacyAvailable = legacyNarrator != null &&
          byId('legacy-narrator-v1') == null &&
          await legacyNarrator!.read() != null;
      initialized = true;
    } catch (_) {
      error = 'Impossible de lire la bibliothèque locale.';
      initialized = true;
    } finally {
      _notify();
    }
  }

  Future<BookDefinition> create([String title = 'Nouveau Livre']) async {
    final book = BookDefinition(id: BookDefinition.freshId(), title: title);
    await save(book);
    return book;
  }

  Future<void> save(BookDefinition book) async {
    await store.putBook(book);
    final index = _books.indexWhere((item) => item.id == book.id);
    if (index < 0) {
      _books.insert(0, book);
    } else {
      _books[index] = book;
    }
    _notify();
  }

  Future<void> remove(String id) async {
    await store.deleteBook(id);
    _books.removeWhere((item) => item.id == id);
    _notify();
  }

  Future<BookDefinition> importBook(String json) async {
    var book = BookDefinition.importJson(json);
    if (byId(book.id) != null || await store.findBook(book.id) != null) {
      book = book.copyWith(id: BookDefinition.freshId());
    }
    await save(book);
    await store.bindProfile(book.id, null);
    return book;
  }

  Future<BookDefinition?> createFromLegacy() async {
    if (!legacyAvailable || legacyNarrator == null) return null;
    final narrator = await legacyNarrator!.read();
    if (narrator == null) return null;
    // Stable ID makes repeated / interrupted migration idempotent.
    final existing = await store.findBook('legacy-narrator-v1');
    if (existing != null) {
      legacyAvailable = false;
      _notify();
      return existing;
    }
    final book = BookDefinition(
      id: 'legacy-narrator-v1',
      title: 'Mon premier Livre',
      narrativeStyle: narrator.narrativePrompt,
      openingMessages: narrator.openingMessages,
    );
    await save(book);
    legacyAvailable = false;
    _notify();
    return book;
  }

  Future<String?> profileFor(String bookId) => store.profileIdForBook(bookId);

  Future<void> setProfile(String bookId, String? profileId) async {
    await store.bindProfile(bookId, profileId);
    _notify();
  }

  Future<List<BookSession>> sessions(String bookId) => store.listSessions(bookId);

  Future<BookSession> newSession(BookDefinition book) async {
    final session = BookSession(
      id: BookSession.freshId(), bookId: book.id,
      title: 'Partie du ${DateTime.now().day}/${DateTime.now().month}',
    );
    await store.putSession(session);
    return session;
  }

  Future<BookSession?> session(String id) => store.findSession(id);

  Future<void> saveSession(BookSession session) => store.putSession(session);

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
