import 'dart:convert';

import 'package:domolia/ai/ai_controller.dart';
import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/ai_task_generation.dart';
import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_lore.dart';
import 'package:domolia/books/book_editor_page.dart';
import 'package:domolia/books/book_library_controller.dart';
import 'package:domolia/books/book_library_page.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/conversation_settings_page.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/narrator.dart';
import 'package:domolia/chat/narrator_settings.dart';
import 'package:domolia/chat/raw_generation.dart';
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
  Future<void> updateSession(BookSession session) async {
    if (savedSessions.containsKey(session.id)) {
      savedSessions[session.id] = session;
    }
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

  test('Five distinct detail prompts preserve literary rules without JSON', () {
    for (var level = 1; level <= 5; level++) {
      final book = BookDefinition(
        id: 'book-level-$level', title: 'Niveau $level',
        detailLevel: level,
      );
      expect(book.narrator.systemPrompt,
        contains(BookDefinition.detailInstructions[level - 1]));
      expect(book.narrator.systemPrompt, isNot(contains('"type":"scene_change"')));
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

  testWidgets('Four editable tabs and NSFW warning work on narrow Android',
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
    await tester.drag(find.byKey(const ValueKey('bookTab-3')),
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
    await library.saveDiagnostic(StoredAiDiagnostic(
      id: 'diagnostic-a',
      sessionId: a.id,
      createdAtUtc: DateTime.utc(2026),
      content: '{"format":"diagnostic"}',
    ), 10);
    await library.saveDiagnostic(StoredAiDiagnostic(
      id: 'diagnostic-b',
      sessionId: b.id,
      createdAtUtc: DateTime.utc(2026),
      content: '{"format":"diagnostic"}',
    ), 10);
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
    await tester.tap(find.byKey(ValueKey('bookPurgeSession-${a.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Purger les diagnostics ?'), findsOneWidget);
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(await library.diagnostics(a.id), hasLength(1));

    await tester.tap(find.byKey(ValueKey('bookPurgeSession-${a.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Purger'));
    await tester.pumpAndSettle();
    expect(await library.diagnostics(a.id), isEmpty);
    expect(await library.diagnostics(b.id), hasLength(1));
    expect(await library.session(a.id), isNotNull);

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

  test('Une écriture tardive ne recrée jamais une partie supprimée', () async {
    final store = _MemoryBooks();
    final library = BookLibraryController(store: store);
    addTearDown(library.dispose);
    await library.initialize();
    final book = await library.create('Test de suppression');
    final session = await library.newSession(book);
    await library.deleteSession(session.id);
    await library.saveSession(session.copyWith(title: 'Écriture tardive'));
    expect(await library.session(session.id), isNull);
    expect(await store.findBook(book.id), isNotNull);
  });


  test('Recent sessions include every Book and are sorted newest first', () async {
    final store = _MemoryBooks();
    final library = BookLibraryController(store: store);
    addTearDown(library.dispose);
    await library.initialize();
    final one = await library.create('Book One');
    final two = await library.create('Book Two');
    await store.putSession(BookSession(
      id: 'old', bookId: one.id, title: 'Old',
      updatedAtUtc: DateTime.utc(2026, 11, 1),
    ));
    await store.putSession(BookSession(
      id: 'new', bookId: two.id, title: 'New',
      updatedAtUtc: DateTime.utc(2026, 11, 14),
    ));
    await store.putSession(BookSession(
      id: 'mid', bookId: one.id, title: 'Middle',
      updatedAtUtc: DateTime.utc(2026, 11, 10),
    ));
    expect((await library.recentSessions()).map((s) => s.id),
      ['new', 'mid', 'old']);
    expect((await library.recentSessions(limit: 2)).map((s) => s.id),
      ['new', 'mid']);
  });

  testWidgets('Conversation settings only select existing profiles and export',
      (tester) async {
    tester.view.physicalSize = const Size(420, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final store = _MemoryBooks();
    final library = BookLibraryController(store: store);
    addTearDown(library.dispose);
    await library.initialize();
    final book = await library.create('Aventure');
    final session = await library.newSession(book);
    final ai = AiConnectionController(
      store: _Profiles(const AiProfilesState(
        profiles: [_profile], selectedId: 'profile-1',
      )), provider: _NoNetwork(),
    );
    addTearDown(ai.dispose);
    final chat = NarrativeChatController(
      provider: _NoNetwork(), configuration: () => null,
    );
    addTearDown(chat.dispose);
    chat.restoreTimeline(const [
      ChatEntry(id: 0, speaker: ChatSpeaker.narrator,
        name: 'Narrateur', text: 'Prologue'),
      ChatEntry(id: 1, speaker: ChatSpeaker.player,
        name: 'Vous', text: 'Je suis prêt'),
    ]);
    var returned = false;
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: ConversationSettingsPage(
        library: library, ai: ai, chat: chat,
        bookId: book.id, sessionId: session.id,
        bookTitle: book.title, sessionTitle: session.title,
        onBack: () => returned = true,
      )),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('conversationSettings')), findsOneWidget);
    expect(find.text('Paramètres de la conversation'), findsOneWidget);
    expect(find.text('Créer une configuration'), findsNothing);
    expect(find.text('Profil par défaut du Livre'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('conversationDefaultProfile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connexion de test').last);
    await tester.pumpAndSettle();
    expect((await library.session(session.id))!.aiProfileId, 'profile-1');
    expect(ai.profiles, hasLength(1));

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('conversationExport')), 250);
    await tester.ensureVisible(
      find.byKey(const ValueKey('conversationExport')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('conversationExport')));
    await tester.pumpAndSettle();
    expect(find.text('Toute la conversation'), findsOneWidget);
    expect(find.text('Portée de l’export'), findsOneWidget);
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byTooltip('Retour à la conversation'), -250);
    await tester.ensureVisible(find.byTooltip('Retour à la conversation'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Retour à la conversation'));
    expect(returned, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Conversation settings warn about a deleted AI profile',
      (tester) async {
    final store = _MemoryBooks();
    final library = BookLibraryController(store: store);
    addTearDown(library.dispose);
    await library.initialize();
    final book = await library.create('Livre');
    final session = await library.newSession(book);
    await library.setSessionProfile(session.id, 'removed-profile');
    final ai = AiConnectionController(
      store: _Profiles(const AiProfilesState(
        profiles: [_profile], selectedId: 'profile-1',
      )), provider: _NoNetwork(),
    );
    addTearDown(ai.dispose);
    final chat = NarrativeChatController(
      provider: _NoNetwork(), configuration: () => null,
    );
    addTearDown(chat.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: ConversationSettingsPage(
        library: library, ai: ai, chat: chat, bookId: book.id,
        sessionId: session.id, onBack: () {},
      )),
    ));
    await tester.pumpAndSettle();
    expect(find.text('La configuration précédente a été supprimée.'),
      findsOneWidget);
    expect(tester.takeException(), isNull);
  });


  testWidgets('Session settings export the current canonical Book JSON beside chat export',
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
    final book = await library.create('Skogheim');
    final session = await library.newSession(book);
    await library.setProfile(book.id, 'secret-local-profile-id');
    await library.save(book.copyWith(lore: const BookLore(
      global: LoreGlobal(universe: 'Skogheim', rules: 'La paix du foyer.'),
      characters: [LoreCharacter(id: 'astrid', name: 'Astrid')],
    )));
    final ai = AiConnectionController(
      store: _Profiles(const AiProfilesState(
        profiles: [_profile], selectedId: 'profile-1',
      )), provider: _NoNetwork(),
    );
    addTearDown(ai.dispose);
    final chat = NarrativeChatController(
      provider: _NoNetwork(), configuration: () => null,
    );
    addTearDown(chat.dispose);
    chat.restoreTimeline(const [
      ChatEntry(id: 0, speaker: ChatSpeaker.player,
        name: 'Vous', text: 'Conversation privée'),
    ]);
    String? savedName;
    String? exported;
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: ConversationSettingsPage(
        library: library, ai: ai, chat: chat,
        bookId: book.id, sessionId: session.id,
        onBack: () {},
        onExportBookJson: (name, bytes) async {
          savedName = name;
          exported = utf8.decode(bytes);
        },
      )),
    ));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('conversationExport')), 200);
    expect(find.byKey(const ValueKey('conversationExport')), findsOneWidget);
    expect(find.byKey(const ValueKey('bookRawExport')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('bookRawExport')), 200);
    await tester.ensureVisible(find.byKey(const ValueKey('bookRawExport')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bookRawExport')));
    await tester.pumpAndSettle();

    expect(savedName, 'Skogheim.json');
    final restored = BookDefinition.importJson(exported!);
    expect(restored.title, 'Skogheim');
    expect(restored.lore.global.universe, 'Skogheim');
    expect(restored.lore.characters.single.name, 'Astrid');
    expect(exported!, isNot(contains('secret-local-profile-id')));
    expect(exported!, isNot(contains('private-api-secret')));
    expect(exported!, isNot(contains('Conversation privée')));
    expect(exported!, isNot(contains(session.id)));
    expect(tester.takeException(), isNull);

    // The active Book may have changed since this settings screen opened.
    await library.save(library.byId(book.id)!.copyWith(
      lore: const BookLore(global: LoreGlobal(universe: 'Skogheim renouvelé')),
    ));
    await tester.tap(find.byKey(const ValueKey('bookRawExport')));
    await tester.pumpAndSettle();
    expect(BookDefinition.importJson(exported!).lore.global.universe,
      'Skogheim renouvelé');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Session export of a deleted Book fails safely',
      (tester) async {
    final store = _MemoryBooks();
    final library = BookLibraryController(store: store);
    addTearDown(library.dispose);
    await library.initialize();
    final book = await library.create('Supprimé');
    final session = await library.newSession(book);
    final ai = AiConnectionController(
      store: _Profiles(const AiProfilesState(
        profiles: [_profile], selectedId: 'profile-1',
      )), provider: _NoNetwork(),
    );
    addTearDown(ai.dispose);
    final chat = NarrativeChatController(
      provider: _NoNetwork(), configuration: () => null,
    );
    addTearDown(chat.dispose);
    var called = false;
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: ConversationSettingsPage(
        library: library, ai: ai, chat: chat,
        bookId: book.id, sessionId: session.id,
        onBack: () {},
        onExportBookJson: (_, _) async { called = true; },
      )),
    ));
    await tester.pumpAndSettle();
    await library.remove(book.id);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('bookRawExport')), 200);
    await tester.ensureVisible(find.byKey(const ValueKey('bookRawExport')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bookRawExport')));
    await tester.pumpAndSettle();
    expect(called, false);
    expect(find.text('Livre introuvable.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });


  testWidgets('Conversation IA export includes RAW and exact captured phases',
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
    final book = await library.create('Skogheim');
    final session = await library.newSession(book);
    final ai = AiConnectionController(
      store: _Profiles(const AiProfilesState(
        profiles: [_profile], selectedId: 'profile-1',
      )), provider: _NoNetwork(),
    );
    addTearDown(ai.dispose);
    final chat = NarrativeChatController(
      provider: _NoNetwork(), configuration: () => null,
    );
    addTearDown(chat.dispose);
    chat.restoreTimeline(const [
      ChatEntry(id: 5, speaker: ChatSpeaker.player,
        name: 'Vous', text: 'Où suis-je ?'),
    ], rawGenerations: const [
      RawGeneration(playerEventId: 5, rawText: 'Astrid répond...'),
    ]);

    final recorder = AiExchangeRecorder();
    final exchange = recorder.begin(
      provider: 'openai-compatible', method: 'POST',
      url: 'https://example.invalid/v1/chat/completions',
      requestBody: '{"model":"test","messages":[]}',
      secret: 'secret-token', accept: 'application/json',
    );
    exchange.stage = 'jsonifier';
    exchange.playerEventId = 5;
    exchange.complete(error: 'JSONification invalide');
    await library.saveDiagnostic(StoredAiDiagnostic(
      id: 'diag-1', sessionId: session.id,
      createdAtUtc: DateTime.utc(2026, 11, 15),
      content: exchange.exportJson(),
    ), 10);

    var loads = 0;
    String? exportedName;
    String? exportedText;
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: ConversationSettingsPage(
        library: library, ai: ai, chat: chat,
        bookId: book.id, sessionId: session.id,
        bookTitle: 'Skogheim', onBack: () {},
        onLoadAiDiagnostics: () async {
          loads++;
          return library.diagnostics(session.id);
        },
        onExportAiTrace: (name, bytes) async {
          exportedName = name;
          exportedText = utf8.decode(bytes);
        },
      )),
    ));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('conversationExport')), 200);
    expect(find.byKey(const ValueKey('conversationExport')), findsOneWidget);
    expect(find.byKey(const ValueKey('bookRawExport')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(
      const ValueKey('aiPipelineExport')), 180);
    await tester.ensureVisible(find.byKey(
      const ValueKey('aiPipelineExport')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('aiPipelineExport')));
    await tester.pumpAndSettle();

    expect(loads, 1);
    expect(exportedName, 'domolia-diagnostic-ia.json');
    final exported = jsonDecode(exportedText!) as Map<String, dynamic>;
    expect(exported['format'], 'domolia-ai-pipeline-trace-v1');
    expect(exported['bookTitle'], 'Skogheim');
    final turn = (exported['turns'] as List).single;
    expect(turn['playerMessage'], 'Où suis-je ?');
    expect(turn['raw']['text'], 'Astrid répond...');
    expect(turn['raw']['status'], 'pending_jsonification');
    expect(turn['phases'][0]['stage'], 'jsonifier');
    expect(turn['phases'][0]['interpretation']['error'],
      'JSONification invalide');
    expect(exportedText!, isNot(contains('secret-token')));
    expect(tester.takeException(), isNull);
  });



  testWidgets('Each Party overrides formatter and optimizer independently',
      (tester) async {
    tester.view.physicalSize = const Size(340, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final library = BookLibraryController(store: _MemoryBooks());
    addTearDown(library.dispose);
    await library.initialize();
    final book = await library.create('Deux tâches');
    final session = await library.newSession(book);
    const formatter = AiProfile(
      id: 'fmt', name: 'JSONificateur léger',
      baseUrl: 'https://example.invalid', model: 'fast-model',
      apiKey: 'private-formatter-key',
    );
    final ai = AiConnectionController(
      store: _Profiles(const AiProfilesState(
        profiles: [_profile, formatter], selectedId: 'profile-1',
      )), provider: _NoNetwork(),
    );
    addTearDown(ai.dispose);
    final chat = NarrativeChatController(
      provider: _NoNetwork(), configuration: () => null,
    );
    addTearDown(chat.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: ConversationSettingsPage(
        library: library, ai: ai, chat: chat,
        bookId: book.id, sessionId: session.id, onBack: () {},
      )),
    ));
    await tester.pumpAndSettle();
    final formatterSelector = find.byKey(
      const ValueKey('conversationTask-jsonifier-'));
    await tester.scrollUntilVisible(formatterSelector, 210);
    await tester.tap(formatterSelector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('JSONificateur léger').last);
    await tester.pumpAndSettle();
    var stored = (await library.session(session.id))!;
    expect(stored.aiProfileId, isNull);
    expect(stored.formatterProfileId, 'fmt');
    expect(stored.optimizerProfileId, isNull);

    final optimizerSelector = find.byKey(
      const ValueKey('conversationTask-optimizer-'));
    await tester.scrollUntilVisible(optimizerSelector, 210);
    await tester.tap(optimizerSelector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Désactiver pour cette Partie').last);
    await tester.pumpAndSettle();
    stored = (await library.session(session.id))!;
    expect(stored.optimizerProfileId, '#disabled');
    expect(stored.formatterProfileId, 'fmt');
    expect(stored.aiProfileId, isNull);

    await tester.scrollUntilVisible(find.byKey(
      const ValueKey('conversationRecompileLore')), 180);
    await tester.tap(find.byKey(const ValueKey('conversationRecompileLore')));
    await tester.pumpAndSettle();
    expect(find.textContaining('prochain message'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  test('Per-Party task selections and compilation remain private to Book exports',
      () async {
    final library = BookLibraryController(store: _MemoryBooks());
    addTearDown(library.dispose);
    await library.initialize();
    final book = await library.create('Livre original');
    final session = await library.newSession(book);
    await library.setSessionTaskProfile(session.id, 'jsonifier', 'fmt');
    await library.setSessionTaskProfile(session.id, 'optimizer', '#disabled');
    await library.saveOptimizedLore(session.id,
      'hash-local', 'Cache de narration privé');
    final stored = (await library.session(session.id))!;
    expect(stored.formatterProfileId, 'fmt');
    expect(stored.optimizerProfileId, '#disabled');
    expect(stored.optimizedLore, 'Cache de narration privé');
    final exported = library.byId(book.id)!.exportJson();
    expect(exported, isNot(contains('Cache de narration privé')));
    expect(exported, isNot(contains('hash-local')));
    expect(exported, isNot(contains('#disabled')));
    expect(exported, isNot(contains('fmt')));
    expect(exported, isNot(contains(session.id)));
  });

  testWidgets('A Party overrides JSONifier token and reasoning independently',
      (tester) async {
    tester.view.physicalSize = const Size(360, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final library = BookLibraryController(store: _MemoryBooks());
    addTearDown(library.dispose);
    await library.initialize();
    final book = await library.create('Lune du Nord');
    final session = await library.newSession(book);
    final ai = AiConnectionController(
      store: _Profiles(const AiProfilesState(
        profiles: [_profile], selectedId: 'profile-1',
      )), provider: _NoNetwork(),
    );
    addTearDown(ai.dispose);
    final chat = NarrativeChatController(
      provider: _NoNetwork(), configuration: () => null,
    );
    addTearDown(chat.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: ConversationSettingsPage(
        library: library, ai: ai, chat: chat, bookId: book.id,
        sessionId: session.id, onBack: () {},
      )),
    ));
    await tester.pumpAndSettle();

    final token = find.byKey(
        const ValueKey('conversationTokens-jsonifier-0'));
    await tester.scrollUntilVisible(token, 230);
    await tester.ensureVisible(token);
    await tester.pumpAndSettle();
    await tester.tap(token);
    await tester.pumpAndSettle();
    await tester.tap(find.text('8192 tokens').last);
    await tester.pumpAndSettle();
    var stored = (await library.session(session.id))!;
    expect(stored.generationOverrides[AiNarrativeTask.jsonifier]!
        .maxOutputTokens, 8192);
    expect(stored.generationOverrides[AiNarrativeTask.narrator], isNull);

    final reasoning = find.byKey(
      const ValueKey('conversationReasoning-jsonifier-'));
    await tester.scrollUntilVisible(reasoning, 200);
    await tester.ensureVisible(reasoning);
    await tester.pumpAndSettle();
    await tester.tap(reasoning);
    await tester.pumpAndSettle();
    await tester.tap(find.text('NONE').last);
    await tester.pumpAndSettle();
    stored = (await library.session(session.id))!;
    expect(stored.generationOverrides[AiNarrativeTask.jsonifier]!
        .reasoningEffort, 'none');
    expect(stored.generationOverrides[AiNarrativeTask.narrator], isNull);
    expect(tester.takeException(), isNull);
  });

  test('Character status survives session JSON without changing old entries', () {
    const session = BookSession(
      id: 'status-test', bookId: 'book', title: 'Partie',
      timeline: [
        ChatEntry(id: 1, speaker: ChatSpeaker.character,
            name: 'Liv', text: 'Quoi ?!', status: 'étonnée'),
        ChatEntry(id: 2, speaker: ChatSpeaker.player,
            name: 'Vous', text: 'Je réponds'),
      ],
    );
    final loaded = BookSession.decodeTimeline(session.encodeTimeline());
    expect((loaded.first as ChatEntry).status, 'étonnée');
    expect((loaded.last as ChatEntry).status, isNull);
    expect((jsonDecode(session.encodeTimeline()) as List).first['status'],
        'étonnée');
    final legacy = BookSession.decodeTimeline(
      '[{"id":0,"type":"message","speaker":"character",'
      '"name":"Liv","text":"Bonjour"}]',
    );
    expect((legacy.single as ChatEntry).status, isNull);
  });

  test('Reply pacing is independent of descriptive density and character control', () {
    for (var length = 1; length <= 5; length++) {
      final book = BookDefinition(
        id: 'pacing-$length', title: 'Rythme $length',
        responseLength: length, detailLevel: 5,
        styleKeywords: const ['Dialogué', 'Mystérieux'],
      );
      final prompt = book.narrator.systemPrompt;
      expect(prompt, contains(BookDefinition.responseLengthInstructions[length - 1]));
      expect(prompt, contains('Mots-clés du style d’écriture'));
      expect(prompt, contains('Dialogué, Mystérieux'));
      expect(prompt, contains(BookDefinition.detailInstructions[4]));
      expect(prompt, contains('personnage joueur'));
      expect(prompt, isNot(contains('"type":"scene_change"')));
    }
    expect(const BookDefinition(id: 'default', title: 'Livre').responseLength, 3);
    expect(BookDefinition.responseLengthInstruction(3), contains('120 à 185 mots'));
  });

  test('Book v3 persists pacing and keywords; old v1/v2 books use defaults', () {
    const original = BookDefinition(
      id: 'pacing-book', title: 'Pacing',
      narrativeStyle: 'Un style personnalisé',
      responseLength: 2,
      detailLevel: 4,
      styleKeywords: ['Direct', 'Intimiste'],
    );
    final encoded = original.exportJson();
    final restored = BookDefinition.importJson(encoded);
    expect(restored.responseLength, 2);
    expect(restored.styleKeywords, ['Direct', 'Intimiste']);
    expect(restored.detailLevel, 4);
    expect(restored.narrativeStyle, original.narrativeStyle);
    expect((jsonDecode(encoded) as Map)['version'], 3);

    final legacyV2 = jsonDecode(encoded) as Map<String, dynamic>;
    legacyV2['version'] = 2;
    (legacyV2['narrative'] as Map<String, dynamic>)
      ..remove('responseLength')
      ..remove('styleKeywords');
    final migratedV2 = BookDefinition.importJson(jsonEncode(legacyV2));
    expect(migratedV2.responseLength, 3);
    expect(migratedV2.styleKeywords, isEmpty);
    expect(migratedV2.narrativeStyle, original.narrativeStyle);

    legacyV2['version'] = 1;
    legacyV2.remove('lore');
    final migratedV1 = BookDefinition.importJson(jsonEncode(legacyV2));
    expect(migratedV1.responseLength, 3);
    expect(migratedV1.styleKeywords, isEmpty);
  });

  test('Invalid pacing, duplicated keywords and unknown schema are rejected', () {
    final book = const BookDefinition(id: 'validation', title: 'Test');
    expect(() => book.copyWith(responseLength: 0).validate(),
      throwsFormatException);
    expect(() => book.copyWith(responseLength: 6).validate(),
      throwsFormatException);
    expect(() => book.copyWith(styleKeywords: ['direct', 'Direct']).validate(),
      throwsFormatException);
    expect(() => book.copyWith(
        styleKeywords: List.filled(11, 'mot-clé')).validate(),
      throwsFormatException);
    expect(() => book.copyWith(
        styleKeywords: ['mot-clé trop long ' * 3]).validate(),
      throwsFormatException);
    final bad = jsonDecode(book.exportJson()) as Map<String, dynamic>;
    (bad['narrative'] as Map<String, dynamic>)['responseLength'] = '3';
    expect(() => BookDefinition.importJson(jsonEncode(bad)),
      throwsFormatException);
  });

  testWidgets('Book narrator editor updates length and selected style tags',
      (tester) async {
    tester.view.physicalSize = const Size(360, 930);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final library = BookLibraryController(store: _MemoryBooks());
    addTearDown(library.dispose);
    await library.initialize();
    final book = await library.create('Narration test');
    final ai = AiConnectionController(
      store: _Profiles(const AiProfilesState(
        profiles: [_profile], selectedId: 'profile-1',
      )), provider: _NoNetwork(),
    );
    addTearDown(ai.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: BookEditorPage(book: book, library: library, ai: ai,
        onPlay: (_, _) async {}),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Narrateur'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bookResponseLengthSlider')),
      findsOneWidget);
    expect(find.byKey(const ValueKey('bookDetailSlider')), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('bookStyleKeyword-Dialogué')));
    await tester.tap(find.byKey(const ValueKey('bookStyleKeyword-Dialogué')));
    await tester.pumpAndSettle();
    final slider = find.byKey(const ValueKey('bookResponseLengthSlider'));
    await tester.ensureVisible(slider);
    await tester.drag(slider, const Offset(-110, 0));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    final stored = library.byId(book.id)!;
    expect(stored.styleKeywords, contains('Dialogué'));
    expect(stored.responseLength, lessThan(3));
    expect(stored.detailLevel, 3);
    expect(tester.takeException(), isNull);
  });

}
