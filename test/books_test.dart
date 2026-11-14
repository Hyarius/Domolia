import 'dart:convert';

import 'package:domolia/ai/ai_controller.dart';
import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_editor_page.dart';
import 'package:domolia/books/book_library_controller.dart';
import 'package:domolia/books/book_library_page.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/narrator.dart';
import 'package:domolia/chat/narrator_settings.dart';
import 'package:domolia/theme/domolia_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _MemoryBooks implements BookStore {
  final Map<String, BookDefinition> definitions = {};
  final Map<String, String?> bindings = {};
  final Map<String, BookSession> savedSessions = {};
  @override
  Future<List<BookDefinition>> listBooks() async => definitions.values.toList();
  @override
  Future<BookDefinition?> findBook(String id) async => definitions[id];
  @override
  Future<void> putBook(BookDefinition book) async {
    book.validate();
    definitions[book.id] = book;
  }
  @override
  Future<void> deleteBook(String id) async {
    definitions.remove(id);
    bindings.remove(id);
    savedSessions.removeWhere((key, item) => item.bookId == id);
    savedDiagnostics.removeWhere((key, item) =>
        !savedSessions.containsKey(item.sessionId));
  }
  @override
  Future<String?> profileIdForBook(String bookId) async => bindings[bookId];
  @override
  Future<void> bindProfile(String bookId, String? profileId) async {
    bindings[bookId] = profileId;
  }
  @override
  Future<List<BookSession>> listSessions(String id) async =>
      savedSessions.values.where((s) => s.bookId == id).toList();
  @override
  Future<BookSession?> findSession(String id) async => savedSessions[id];
  @override
  Future<void> putSession(BookSession session) async {
    savedSessions[session.id] = session;
  }
  @override
  Future<void> deleteSession(String id) async {
    savedSessions.remove(id);
    savedDiagnostics.removeWhere((key, item) => item.sessionId == id);
  }
  final Map<String, StoredAiDiagnostic> savedDiagnostics = {};
  @override
  Future<void> putDiagnostic(
      StoredAiDiagnostic diagnostic, int retentionLimit) async {
    if (retentionLimit > 0) savedDiagnostics[diagnostic.id] = diagnostic;
    final values = (await listDiagnostics(diagnostic.sessionId));
    for (final old in values.skip(retentionLimit)) {
      savedDiagnostics.remove(old.id);
    }
  }
  @override
  Future<List<StoredAiDiagnostic>> listDiagnostics(String sessionId) async =>
      (savedDiagnostics.values.where((d) => d.sessionId == sessionId).toList()
        ..sort((a, b) => b.createdAtUtc.compareTo(a.createdAtUtc)));
  @override
  Future<void> clearDiagnostics(String sessionId) async {
    savedDiagnostics.removeWhere((key, value) => value.sessionId == sessionId);
  }
  @override
  Future<void> pruneDiagnostics(int retentionLimit) async {
    for (final session in savedSessions.values) {
      final values = await listDiagnostics(session.id);
      for (final old in values.skip(retentionLimit)) {
        savedDiagnostics.remove(old.id);
      }
    }
  }
}

class _Legacy implements NarratorSettingsStore {
  _Legacy(this.saved);
  Narrator? saved;
  @override
  Future<Narrator?> read() async => saved;
  @override
  Future<void> write(Narrator narrator) async => saved = narrator;
}

class _Profiles implements AiProfileStore {
  AiProfilesState? state;
  _Profiles(this.state);
  @override
  Future<AiProfilesState?> read() async => state;
  @override
  Future<void> write(AiProfilesState value) async => state = value;
}

class _NoNetwork implements AiChatProvider {
  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async =>
      throw StateError('Test must not use a provider');
  @override
  Future<String> complete(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) async => throw StateError('Test must not use a provider');
}

const _profile = AiProfile(
  id: 'profile-1',
  name: 'Connexion de test',
  baseUrl: 'https://example.invalid',
  model: 'placeholder',
  apiKey: 'private-api-secret',
  nsfwCompatibility: AiNsfwCompatibility.unsupported,
);

void main() {
  test('Books remain independent, with profile binding outside export', () async {
    final store = _MemoryBooks();
    final library = BookLibraryController(store: store);
    addTearDown(library.dispose);
    await library.initialize();
    final a = await library.create('Livre A');
    final b = await library.create('Livre B');
    await library.save(a.copyWith(narrativeStyle: 'Style de A', detailLevel: 1));
    await library.save(b.copyWith(narrativeStyle: 'Style de B', detailLevel: 5));
    await library.setProfile(a.id, 'secret-local-profile-id');
    await library.setProfile(b.id, 'secret-local-profile-id');
    final restarted = BookLibraryController(store: store);
    addTearDown(restarted.dispose);
    await restarted.initialize();
    expect(restarted.books, hasLength(2));
    expect(restarted.byId(a.id)!.narrativeStyle, 'Style de A');
    expect(restarted.byId(b.id)!.narrativeStyle, 'Style de B');
    expect(await restarted.profileFor(b.id), 'secret-local-profile-id');
    final exported = restarted.byId(a.id)!.exportJson();
    expect(exported, isNot(contains('secret-local-profile-id')));
    expect(exported, isNot(contains('private-api-secret')));
    expect(exported, isNot(contains('apiKey')));
    await library.remove(a.id);
    expect(await store.findBook(a.id), isNull);
    expect(await store.findBook(b.id), isNotNull);
  });

  test('Five distinct detail prompts preserve the NDJSON contract', () {
    for (var level = 1; level <= 5; level++) {
      final book = BookDefinition(
        id: 'book-level-$level', title: 'Niveau $level',
        detailLevel: level,
      );
      expect(book.narrator.systemPrompt,
        contains(BookDefinition.detailInstructions[level - 1]));
      expect(book.narrator.systemPrompt, contains('"type":"scene_change"'));
      expect(book.narrator.protocolPrompt, defaultNarratorProtocolPrompt);
      expect(book.narrator.systemPrompt,
        isNot(contains('Niveau de détail ${level == 5 ? 1 : level + 1} :')));
    }
  });

  test('Invalid/oversized JSON is rejected and an import collision is safe',
      () async {
    final store = _MemoryBooks();
    final controller = BookLibraryController(store: store);
    addTearDown(controller.dispose);
    await controller.initialize();
    final original = await controller.create('Original');
    final imported = await controller.importBook(original.exportJson());
    expect(imported.id, isNot(original.id));
    expect(controller.books, hasLength(2));
    expect(() => BookDefinition.importJson('not json'), throwsFormatException);
    expect(() => BookDefinition.importJson('{}'), throwsFormatException);
    expect(() => BookDefinition.importJson('x' * (BookDefinition.maxJsonBytes + 1)),
      throwsFormatException);
    final poisoned = jsonDecode(original.exportJson()) as Map<String, dynamic>;
    poisoned['apiKey'] = 'a private key';
    expect(() => BookDefinition.importJson(jsonEncode(poisoned)),
      throwsFormatException);
    final oversizedCover = jsonDecode(original.exportJson())
        as Map<String, dynamic>;
    oversizedCover['cover'] = {
      'mime': 'image/png', 'base64': base64Encode(List<int>.filled(
        BookDefinition.maxCoverBytes + 1, 17)),
    };
    expect(() => BookDefinition.importJson(jsonEncode(oversizedCover)),
      throwsFormatException);
  });

  test('Migration from narrator settings is idempotent and non-destructive',
      () async {
    final old = _Legacy(const Narrator(
      narrativePrompt: 'Ancien style inchangé',
      openingMessages: ['Ouverture préservée'],
    ));
    final store = _MemoryBooks();
    final first = BookLibraryController(store: store, legacyNarrator: old);
    addTearDown(first.dispose);
    await first.initialize();
    expect(first.legacyAvailable, true);
    final book = await first.createFromLegacy();
    expect(book!.narrativeStyle, 'Ancien style inchangé');
    expect(book.openingMessages, ['Ouverture préservée']);
    expect((await old.read())!.narrativePrompt, 'Ancien style inchangé');
    final second = BookLibraryController(store: store, legacyNarrator: old);
    addTearDown(second.dispose);
    await second.initialize();
    expect(second.legacyAvailable, false);
    expect(await second.createFromLegacy(), null);
    expect(second.books, hasLength(1));
  });

  test('Sessions isolate events and restore without replaying opening', () {
    const session = BookSession(id: 'part-1', bookId: 'book-1', title: 'Aventure',
      timeline: [
        ChatEntry(id: 0, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Ouverture'),
        ChatEntry(id: 1, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Je pars'),
        ChatSceneChange(id: 2),
      ],
    );
    final decoded = BookSession.decodeTimeline(session.encodeTimeline());
    expect(decoded, hasLength(3));
    expect(decoded.last, isA<ChatSceneChange>());
    final controller = NarrativeChatController(
      provider: _NoNetwork(),
      configuration: () => null,
    );
    addTearDown(controller.dispose);
    controller.restoreTimeline(decoded);
    controller.beginConversation();
    expect(controller.timeline, hasLength(3));
    expect(controller.messages.first.text, 'Ouverture');
    expect(controller.currentSceneMessages, isEmpty);
  });

  test('AI content capability can be changed without affecting secrets', () async {
    final store = _Profiles(const AiProfilesState(
      profiles: [_profile], selectedId: 'profile-1',
    ));
    final ai = AiConnectionController(store: store, provider: _NoNetwork());
    addTearDown(ai.dispose);
    await ai.initialize();
    expect(ai.selectedProfile.nsfwCompatibility,
      AiNsfwCompatibility.unsupported);
    expect(await ai.setNsfwCompatibility(AiNsfwCompatibility.supported), true);
    expect(store.state!.profiles.single.apiKey, 'private-api-secret');
    expect(store.state!.profiles.single.nsfwCompatibility,
      AiNsfwCompatibility.supported);
  });

  testWidgets('Library displays multiple book covers and opens a book',
      (tester) async {
    final store = _MemoryBooks();
    final library = BookLibraryController(store: store);
    addTearDown(library.dispose);
    await library.initialize();
    await library.create('Livre A');
    await library.create('Livre B');
    BookDefinition? opened;
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: BookLibraryPage(
        library: library, onOpen: (b) => opened = b,
      )),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('booksGrid')), findsOneWidget);
    expect(find.text('Livre A'), findsWidgets);
    expect(find.text('Livre B'), findsWidgets);
    await tester.tap(find.byTooltip('Ouvrir Livre A'));
    expect(opened!.title, 'Livre A');
  });

  testWidgets('Three editable tabs and NSFW warning work on narrow Android',
      (tester) async {
    tester.view.physicalSize = const Size(320, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final store = _MemoryBooks();
    final library = BookLibraryController(store: store);
    addTearDown(library.dispose);
    await library.initialize();
    final book = await library.create('Mon Livre');
    await library.setProfile(book.id, _profile.id);
    final ai = AiConnectionController(
      store: _Profiles(const AiProfilesState(
        profiles: [_profile], selectedId: 'profile-1',
      )), provider: _NoNetwork(),
    );
    addTearDown(ai.dispose);
    await tester.pumpWidget(MaterialApp(theme: DomoliaTheme.dark,
      home: BookEditorPage(book: book, library: library,
        ai: ai, onPlay: (_, session) async {}),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bookTitle')), findsOneWidget);
    await tester.tap(find.text('Narrateur'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bookDetailSlider')), findsOneWidget);
    expect(find.text('Équilibré'), findsOneWidget);
    await tester.tap(find.text('Système'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bookOpenings')), findsOneWidget);
    await tester.tap(find.text('Livre').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('bookNsfw')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bookNsfw')));
    await tester.pumpAndSettle();
    expect(library.byId(book.id)!.nsfw, true);
    await tester.tap(find.text('Système'));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const ValueKey('bookTab-2')),
        const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.textContaining('ne prend pas en charge le mode NSFW'),
      findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Une partie peut être supprimée après confirmation, sans toucher aux autres',
      (tester) async {
    final store = _MemoryBooks();
    final library = BookLibraryController(store: store);
    addTearDown(library.dispose);
    await library.initialize();
    final book = await library.create('Livre à parties');
    final a = await library.newSession(book);
    final b = await library.newSession(book);
    final ai = AiConnectionController(
      store: _Profiles(const AiProfilesState(
        profiles: [_profile], selectedId: 'profile-1',
      )), provider: _NoNetwork(),
    );
    addTearDown(ai.dispose);
    var plays = 0;
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: BookEditorPage(
        book: book, library: library, ai: ai,
        onPlay: (_, _) async => plays++,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('bookPlay')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('bookSession-${a.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('bookSession-${b.id}')), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('bookDeleteSession-${a.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Supprimer cette partie ?'), findsOneWidget);
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(await library.session(a.id), isNotNull);

    await tester.tap(find.byKey(ValueKey('bookDeleteSession-${a.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Supprimer'));
    await tester.pumpAndSettle();
    expect(await library.session(a.id), isNull);
    expect(await library.session(b.id), isNotNull);
    expect(plays, 0);

    await tester.tap(find.byKey(const ValueKey('bookPlay')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('bookSession-${a.id}')), findsNothing);
    expect(find.byKey(ValueKey('bookSession-${b.id}')), findsOneWidget);
  });

}
