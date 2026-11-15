import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:domolia/ai/ai_provider.dart';
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
  });

  test('export and restore cross-device; import idempotent and secret-free',
      () async {
    final dir = await Directory.systemTemp.createTemp('domolia-backup-');
    addTearDown(() => dir.delete(recursive: true));
    final oldStore = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: dir.path + '/old.db',
    );
    final newStore = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: dir.path + '/new.db',
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
    expect(importedProfiles.state!.profiles.single.apiKey, sensitive);
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
      factory: databaseFactoryFfi, databasePath: dir.path + '/merged.db',
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
      factory: databaseFactoryFfi, databasePath: dir.path + '/replace.db',
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
      factory: databaseFactoryFfi, databasePath: dir.path + '/rollback.db',
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
}
