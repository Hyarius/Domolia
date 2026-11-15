import 'package:flutter/foundation.dart';

import '../ai/ai_diagnostics.dart';
import '../logging/app_logger.dart';
import '../chat/narrator_settings.dart';
import 'book_definition.dart';
import 'book_session.dart';
import 'book_store.dart';

class BookLibraryController extends ChangeNotifier {
  BookLibraryController({required this.store, this.legacyNarrator});

  final BookStore store;
  final NarratorSettingsStore? legacyNarrator;
  final List<BookDefinition> _books = [];
  // Prevent a queued chat autosave from resurrecting a deleted session.
  final Set<String> _deletedSessions = {};
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
      AppLogger.info('Bibliothèque chargée', component: 'books',
        details: {'bookCount': _books.length});
    } catch (failure, stackTrace) {
      AppLogger.error('Lecture de la bibliothèque impossible', component: 'books',
          error: failure, stackTrace: stackTrace);
      error = 'Impossible de lire la bibliothèque locale.';
      initialized = true;
    } finally {
      _notify();
    }
  }

  Future<BookDefinition> create([String title = 'Nouveau Livre']) async {
    final book = BookDefinition(id: BookDefinition.freshId(), title: title);
    await save(book);
    AppLogger.info('Livre créé', component: 'books');
    return book;
  }

  Future<void> save(BookDefinition book) async {
    try {
      await store.putBook(book);
    } catch (failure, stackTrace) {
      AppLogger.error('Sauvegarde du Livre échouée', component: 'books',
          error: failure, stackTrace: stackTrace,
          details: {'coverBytes': book.coverBase64?.length ?? 0});
      rethrow;
    }
    AppLogger.debug('Livre sauvegardé', component: 'books',
        details: {'hasCover': book.coverBase64 != null});
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
    AppLogger.info('Livre supprimé', component: 'books');
    _books.removeWhere((item) => item.id == id);
    _notify();
  }

  Future<BookDefinition> importBook(String json) async {
    var book = BookDefinition.importJson(json);
    if (byId(book.id) != null || await store.findBook(book.id) != null) {
      book = book.copyWith(id: BookDefinition.freshId());
    }
    await save(book);
    AppLogger.info('Livre importé', component: 'books');
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

  /// Most recently changed sessions across all books; never loads their text
  /// into the home screen's displayed metadata.
  Future<List<BookSession>> recentSessions({int limit = 20}) async {
    await initialize();
    final results = <BookSession>[];
    for (final book in _books) {
      results.addAll(await store.listSessions(book.id));
    }
    results.sort((a, b) => (b.updatedAtUtc ?? DateTime.fromMillisecondsSinceEpoch(0))
        .compareTo(a.updatedAtUtc ?? DateTime.fromMillisecondsSinceEpoch(0)));
    return results.take(limit).toList(growable: false);
  }

  Future<void> setSessionProfile(String id, String? profileId) async {
    final current = await store.findSession(id);
    if (current == null) throw StateError('Partie introuvable.');
    // Unlike timeline autosaves, putSession also updates the profile field.
    await store.putSession(current.copyWith(
      aiProfileId: profileId, clearAiProfile: profileId == null));
    AppLogger.info('Profil IA de Partie modifié', component: 'books',
        details: {'hasOverride': profileId != null});
  }

  Future<String?> profileForSession(String id, String bookId) async {
    final part = await store.findSession(id);
    return part?.aiProfileId ?? await store.profileIdForBook(bookId);
  }


  Future<BookSession> newSession(BookDefinition book) async {
    final session = BookSession(
      id: BookSession.freshId(), bookId: book.id,
      title: 'Partie du ${DateTime.now().day}/${DateTime.now().month}',
    );
    await store.putSession(session);
    AppLogger.info('Partie créée', component: 'books');
    return session;
  }

  Future<BookSession?> session(String id) => store.findSession(id);

  Future<void> saveSession(BookSession session) async {
    if (_deletedSessions.contains(session.id)) return;
    await store.updateSession(session);
    AppLogger.trace('Historique de Partie sauvegardé', component: 'books',
        details: {'eventCount': session.timeline.length});
  }

  Future<void> deleteSession(String id) async {
    _deletedSessions.add(id);
    try {
      await store.deleteSession(id);
      AppLogger.info('Partie supprimée', component: 'books');
    } catch (failure, stackTrace) {
      AppLogger.error('Suppression de Partie échouée', component: 'books',
          error: failure, stackTrace: stackTrace);
      _deletedSessions.remove(id);
      rethrow;
    }
  }

  Future<List<StoredAiDiagnostic>> diagnostics(String sessionId) =>
      store.listDiagnostics(sessionId);

  Future<void> saveDiagnostic(
      StoredAiDiagnostic diagnostic, int retentionLimit) =>
      store.putDiagnostic(diagnostic, retentionLimit);

  Future<void> clearDiagnostics(String sessionId) =>
      store.clearDiagnostics(sessionId);

  Future<void> pruneDiagnostics(int retentionLimit) =>
      store.pruneDiagnostics(retentionLimit);

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
