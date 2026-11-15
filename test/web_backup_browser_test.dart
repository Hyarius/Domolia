import 'dart:convert';
import 'dart:typed_data';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/backup/backup_service.dart';
import 'package:domolia/backup/portable_backup.dart';
import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/platform/production_services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';

class _BrowserProfiles implements AiProfileStore {
  _BrowserProfiles(this.state);
  AiProfilesState state;

  @override
  Future<AiProfilesState?> read() async => state;

  @override
  Future<void> write(AiProfilesState next) async => state = next;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Web IndexedDB backup restore survives SQLite reopen; excludes secrets',
      () async {
    final id = 'web-backup-test';
    final store = createProductionBookStore() as SqliteBookStore;
    await store.deleteBook(id);
    final profiles = _BrowserProfiles(const AiProfilesState(
      selectedId: 'local',
      profiles: [
        AiProfile(
          id: 'local', name: 'Mes identifiants',
          baseUrl: 'https://example.org/v1', model: 'local-model',
          apiKey: 'VERY-PRIVATE-KEY',
        ),
      ],
    ));
    final backup = PortableBackup(
      createdAtUtc: DateTime.utc(2026, 11, 15),
      books: const [BookDefinition(
        id: 'web-backup-test', title: 'Livre portable',
        coverMime: 'image/webp',
        coverBase64: 'UklGRh4AAABXRUJQVlA4TBEAAAAvAAAAAAdQrXrUqP+BiOh/AAA=',
      )],
      sessions: [
        BackupSession(
          session: const BookSession(
            id: 'web-backup-test-part',
            bookId: 'web-backup-test',
            title: 'Partie Web',
            timeline: [
              ChatEntry(
                id: 0, speaker: ChatSpeaker.player,
                name: 'Vous', text: 'Bonjour',
              ),
              ChatSceneChange(id: 1),
            ],
          ),
          updatedAtMicros: DateTime.utc(2026, 11, 15).microsecondsSinceEpoch,
        ),
      ],
      bookBindings: const [BackupBinding('web-backup-test', 'remote')],
      aiProfiles: const [
        BackupProfile(
          id: 'remote', name: 'Profil importé',
          kind: AiProviderKind.customAi,
          baseUrl: 'https://example.org/v1', model: 'remote-model',
          nsfwCompatibility: AiNsfwCompatibility.unknown,
        ),
      ],
    );
    final bytes = backup.encode();
    expect(utf8.decode(bytes), isNot(contains('VERY-PRIVATE-KEY')));

    final svc = BackupService(books: store, profileStore: profiles);
    await svc.restore(PortableBackup.decode(Uint8List.fromList(bytes)),
        BackupRestoreMode.merge);
    await store.close();

    final reopened = createProductionBookStore() as SqliteBookStore;
    addTearDown(reopened.close);
    final book = await reopened.findBook(id);
    expect(book, isNotNull);
    expect(book!.coverBase64, backup.books.single.coverBase64);
    final part = await reopened.findSession('web-backup-test-part');
    expect(part, isNotNull);
    expect(part!.timeline.last, isA<ChatSceneChange>());
    expect(await reopened.profileIdForBook(id), startsWith('imported-'));
    expect(profiles.state.profiles.first.apiKey, 'VERY-PRIVATE-KEY');
    expect(profiles.state.profiles.last.apiKey, isEmpty);

    // Test the actual Web SQLite capture path, not just the pure codec.
    final roundtrip = await BackupService(
      books: reopened, profileStore: profiles,
    ).capture();
    expect(roundtrip.books.map((b) => b.id), contains(id));
    expect(roundtrip.sessions.map((s) => s.session.id),
        contains('web-backup-test-part'));
    expect(utf8.decode(roundtrip.encode()), isNot(contains('VERY-PRIVATE-KEY')));
    await reopened.deleteBook(id);
  }, skip: !kIsWeb);
}
