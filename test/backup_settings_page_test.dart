import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:domolia/ai/ai_controller.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/backup/backup_service.dart';
import 'package:domolia/backup/backup_settings_page.dart';
import 'package:domolia/backup/portable_backup.dart';
import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_library_controller.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:material_ui/material_ui.dart';
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
  Future<List<AiModel>> listModels(AiConfiguration config) async => [];
  @override
  Future<String> complete(AiConfiguration config, {
    required List<AiMessage> messages,
    int maxTokens = 64,
  }) async => 'test';
}

class _Fixture {
  _Fixture(this.dir)
      : store = SqliteBookStore(
          factory: databaseFactoryFfi,
          databasePath: path.join(dir.path, 'ui.sqlite'),
        ),
        profiles = _Profiles(const AiProfilesState(
          selectedId: 'local', profiles: [
            AiProfile(
              id: 'local', name: 'Profil local',
              baseUrl: 'https://example.org/v1',
              model: 'local-model', apiKey: 'SECRET-LOCAL-KEY',
            ),
          ],
        ));
  final Directory dir;
  final SqliteBookStore store;
  final _Profiles profiles;
  late final books = BookLibraryController(store: store);
  late final ai = AiConnectionController(
    store: profiles, provider: _Provider(),
  );

  Future<void> init() async {
    await books.initialize();
    await ai.initialize();
  }

  Future<void> close() async {
    books.dispose();
    ai.dispose();
    await store.close();
    await dir.delete(recursive: true);
  }
}

PortableBackup _archive({String title = 'Livre portable'}) => PortableBackup(
  createdAtUtc: DateTime.utc(2026, 11, 15),
  books: [BookDefinition(id: 'imported', title: title)],
  sessions: [
    BackupSession(
      session: const BookSession(
        id: 'part-1', bookId: 'imported', title: 'Partie restaurée',
        timeline: [
          ChatEntry(id: 0, speaker: ChatSpeaker.player,
            name: 'Joueur', text: 'Bonjour'),
          ChatSceneChange(id: 1),
        ],
      ),
      updatedAtMicros: DateTime.utc(2025, 1, 1).microsecondsSinceEpoch,
    ),
  ],
  bookBindings: const [BackupBinding('imported', 'remote')],
  aiProfiles: const [
    BackupProfile(
      id: 'remote', name: 'Profil distant',
      kind: AiProviderKind.customAi,
      baseUrl: 'https://example.org/v1', model: 'model-a',
      nsfwCompatibility: AiNsfwCompatibility.unknown,
    ),
  ],
);

class _Service extends BackupService {
  _Service(_Fixture fixture, this.snapshot)
      : super(books: fixture.store, profileStore: fixture.profiles);
  PortableBackup snapshot;
  PortableBackup? lastImported;
  BackupRestoreMode? lastMode;
  int imports = 0;

  @override
  Future<PortableBackup> capture() async => snapshot;

  @override
  Future<({int bookConflicts, int sessionConflicts})> preview(
    PortableBackup backup, BackupRestoreMode mode,
  ) async => (bookConflicts: 1, sessionConflicts: 2);

  @override
  Future<void> restore(PortableBackup backup, BackupRestoreMode mode) async {
    lastImported = backup;
    lastMode = mode;
    imports++;
  }
}

Future<_Fixture> _fixture(WidgetTester tester) async {
  final fixture = _Fixture(
    await Directory.systemTemp.createTemp('domolia-backup-ui-'),
  );
  addTearDown(fixture.close);
  // FFI SQLite runs in a real isolate; initialize outside the fake-async zone
  // used to pump widget frames.
  await tester.runAsync(fixture.init);
  return fixture;
}

Widget _page(
  _Fixture f, _Service service, {
  Future<bool> Function(Uint8List, String)? save,
  Future<({String name, Uint8List bytes})?> Function()? pick,
  Future<void> Function()? beforeCapture,
  Future<void> Function()? beforeRestore,
  VoidCallback? afterRestore,
}) => MaterialApp(
  home: Scaffold(
    body: BackupSettingsPage(
      books: f.books,
      ai: f.ai,
      onBack: () {},
      backupService: service,
      reloadData: () async {},
      saveArchive: save,
      pickArchive: pick,
      onBeforeCapture: beforeCapture,
      onBeforeRestore: beforeRestore,
      onAfterRestore: afterRestore,
    ),
  ),
);

void main() {
  sqfliteFfiInit();

  testWidgets('save button writes full portable bytes after pending changes',
      (tester) async {
    final f = await _fixture(tester);
    final service = _Service(f, _archive(title: 'Avant'));
    Uint8List? fileBytes;
    String? fileName;
    var waited = false;
    await tester.pumpWidget(_page(
      f, service,
      beforeCapture: () async {
        service.snapshot = _archive(title: 'Dernier état');
        waited = true;
      },
      save: (bytes, name) async {
        fileBytes = bytes;
        fileName = name;
        return true;
      },
    ));
    await tester.tap(find.byKey(const ValueKey('backupSave')));
    await tester.pumpAndSettle();
    expect(waited, true);
    expect(fileName, endsWith('.domolia'));
    expect(fileBytes, isNotNull);
    final decoded = PortableBackup.decode(fileBytes!);
    expect(decoded.books.single.title, 'Dernier état');
    expect(decoded.sessions.single.session.timeline.last,
      isA<ChatSceneChange>());
    expect(decoded.bookBindings.single.aiProfileId, 'remote');
    expect(utf8.decode(fileBytes!), isNot(contains('SECRET-LOCAL-KEY')));
    expect(find.textContaining('Sauvegarde enregistrée'), findsOneWidget);
  });

  testWidgets('import preview displays counts and calls merge once',
      (tester) async {
    final f = await _fixture(tester);
    final service = _Service(f, _archive());
    var before = 0;
    var after = 0;
    await tester.pumpWidget(_page(
      f, service,
      pick: () async => (
        name: 'saved.domolia', bytes: _archive().encode(),
      ),
      beforeRestore: () async { before++; },
      afterRestore: () { after++; },
    ));
    await tester.tap(find.byKey(const ValueKey('backupLoad')));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 Livres'), findsOneWidget);
    expect(find.textContaining('1 conflit(s) de Livres'), findsOneWidget);
    await tester.tap(find.text('Fusionner'));
    await tester.pumpAndSettle();
    expect(before, 1);
    expect(after, 1);
    expect(service.imports, 1);
    expect(service.lastMode, BackupRestoreMode.merge);
    expect(service.lastImported!.sessions.single.session.id, 'part-1');
    expect(service.lastImported!.sessions.single.session.timeline.last,
      isA<ChatSceneChange>());
    expect(find.textContaining('Restauration terminée'), findsOneWidget);
  });

  testWidgets('malformed file is rejected before invoking the restore service',
      (tester) async {
    final f = await _fixture(tester);
    final service = _Service(f, _archive());
    await tester.pumpWidget(_page(
      f, service,
      pick: () async => (
        name: 'invalid.domolia',
        bytes: Uint8List.fromList(utf8.encode('{"format":')),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('backupLoad')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Fichier de sauvegarde invalide'),
      findsOneWidget);
    expect(service.imports, 0);
  });

  testWidgets('replace requires a second confirmation, cancellation is safe',
      (tester) async {
    final f = await _fixture(tester);
    final service = _Service(f, _archive());
    await tester.pumpWidget(_page(
      f, service,
      pick: () async => (
        name: 'valid.domolia', bytes: _archive().encode(),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('backupLoad')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remplacer'));
    await tester.pumpAndSettle();
    expect(find.text('Oui, remplacer'), findsOneWidget);
    expect(service.imports, 0);
    await tester.tap(find.text('Annuler').last);
    await tester.pumpAndSettle();
    expect(service.imports, 0);

    await tester.tap(find.byKey(const ValueKey('backupLoad')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remplacer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Oui, remplacer'));
    await tester.pumpAndSettle();
    expect(service.imports, 1);
    expect(service.lastMode, BackupRestoreMode.replace);
  });
}
