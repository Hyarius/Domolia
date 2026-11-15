import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:domolia/ai/ai_controller.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/backup/backup_settings_page.dart';
import 'package:domolia/backup/portable_backup.dart';
import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_library_controller.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Profiles implements AiProfileStore {
  _Profiles(this.state);
  AiProfilesState state;

  @override
  Future<AiProfilesState?> read() async => state;

  @override
  Future<void> write(AiProfilesState next) async => state = next;
}

class _Provider implements AiChatProvider {
  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async => [];

  @override
  Future<String> complete(
    AiConfiguration configuration, {
    required List<AiMessage> messages,
    int maxTokens = 64,
  }) async => 'test';
}

class _Fixture {
  _Fixture(this.directory)
      : store = SqliteBookStore(
          factory: databaseFactoryFfi,
          databasePath: path.join(directory.path, 'local.sqlite'),
        ),
        profiles = _Profiles(const AiProfilesState(
          selectedId: 'local',
          profiles: [
            AiProfile(
              id: 'local', name: 'Compte local',
              baseUrl: 'https://example.org/v1',
              model: 'local-model', apiKey: 'LOCAL-PRIVATE-TOKEN',
            ),
          ],
        ));

  final Directory directory;
  final SqliteBookStore store;
  final _Profiles profiles;
  late final BookLibraryController books =
      BookLibraryController(store: store);
  late final AiConnectionController ai = AiConnectionController(
    store: profiles, provider: _Provider(),
  );

  Future<void> initialize() async {
    await books.initialize();
    await ai.initialize();
  }

  Future<void> dispose() async {
    books.dispose();
    ai.dispose();
    await store.close();
    await directory.delete(recursive: true);
  }
}

PortableBackup _archive() => PortableBackup(
  createdAtUtc: DateTime.utc(2026, 11, 15),
  books: const [
    BookDefinition(id: 'import-book', title: 'Livre depuis Android'),
  ],
  sessions: [
    BackupSession(
      session: const BookSession(
        id: 'import-session', bookId: 'import-book', title: 'Partie portable',
        timeline: [
          ChatEntry(id: 0, speaker: ChatSpeaker.player,
            name: 'Vous', text: 'Salut !'),
          ChatSceneChange(id: 1),
        ],
      ),
      updatedAtMicros: DateTime.utc(2026, 1, 1).microsecondsSinceEpoch,
    ),
  ],
  bookBindings: const [BackupBinding('import-book', 'original-profile')],
  aiProfiles: const [
    BackupProfile(
      id: 'original-profile', name: 'Compte Android',
      baseUrl: 'https://example.org/v1', model: 'remote-model',
      kind: AiProviderKind.customAi,
      nsfwCompatibility: AiNsfwCompatibility.unknown,
    ),
  ],
);

Widget _page(
  _Fixture fixture, {
  Future<bool> Function(Uint8List, String)? save,
  Future<({String name, Uint8List bytes})?> Function()? pick,
  Future<void> Function()? beforeSave,
  Future<void> Function()? beforeRestore,
  VoidCallback? afterRestore,
}) => MaterialApp(
  home: Scaffold(
    body: BackupSettingsPage(
      books: fixture.books,
      ai: fixture.ai,
      onBack: () {},
      saveArchive: save,
      pickArchive: pick,
      onBeforeCapture: beforeSave,
      onBeforeRestore: beforeRestore,
      onAfterRestore: afterRestore,
    ),
  ),
);

void main() {
  sqfliteFfiInit();

  testWidgets('save button exports the exact latest SQLite data, no secrets',
      (tester) async {
    final fixture = _Fixture(
      await Directory.systemTemp.createTemp('domolia-page-save-'));
    addTearDown(fixture.dispose);
    await fixture.initialize();
    await fixture.store.putBook(const BookDefinition(
      id: 'saved-book', title: 'Le Livre conservé',
      tags: {'nsfw'}, detailLevel: 4,
    ));
    const before = BookSession(
      id: 'saved-session', bookId: 'saved-book', title: 'Partie',
    );
    const after = BookSession(
      id: 'saved-session', bookId: 'saved-book', title: 'Partie',
      timeline: [
        ChatEntry(id: 0, speaker: ChatSpeaker.player,
            name: 'Joueur', text: 'Dernier message'),
        ChatSceneChange(id: 1),
      ],
    );
    await fixture.store.putSession(before);
    Uint8List? saved;
    String? savedName;
    var pendingWriteFlushed = false;
    await tester.pumpWidget(_page(
      fixture,
      beforeSave: () async {
        await fixture.store.updateSession(after);
        pendingWriteFlushed = true;
      },
      save: (bytes, name) async {
        saved = bytes;
        savedName = name;
        return true;
      },
    ));
    await tester.tap(find.byKey(const ValueKey('backupSave')));
    await tester.pumpAndSettle();
    expect(pendingWriteFlushed, true);
    expect(saved, isNotNull);
    expect(savedName, endsWith('.domolia'));
    final data = PortableBackup.decode(saved!);
    expect(data.books.single.title, 'Le Livre conservé');
    expect(data.books.single.detailLevel, 4);
    expect(data.books.single.tags, {'nsfw'});
    expect(data.sessions.single.session.encodeTimeline(),
        after.encodeTimeline());
    expect(data.sessions.single.session.timeline.last,
        isA<ChatSceneChange>());
    expect(utf8.decode(saved!), isNot(contains('LOCAL-PRIVATE-TOKEN')));
    expect(find.textContaining('Sauvegarde enregistrée'), findsOneWidget);
  });

  testWidgets('load button shows preview and merges a real SQLite session',
      (tester) async {
    final fixture = _Fixture(
      await Directory.systemTemp.createTemp('domolia-page-load-'));
    addTearDown(fixture.dispose);
    await fixture.initialize();
    var preflight = 0;
    var postflight = 0;
    await tester.pumpWidget(_page(
      fixture,
      pick: () async =>
          (name: 'valid.domolia', bytes: _archive().encode()),
      beforeRestore: () async => preflight++,
      afterRestore: () => postflight++,
    ));
    await tester.tap(find.byKey(const ValueKey('backupLoad')));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 Livres'), findsOneWidget);
    expect(find.text('Fusionner'), findsOneWidget);
    await tester.tap(find.text('Fusionner'));
    await tester.pumpAndSettle();
    expect(preflight, 1);
    expect(postflight, 1);
    expect((await fixture.store.findBook('import-book'))!.title,
        'Livre depuis Android');
    expect((await fixture.store.findSession('import-session'))!
        .encodeTimeline(), _archive().sessions.single.session.encodeTimeline());
    expect(await fixture.store.profileIdForBook('import-book'),
        startsWith('imported-'));
    expect(fixture.profiles.state.profiles.first.apiKey,
        'LOCAL-PRIVATE-TOKEN');
    expect(fixture.profiles.state.profiles.last.apiKey, isEmpty);

    // Re-importing from the same UI must not duplicate books, parts or profiles.
    await tester.tap(find.byKey(const ValueKey('backupLoad')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fusionner'));
    await tester.pumpAndSettle();
    expect(await fixture.store.listBooks(), hasLength(1));
    expect(await fixture.store.listSessions('import-book'), hasLength(1));
    expect(fixture.profiles.state.profiles, hasLength(2));
  });

  testWidgets('malformed import cannot modify local books',
      (tester) async {
    final fixture = _Fixture(
      await Directory.systemTemp.createTemp('domolia-page-invalid-'));
    addTearDown(fixture.dispose);
    await fixture.initialize();
    await fixture.store.putBook(const BookDefinition(
      id: 'safe', title: 'Ne pas perdre',
    ));
    await tester.pumpWidget(_page(
      fixture,
      pick: () async => (
        name: 'broken.domolia',
        bytes: Uint8List.fromList(utf8.encode('{"broken":')),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('backupLoad')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Fichier de sauvegarde invalide'),
        findsOneWidget);
    expect((await fixture.store.listBooks()).single.id, 'safe');
    expect(fixture.profiles.state.profiles.single.apiKey,
        'LOCAL-PRIVATE-TOKEN');
  });

  testWidgets('replace requires two explicit confirmations',
      (tester) async {
    final fixture = _Fixture(
      await Directory.systemTemp.createTemp('domolia-page-replace-'));
    addTearDown(fixture.dispose);
    await fixture.initialize();
    await fixture.store.putBook(const BookDefinition(
      id: 'keep-until-confirmed', title: 'Bibliothèque actuelle',
    ));
    await tester.pumpWidget(_page(
      fixture,
      pick: () async => (
        name: 'archive.domolia', bytes: _archive().encode(),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('backupLoad')));
    await tester.pumpAndSettle();
    expect(await fixture.store.findBook('keep-until-confirmed'), isNotNull);
    await tester.tap(find.text('Remplacer'));
    await tester.pumpAndSettle();
    expect(find.text('Oui, remplacer'), findsOneWidget);
    expect(await fixture.store.findBook('keep-until-confirmed'), isNotNull);
    await tester.tap(find.text('Oui, remplacer'));
    await tester.pumpAndSettle();
    expect(await fixture.store.findBook('keep-until-confirmed'), isNull);
    expect(await fixture.store.findBook('import-book'), isNotNull);
  });
}
