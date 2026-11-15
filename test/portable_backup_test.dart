import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:path/path.dart' as path;
import 'package:domolia/backup/backup_service.dart';
import 'package:domolia/backup/portable_backup.dart';
import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _MemoryProfiles implements AiProfileStore {
  _MemoryProfiles(this.state);
  AiProfilesState? state;

  @override
  Future<AiProfilesState?> read() async => state;

  @override
  Future<void> write(AiProfilesState updated) async => state = updated;
}

void main() {
  sqfliteFfiInit();
  const cover = 'UklGRh4AAABXRUJQVlA4TBEAAAAvAAAAAAdQrXrUqP+BiOh/AAA=';
  const sensitive = 'DONT-EXPORT-THIS-SECRET';
  const local = AiProfilesState(
    selectedId: 'profile',
    profiles: [
      AiProfile(
        id: 'profile', name: 'Fournisseur privé',
        baseUrl: 'https://example.test/v1',
        model: 'model-test', apiKey: sensitive,
      ),
    ],
  );

  PortableBackup archive({
    String title = 'Livre importé',
    String sessionText = 'Une scène nouvelle',
  }) => PortableBackup(
    createdAtUtc: DateTime.utc(2026, 11, 15),
    books: [
      BookDefinition(
        id: 'book1', title: title,
        coverMime: 'image/webp', coverBase64: cover,
      ),
    ],
    sessions: [
      BackupSession(
        session: BookSession(
          id: 'session1', bookId: 'book1', title: 'Partie 1',
          timeline: [
            const ChatEntry(
              id: 0, speaker: ChatSpeaker.player,
              name: 'Moi', text: 'Bonjour',
            ),
            const ChatSceneChange(id: 1),
            ChatEntry(id: 2, speaker: ChatSpeaker.narrator,
              name: 'Narrateur', text: sessionText),
          ],
        ),
        updatedAtMicros: DateTime.utc(2026, 11, 15).microsecondsSinceEpoch,
      ),
    ],
    aiProfiles: [BackupProfile.fromAi(local.profiles.single)],
    bookBindings: [const BackupBinding('book1', 'profile')],
  );

  test('codec roundtrip portable keeps full timeline, cover, without tokens', () {
    final bytes = archive().encode();
    final json = utf8.decode(bytes);
    expect(json, contains('Une scène nouvelle'));
    expect(json, contains(cover));
    expect(json, isNot(contains(sensitive)));
    expect(json, isNot(contains('apiKey')));
    expect(json, isNot(contains('refreshToken')));
    expect(json, isNot(contains('diagnostic')));
    final loaded = PortableBackup.decode(bytes);
    expect(loaded.books.single.coverBase64, cover);
    expect(loaded.bookBindings.single.aiProfileId, 'profile');
    expect(loaded.aiProfiles.single.name, 'Fournisseur privé');
    expect(loaded.sessions.single.session.timeline[1], isA<ChatSceneChange>());
    expect(loaded.sessions.single.updatedAtMicros,
        DateTime.utc(2026, 11, 15).microsecondsSinceEpoch);
    expect(loaded.encode(), bytes);
  });

  test('rejects malformed, truncated, orphan and hostile metadata before writes', () {
    final source = jsonDecode(utf8.decode(archive().encode()))
        as Map<String, dynamic>;
    Uint8List corrupt(Map<String, dynamic> json) =>
        Uint8List.fromList(utf8.encode(jsonEncode(json)));

    expect(() => PortableBackup.decode(Uint8List.fromList([123, 34])),
        throwsFormatException);
    final invalid = jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
    (invalid['aiProfiles'] as List).first['apiKey'] = sensitive;
    expect(() => PortableBackup.decode(corrupt(invalid)), throwsFormatException);

    final orphan = jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
    (orphan['sessions'] as List).first['bookId'] = 'not-present';
    expect(() => PortableBackup.decode(corrupt(orphan)), throwsFormatException);

    final dupe = jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
    (dupe['books'] as List).add((dupe['books'] as List).first);
    expect(() => PortableBackup.decode(corrupt(dupe)), throwsFormatException);

    final preferences = jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
    preferences['preferences'] = {'apiKey': sensitive};
    expect(() => PortableBackup.decode(corrupt(preferences)),
        throwsFormatException);

    final tokenInUrl = jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
    (tokenInUrl['aiProfiles'] as List).first['baseUrl'] =
        'https://example.org/v1?token=SECRET';
    expect(() => PortableBackup.decode(corrupt(tokenInUrl)),
        throwsFormatException);

    final unknownEvent = jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
    (unknownEvent['sessions'] as List).first['timeline'][0]['refreshToken'] =
        sensitive;
    expect(() => PortableBackup.decode(corrupt(unknownEvent)),
        throwsFormatException);
  });

  test('export and restore cross-device; import idempotent and secret-free',
      () async {
    final dir = await Directory.systemTemp.createTemp('domolia-backup-');
    addTearDown(() => dir.delete(recursive: true));
    final oldStore = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: '${dir.path}/old.db',
    );
    final newStore = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: '${dir.path}/new.db',
    );
    addTearDown(oldStore.close);
    addTearDown(newStore.close);
    await oldStore.putBook(archive().books.single);
    await oldStore.bindProfile('book1', 'profile');
    await oldStore.putSession(archive().sessions.single.session);
    final saved = await BackupService(
      books: oldStore, profileStore: _MemoryProfiles(local),
    ).capture();
    final portable = PortableBackup.decode(saved.encode());
    final importedProfiles = _MemoryProfiles(local);
    final restored = BackupService(
      books: newStore, profileStore: importedProfiles,
    );
    await restored.restore(portable, BackupRestoreMode.merge);
    expect(await newStore.listBooks(), hasLength(1));
    expect(await newStore.listSessions('book1'), hasLength(1));
    expect((await newStore.listSessions('book1')).single.timeline[1],
        isA<ChatSceneChange>());
    final linkedId = await newStore.profileIdForBook('book1');
    expect(linkedId, startsWith('imported-'));
    expect(importedProfiles.state!.profiles.first.apiKey, sensitive);
    expect(importedProfiles.state!.profiles.last.apiKey, isEmpty);
    expect(importedProfiles.state!.profiles.last.id, linkedId);
    await restored.restore(portable, BackupRestoreMode.merge);
    expect(await newStore.listBooks(), hasLength(1));
    expect(await newStore.listSessions('book1'), hasLength(1));
    expect(importedProfiles.state!.profiles, hasLength(2));
  });

  test('merge keeps conflicting local book and part, and stays idempotent',
      () async {
    final dir = await Directory.systemTemp.createTemp('domolia-merge-');
    addTearDown(() => dir.delete(recursive: true));
    final store = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: '${dir.path}/merged.db',
    );
    addTearDown(store.close);
    await store.putBook(const BookDefinition(
      id: 'book1', title: 'Livre local différent',
    ));
    await store.putSession(const BookSession(
      id: 'session1', bookId: 'book1', title: 'Partie locale',
    ));
    final svc = BackupService(books: store, profileStore: _MemoryProfiles(local));
    expect((await svc.preview(archive(), BackupRestoreMode.merge)).bookConflicts, 1);
    await svc.restore(archive(), BackupRestoreMode.merge);
    expect(await store.listBooks(), hasLength(2));
    final imported = (await store.listBooks())
        .singleWhere((b) => b.title == 'Livre importé');
    expect(imported.id, isNot('book1'));
    final sessions = await store.listSessions(imported.id);
    expect(sessions, hasLength(1));
    expect(sessions.single.id, isNot('session1'));
    await svc.restore(archive(), BackupRestoreMode.merge);
    expect(await store.listBooks(), hasLength(2));
    expect(await store.listSessions(imported.id), hasLength(1));
    expect((await store.findBook('book1'))!.title, 'Livre local différent');
  });

  test('replace removes previous books and restores archive in one transaction',
      () async {
    final dir = await Directory.systemTemp.createTemp('domolia-replace-');
    addTearDown(() => dir.delete(recursive: true));
    final store = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: '${dir.path}/replace.db',
    );
    addTearDown(store.close);
    await store.putBook(const BookDefinition(
      id: 'old', title: 'Ancien',
    ));
    final profiles = _MemoryProfiles(local);
    await BackupService(books: store, profileStore: profiles)
        .restore(archive(), BackupRestoreMode.replace);
    expect(await store.findBook('old'), isNull);
    expect((await store.listBooks()).single.id, 'book1');
    expect(await store.findSession('session1'), isNotNull);
    expect(profiles.state!.profiles.first.apiKey, sensitive);
  });

  test('failed SQL restore rolls back books and compensates AI metadata',
      () async {
    final dir = await Directory.systemTemp.createTemp('domolia-rollback-');
    addTearDown(() => dir.delete(recursive: true));
    final store = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: '${dir.path}/rollback.db',
    );
    addTearDown(store.close);
    await store.putBook(const BookDefinition(
      id: 'old', title: 'Ancien',
    ));
    final db = await store.database;
    await db.execute('CREATE TRIGGER reject_session BEFORE INSERT ON sessions '
        'BEGIN SELECT RAISE(FAIL, "simulated disk failure"); END');
    final profiles = _MemoryProfiles(local);
    await expectLater(
      BackupService(books: store, profileStore: profiles)
          .restore(archive(), BackupRestoreMode.replace),
      throwsA(anything),
    );
    expect((await store.listBooks()).single.id, 'old');
    expect(await store.findBook('book1'), isNull);
    expect(profiles.state!.profiles, hasLength(1));
    expect(profiles.state!.profiles.single.apiKey, sensitive);
  });

  test('snapshot includes exact fields of three books, three cover types, '
      'several conversations, profile metadata, dates; excludes diagnostics',
      () async {
    final directory = await Directory.systemTemp.createTemp('domolia-full-');
    final original = SqliteBookStore(
      factory: databaseFactoryFfi,
      databasePath: path.join(directory.path, 'source.db'),
    );
    final target = SqliteBookStore(
      factory: databaseFactoryFfi,
      databasePath: path.join(directory.path, 'target.db'),
    );
    addTearDown(() async {
      await original.close();
      await target.close();
      await directory.delete(recursive: true);
    });
    const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVQIHWP4z8DwHwAFgAI/ScL/nwAAAABJRU5ErkJggg==';
    final jpeg = base64Encode([0xff, 0xd8, 0xff, 0xe0, 0, 1, 2, 3]);
    final definitions = [
      const BookDefinition(
        id: 'book-a', title: 'Épopée de l’Aube',
        coverMime: 'image/webp', coverBase64: cover,
        tags: {'nsfw'}, narrativeStyle: 'Récit : forêt, épée, été.',
        detailLevel: 5,
        openingMessages: ['Bienvenue, héroïne.', 'Que choisis-tu ?'],
      ),
      const BookDefinition(
        id: 'book-b', title: 'Couverture PNG',
        coverMime: 'image/png', coverBase64: png,
        narrativeStyle: 'Clair et précis', detailLevel: 1,
      ),
      BookDefinition(
        id: 'book-c', title: 'Couverture JPEG',
        coverMime: 'image/jpeg', coverBase64: jpeg,
        narrativeStyle: 'Dramatique', detailLevel: 2,
      ),
    ];
    for (final book in definitions) {
      await original.putBook(book);
    }
    await original.bindProfile('book-a', 'profile');
    await original.bindProfile('book-b', 'profile-2');
    await original.bindProfile('book-c', null);
    const first = BookSession(
      id: 'part-a1', bookId: 'book-a', title: 'Chapitre I',
      timeline: [
        ChatEntry(id: 0, speaker: ChatSpeaker.player,
          name: 'Joueur', text: 'Bonjour'),
        ChatEntry(id: 1, speaker: ChatSpeaker.character,
          name: 'Ariane', text: 'Texte avec accents et émojis ✨'),
        ChatSceneChange(id: 2),
        ChatEntry(id: 3, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'La nuit approche.'),
      ],
    );
    const second = BookSession(
      id: 'part-a2', bookId: 'book-a', title: 'Chapitre II',
      timeline: [ChatSceneChange(id: 0)],
    );
    const third = BookSession(
      id: 'part-b', bookId: 'book-b', title: 'Autre histoire',
    );
    for (final part in [first, second, third]) {
      await original.putSession(part);
    }
    final timestamp = DateTime.utc(2023, 4, 5, 6, 7, 8, 9, 321)
        .microsecondsSinceEpoch;
    await (await original.database).update(
      'sessions', {'updated_at': timestamp},
      where: 'id = ?', whereArgs: ['part-a1'],
    );
    await original.putDiagnostic(StoredAiDiagnostic(
      id: 'raw-exchange', sessionId: 'part-a1',
      createdAtUtc: DateTime.utc(2026, 1, 1),
      content: 'PRIVATE_HTTP_DIAGNOSTIC_DO_NOT_EXPORT',
    ), 10);
    final profiles = _MemoryProfiles(AiProfilesState(
      selectedId: 'profile',
      profiles: [
        local.profiles.single,
        const AiProfile(
          id: 'profile-2', name: 'Autre IA',
          kind: AiProviderKind.chatGpt,
          baseUrl: 'https://example.org/v1',
          model: 'chat-model', apiKey: 'SECOND-SECRET-TOKEN',
          nsfwCompatibility: AiNsfwCompatibility.unsupported,
        ),
      ],
    ));
    final snapshot = await BackupService(
      books: original, profileStore: profiles,
    ).capture();
    expect(snapshot.books, hasLength(3));
    expect(snapshot.sessions, hasLength(3));
    expect(snapshot.bookBindings, hasLength(3));
    expect(snapshot.aiProfiles, hasLength(2));
    final bytes = snapshot.encode();
    final raw = utf8.decode(bytes);
    expect(raw, isNot(contains('PRIVATE_HTTP_DIAGNOSTIC_DO_NOT_EXPORT')));
    expect(raw, isNot(contains('SECOND-SECRET-TOKEN')));
    expect(raw, isNot(contains(sensitive)));
    expect(raw, isNot(contains('apiKey')));
    final decoded = PortableBackup.decode(bytes);
    final booksById = {for (final b in decoded.books) b.id: b};
    for (final book in definitions) {
      expect(booksById[book.id]!.toPortableJson(), book.toPortableJson());
    }
    final partsById = {
      for (final record in decoded.sessions) record.session.id: record,
    };
    for (final part in [first, second, third]) {
      expect(partsById[part.id]!.session.encodeTimeline(), part.encodeTimeline());
    }
    expect(partsById['part-a1']!.updatedAtMicros, timestamp);
    final names = {for (final p in decoded.aiProfiles) p.id: p};
    expect(names['profile-2']!.name, 'Autre IA');
    expect(names['profile-2']!.kind, AiProviderKind.chatGpt);
    expect(names['profile-2']!.nsfwCompatibility,
        AiNsfwCompatibility.unsupported);
    final bindings = {
      for (final binding in decoded.bookBindings)
        binding.bookId: binding.aiProfileId,
    };
    expect(bindings, {
      'book-a': 'profile', 'book-b': 'profile-2', 'book-c': null,
    });

    final importedProfiles = _MemoryProfiles(local);
    final service = BackupService(
      books: target, profileStore: importedProfiles,
    );
    await service.restore(decoded, BackupRestoreMode.merge);
    expect(await target.listBooks(), hasLength(3));
    for (final book in definitions) {
      expect((await target.findBook(book.id))!.toPortableJson(),
          book.toPortableJson());
    }
    for (final part in [first, second, third]) {
      expect((await target.findSession(part.id))!.encodeTimeline(),
          part.encodeTimeline());
    }
    expect(await target.profileIdForBook('book-a'), startsWith('imported-'));
    expect(await target.profileIdForBook('book-b'), startsWith('imported-'));
    expect(await target.profileIdForBook('book-c'), isNull);
    expect(await target.listDiagnostics('part-a1'), isEmpty);
    expect((await service.capture()).sessions.singleWhere(
        (record) => record.session.id == 'part-a1').updatedAtMicros,
        timestamp);
  });

  test('deleted AI profile leaves a portable, credential-free placeholder',
      () async {
    final directory = await Directory.systemTemp.createTemp('domolia-orphan-');
    final store = SqliteBookStore(
      factory: databaseFactoryFfi,
      databasePath: path.join(directory.path, 'orphan.db'),
    );
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });
    await store.putBook(const BookDefinition(
      id: 'bound-book', title: 'Livre avec profil IA supprimé',
    ));
    await store.bindProfile('bound-book', 'deleted-profile');
    final snapshot = await BackupService(
      books: store, profileStore: _MemoryProfiles(local),
    ).capture();
    expect(snapshot.aiProfiles, hasLength(2));
    final missing = snapshot.aiProfiles.singleWhere(
        (p) => p.id == 'deleted-profile');
    expect(missing.requiresReconfiguration, true);
    expect(missing.toAi(importedId: 'imported-profile').apiKey, isEmpty);
    final roundtrip = PortableBackup.decode(snapshot.encode());
    expect(roundtrip.bookBindings.single.aiProfileId, 'deleted-profile');
    expect(roundtrip.aiProfiles.last.requiresReconfiguration, true);
  });

  test('field order and pretty printing do not create duplicate books',
      () async {
    final directory = await Directory.systemTemp.createTemp('domolia-json-');
    final store = SqliteBookStore(
      factory: databaseFactoryFfi,
      databasePath: path.join(directory.path, 'json.db'),
    );
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });
    final incoming = archive();
    await store.putBook(incoming.books.single);
    final raw = jsonDecode(incoming.books.single.exportJson())
        as Map<String, dynamic>;
    final reordered = Map<String, dynamic>.fromEntries(
      raw.entries.toList().reversed,
    );
    await (await store.database).update(
      'books', {'definition_json': jsonEncode(reordered)},
      where: 'id = ?', whereArgs: ['book1'],
    );
    final service = BackupService(
      books: store, profileStore: _MemoryProfiles(local),
    );
    final preview = await service.preview(incoming, BackupRestoreMode.merge);
    expect(preview.bookConflicts, 0);
    await service.restore(incoming, BackupRestoreMode.merge);
    expect(await store.listBooks(), hasLength(1));
    await service.restore(incoming, BackupRestoreMode.merge);
    expect(await store.listBooks(), hasLength(1));
    expect((await store.findBook('book1'))!.title, 'Livre importé');
  });

  test('v3 profile_id of a conversation is restored and can be re-exported',
      () async {
    final directory = await Directory.systemTemp.createTemp('domolia-v3-');
    final store = SqliteBookStore(
      factory: databaseFactoryFfi,
      databasePath: path.join(directory.path, 'v3.db'),
    );
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });
    // Simulate the additional field from PR07 without merging that branch.
    final db = await store.database;
    await db.execute('ALTER TABLE sessions ADD COLUMN profile_id TEXT');
    final standard = archive();
    final withProfile = PortableBackup(
      createdAtUtc: standard.createdAtUtc,
      books: standard.books,
      bookBindings: standard.bookBindings,
      aiProfiles: standard.aiProfiles,
      sessions: [
        BackupSession(
          session: standard.sessions.single.session,
          updatedAtMicros: standard.sessions.single.updatedAtMicros,
          aiProfileId: 'profile',
        ),
      ],
    );
    final service = BackupService(
      books: store, profileStore: _MemoryProfiles(local),
    );
    await service.restore(withProfile, BackupRestoreMode.merge);
    final exported = await service.capture();
    expect(exported.sessions.single.aiProfileId, startsWith('imported-'));
    expect(exported.aiProfiles.any(
        (profile) => profile.id == exported.sessions.single.aiProfileId), true);
    await service.restore(withProfile, BackupRestoreMode.merge);
    expect(await store.listSessions('book1'), hasLength(1));
  });

  test('v2 schema rejects per-session profile without destroying existing data',
      () async {
    final directory = await Directory.systemTemp.createTemp('domolia-v2-');
    final store = SqliteBookStore(
      factory: databaseFactoryFfi,
      databasePath: path.join(directory.path, 'v2.db'),
    );
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });
    await store.putBook(const BookDefinition(
      id: 'safe-old', title: 'Livre à conserver',
    ));
    final standard = archive();
    final withProfile = PortableBackup(
      createdAtUtc: standard.createdAtUtc,
      books: standard.books,
      bookBindings: standard.bookBindings,
      aiProfiles: standard.aiProfiles,
      sessions: [
        BackupSession(
          session: standard.sessions.single.session,
          updatedAtMicros: standard.sessions.single.updatedAtMicros,
          aiProfileId: 'profile',
        ),
      ],
    );
    final profiles = _MemoryProfiles(local);
    await expectLater(
      BackupService(books: store, profileStore: profiles)
          .restore(withProfile, BackupRestoreMode.replace),
      throwsFormatException,
    );
    expect((await store.listBooks()).single.id, 'safe-old');
    expect(await store.findSession('session1'), isNull);
    expect(profiles.state!.profiles, hasLength(1));
    expect(profiles.state!.profiles.single.apiKey, sensitive);
  });
}
