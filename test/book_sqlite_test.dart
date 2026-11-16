import 'dart:io';
import 'dart:convert';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/ai_task_generation.dart';
import 'package:domolia/chat/chat_controller.dart';

import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/raw_generation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('SQLite preserves books, profile references and timelines across restart',
      () async {
    final directory = await Directory.systemTemp.createTemp('domolia-book-test-');
    final databasePath = '${directory.path}/books.sqlite';
    final first = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: databasePath,
    );
    addTearDown(() async {
      await first.close();
      await directory.delete(recursive: true);
    });
    const book = BookDefinition(id: 'book-test', title: 'Une histoire',
      narrativeStyle: 'Style A', detailLevel: 4);
    await first.putBook(book);
    await first.bindProfile(book.id, 'local-profile-id');
    final session = BookSession(
      id: 'session-test', bookId: book.id, title: 'Première partie',
      timeline: [
        ChatEntry(id: 0, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Le début'),
        ChatSceneChange(id: 1),
      ],
    );
    await first.putSession(session);
    await first.close();

    final second = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: databasePath,
    );
    addTearDown(second.close);
    expect((await second.listBooks()).single.narrativeStyle, 'Style A');
    expect(await second.profileIdForBook(book.id), 'local-profile-id');
    final restored = (await second.listSessions(book.id)).single;
    expect(restored.timeline, hasLength(2));
    expect(restored.timeline.last, isA<ChatSceneChange>());

    // Updating a book must not destroy child sessions or profile bindings.
    await second.putBook(book.copyWith(title: 'Titre changé'));
    expect(await second.profileIdForBook(book.id), 'local-profile-id');
    expect(await second.findSession(session.id), isNotNull);

    // Removing a single conversation must persist without deleting the book.
    await second.deleteSession(session.id);
    expect(await second.findSession(session.id), isNull);
    expect((await second.listSessions(book.id)), isEmpty);
    expect((await second.findBook(book.id))!.title, 'Titre changé');
    // A delayed timeline save is update-only and cannot recreate deletion.
    await second.updateSession(session.copyWith(title: 'Late write'));
    expect(await second.findSession(session.id), isNull);
    await second.putSession(session);

    await second.deleteBook(book.id);
    expect(await second.findSession(session.id), isNull);
    expect(await second.profileIdForBook(book.id), isNull);
  });

  test('AI traces are capped per conversation, purge one part and cascade on deletion',
      () async {
    final dir = await Directory.systemTemp.createTemp('domolia-diagnostics-');
    final file = '${dir.path}/diagnostics.sqlite';
    final db = SqliteBookStore(factory: databaseFactoryFfi, databasePath: file);
    addTearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });
    const book = BookDefinition(id: 'b', title: 'Test');
    await db.putBook(book);
    const s1 = BookSession(id: 's1', bookId: 'b', title: 'Une');
    const s2 = BookSession(id: 's2', bookId: 'b', title: 'Deux');
    await db.putSession(s1);
    await db.putSession(s2);
    StoredAiDiagnostic trace(String id, String sessionId, int n) =>
        StoredAiDiagnostic(
          id: id,
          sessionId: sessionId,
          createdAtUtc: DateTime.utc(2026, 1, 1).add(Duration(seconds: n)),
          content: '{"format":"test","request":{"body":{"model":"m"}},"response":{"statusCode":200}}',
        );

    await db.putDiagnostic(trace('first', 's1', 1), 2);
    await db.putDiagnostic(trace('second', 's1', 2), 2);
    await db.putDiagnostic(trace('third', 's1', 3), 2);
    await db.putDiagnostic(trace('other', 's2', 4), 2);
    expect((await db.listDiagnostics('s1')).map((d) => d.id),
        ['third', 'second']);
    expect((await db.listDiagnostics('s2')).single.id, 'other');

    // Editing the timeline must not cascade-delete retained diagnostics.
    await db.putSession(s1.copyWith(title: 'Une partie éditée'));
    expect(await db.listDiagnostics('s1'), hasLength(2));

    await db.clearDiagnostics('s1');
    expect(await db.listDiagnostics('s1'), isEmpty);
    expect((await db.findSession('s1'))!.title, 'Une partie éditée');
    expect((await db.listDiagnostics('s2')).single.id, 'other');

    await db.putDiagnostic(trace('new', 's1', 5), 1);
    await db.pruneDiagnostics(0);
    expect(await db.listDiagnostics('s1'), isEmpty);
    expect(await db.listDiagnostics('s2'), isEmpty);

    await db.putDiagnostic(trace('last', 's2', 6), 5);
    await db.deleteSession('s2');
    expect(await db.listDiagnostics('s2'), isEmpty);
  });

  test('Existing v1 book database migrates without losing conversations',
      () async {
    final dir = await Directory.systemTemp.createTemp('domolia-migration-');
    final file = '${dir.path}/legacy.sqlite';
    addTearDown(() async => dir.delete(recursive: true));
    final old = await databaseFactoryFfi.openDatabase(
      file,
      options: OpenDatabaseOptions(version: 1, onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE books (id TEXT PRIMARY KEY, definition_json TEXT NOT NULL)');
        await db.execute(
          'CREATE TABLE book_bindings (book_id TEXT PRIMARY KEY, profile_id TEXT)');
        await db.execute(
          'CREATE TABLE sessions (id TEXT PRIMARY KEY, book_id TEXT NOT NULL, '
          'title TEXT NOT NULL, timeline_json TEXT NOT NULL, '
          'updated_at INTEGER NOT NULL)');
        await db.execute(
          'CREATE INDEX sessions_by_book ON sessions(book_id, updated_at)');
      }),
    );
    const book = BookDefinition(id: 'legacy', title: 'Ancien Livre');
    await old.insert('books', {
      'id': book.id,
      'definition_json': book.exportJson(),
    });
    await old.insert('sessions', {
      'id': 'legacy-session', 'book_id': 'legacy',
      'title': 'Partie intacte', 'timeline_json': '[]',
      'updated_at': 100,
    });
    await old.close();

    final migrated = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: file,
    );
    addTearDown(migrated.close);
    expect((await migrated.findBook('legacy'))!.title, 'Ancien Livre');
    expect((await migrated.findSession('legacy-session'))!.title,
        'Partie intacte');
    await migrated.putDiagnostic(StoredAiDiagnostic(
      id: 'new', sessionId: 'legacy-session',
      createdAtUtc: DateTime.utc(2026), content: '{"format":"test"}',
    ), 5);
    expect(await migrated.listDiagnostics('legacy-session'), hasLength(1));
  });


  test('RAW pending survives restart and a retry commits events atomically',
      () async {
    final dir = await Directory.systemTemp.createTemp('domolia-raw-');
    final file = '${dir.path}/raw.sqlite';
    final first = SqliteBookStore(factory: databaseFactoryFfi, databasePath: file);
    addTearDown(() async {
      await first.close();
      await dir.delete(recursive: true);
    });
    await first.putBook(const BookDefinition(id: 'b', title: 'Livre'));
    const session = BookSession(id: 's', bookId: 'b', title: 'Partie', timeline: [
      ChatEntry(id: 0, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Je quitte la grotte'),
    ]);
    await first.putSession(session);
    await first.saveNarrativeSnapshot(session, const [
      RawGeneration(playerEventId: 0, rawText: 'Le temple apparaît.'),
    ]);
    await first.close();

    final second = SqliteBookStore(factory: databaseFactoryFfi, databasePath: file);
    addTearDown(second.close);
    final pending = await second.listRawGenerations('s');
    expect(pending.single.rawText, 'Le temple apparaît.');
    expect(pending.single.isStructured, false);
    expect((await second.findSession('s'))!.timeline, hasLength(1));

    final committed = session.copyWith(timeline: [
      ...session.timeline,
      const ChatSceneChange(id: 1),
      const ChatEntry(id: 2, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Le temple apparaît.'),
    ]);
    await second.saveNarrativeSnapshot(committed, [
      pending.single.structured(1, 2),
    ]);
    await second.close();

    final third = SqliteBookStore(factory: databaseFactoryFfi, databasePath: file);
    addTearDown(third.close);
    expect((await third.findSession('s'))!.timeline, hasLength(3));
    expect((await third.listRawGenerations('s')).single.isStructured, true);
    await third.saveNarrativeSnapshot(session, const []);
    expect(await third.listRawGenerations('s'), isEmpty);
    expect((await third.findSession('s'))!.timeline, hasLength(1));
  });

  test('Invalid RAW insert rolls back timeline and preserves diagnostics',
      () async {
    final dir = await Directory.systemTemp.createTemp('domolia-raw-txn-');
    final file = '${dir.path}/txn.sqlite';
    final db = SqliteBookStore(factory: databaseFactoryFfi, databasePath: file);
    addTearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });
    await db.putBook(const BookDefinition(id: 'b', title: 'Livre'));
    const session = BookSession(id: 's', bookId: 'b', title: 'Partie', timeline: [
      ChatEntry(id: 10, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Une action'),
    ]);
    await db.putSession(session);
    await db.putDiagnostic(StoredAiDiagnostic(
      id: 'trace', sessionId: 's', createdAtUtc: DateTime.utc(2026),
      content: '{"format":"test"}',
    ), 5);
    final changed = session.copyWith(timeline: [
      ...session.timeline,
      const ChatEntry(id: 11, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Réponse'),
    ]);
    await expectLater(db.saveNarrativeSnapshot(changed, const [
      RawGeneration(playerEventId: 10, rawText: 'Réponse'),
      RawGeneration(playerEventId: 10, rawText: 'Conflit'),
    ]), throwsA(isA<Exception>()));
    expect((await db.findSession('s'))!.timeline, hasLength(1));
    expect(await db.listRawGenerations('s'), isEmpty);
    expect(await db.listDiagnostics('s'), hasLength(1));

    await db.deleteSession('s');
    expect(await db.listRawGenerations('s'), isEmpty);
    expect(await db.listDiagnostics('s'), isEmpty);
    await expectLater(db.saveNarrativeSnapshot(changed, const []),
        throwsStateError);
  });

  test('Manual scene insertion can be reloaded with stable nonmonotonic IDs', () {
    const original = BookSession(id: 's', bookId: 'b', title: 'Partie', timeline: [
      ChatEntry(id: 1, speaker: ChatSpeaker.player, name: 'Vous', text: 'Oui'),
      ChatSceneChange(id: 7),
      ChatEntry(id: 3, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Un temple'),
    ]);
    final restored = BookSession.decodeTimeline(original.encodeTimeline());
    expect(restored.map((e) => e.id), [1, 7, 3]);
    expect(() => BookSession.decodeTimeline(
      '[{"id":1,"type":"scene_change"},{"id":1,"type":"scene_change"}]'),
      throwsFormatException);
  });


  test('Legacy pending literary source resumes from SQLite without an AI call',
      () async {
    final dir = await Directory.systemTemp.createTemp('domolia-stream-integration-');
    final file = '${dir.path}/integration.sqlite';
    final first = SqliteBookStore(factory: databaseFactoryFfi, databasePath: file);
    addTearDown(() async {
      await first.close();
      await dir.delete(recursive: true);
    });
    await first.putBook(const BookDefinition(id: 'b', title: 'Livre'));
    const session = BookSession(id: 's', bookId: 'b', title: 'Partie');
    await first.putSession(session);
    const player = ChatEntry(id: 8, speaker: ChatSpeaker.player,
        name: 'Vous', text: 'Je rentre dans le château.');
    const legacyRaw = RawGeneration(playerEventId: 8,
        rawText: 'Le château apparaît, entouré de brume.');
    await first.saveNarrativeSnapshot(
        session.copyWith(timeline: [player]), [legacyRaw]);
    await first.close();

    final second = SqliteBookStore(
        factory: databaseFactoryFfi, databasePath: file);
    addTearDown(second.close);
    final saved = (await second.findSession('s'))!;
    final pending = await second.listRawGenerations('s');
    expect(saved.timeline, hasLength(1));
    expect(pending.single.isStructured, isFalse);

    final provider = _PipelineProvider();
    final resumed = NarrativeChatController(
      provider: provider,
      configuration: () => _integrationConfig,
      onPersistState: (events, raws) =>
          second.saveNarrativeSnapshot(session.copyWith(timeline: events), raws),
    );
    addTearDown(resumed.dispose);
    resumed.restoreTimeline(saved.timeline, rawGenerations: pending);
    await resumed.retry();
    expect(provider.calls, 0, reason: 'Reuse historical text without another charge.');
    expect(resumed.messages.last.text, legacyRaw.rawText);
    expect((await second.findSession('s'))!.timeline, hasLength(2));
    final persisted = (await second.listRawGenerations('s')).single;
    expect(persisted.isStructured, isTrue);
    expect(persisted.rawText, legacyRaw.rawText);
    await second.deleteBook('b');
    expect(await second.listRawGenerations('s'), isEmpty);
  });

  test('Rollback leaves an earlier committed RAW and timeline untouched',
      () async {
    final dir = await Directory.systemTemp.createTemp('domolia-existing-rollback-');
    final file = '${dir.path}/rollback.sqlite';
    final db = SqliteBookStore(factory: databaseFactoryFfi, databasePath: file);
    addTearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });
    await db.putBook(const BookDefinition(id: 'b', title: 'Livre'));
    const session = BookSession(id: 's', bookId: 'b', title: 'Partie',
      timeline: [
        ChatEntry(id: 0, speaker: ChatSpeaker.player, name: 'Vous', text: 'Oui'),
      ],
    );
    await db.putSession(session);
    const before = RawGeneration(playerEventId: 0, rawText: 'RAW original');
    await db.saveNarrativeSnapshot(session, const [before]);
    final changed = session.copyWith(timeline: [
      ...session.timeline,
      const ChatEntry(id: 1, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Ne doit pas être publié'),
    ]);
    await expectLater(db.saveNarrativeSnapshot(changed, const [
      RawGeneration(playerEventId: 0, rawText: 'RAW nouveau'),
      RawGeneration(playerEventId: 0, rawText: 'Doublon invalide'),
    ]), throwsA(isA<Exception>()));
    expect((await db.findSession('s'))!.timeline, hasLength(1));
    expect((await db.listRawGenerations('s')).single.rawText, before.rawText);
  });


  test('SQLite v4 upgrades task profiles and Lore cache without losing a Party',
      () async {
    final dir = await Directory.systemTemp.createTemp('domolia-tasks-migration-');
    final file = '${dir.path}/tasks.sqlite';
    addTearDown(() async => dir.delete(recursive: true));
    final legacy = await databaseFactoryFfi.openDatabase(
      file,
      options: OpenDatabaseOptions(version: 4, onCreate: (db, version) async {
        await db.execute('CREATE TABLE books '
          '(id TEXT PRIMARY KEY, definition_json TEXT NOT NULL)');
        await db.execute('CREATE TABLE book_bindings '
          '(book_id TEXT PRIMARY KEY, profile_id TEXT)');
        await db.execute('CREATE TABLE sessions '
          '(id TEXT PRIMARY KEY, book_id TEXT NOT NULL, title TEXT NOT NULL, '
          'timeline_json TEXT NOT NULL, updated_at INTEGER NOT NULL, '
          'profile_id TEXT)');
        await db.execute('CREATE TABLE ai_diagnostics '
          '(id TEXT PRIMARY KEY, session_id TEXT NOT NULL, '
          'created_at INTEGER NOT NULL, payload_json TEXT NOT NULL)');
        await db.execute('CREATE TABLE raw_generations '
          '(session_id TEXT NOT NULL, player_event_id INTEGER NOT NULL, '
          'raw_text TEXT NOT NULL, first_event_id INTEGER, '
          'last_event_id INTEGER, '
          'PRIMARY KEY(session_id, player_event_id))');
      }),
    );
    const book = BookDefinition(id: 'old-book', title: 'Avant les tâches');
    await legacy.insert('books', {
      'id': book.id, 'definition_json': book.exportJson(),
    });
    await legacy.insert('sessions', {
      'id': 'old-session', 'book_id': book.id,
      'title': 'Partie sauvegardée', 'timeline_json': '[]',
      'updated_at': 100, 'profile_id': 'writer',
    });
    await legacy.insert('raw_generations', {
      'session_id': 'old-session', 'player_event_id': 3,
      'raw_text': 'Texte déjà généré',
    });
    await legacy.close();

    final db = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: file);
    final old = (await db.findSession('old-session'))!;
    expect(old.title, 'Partie sauvegardée');
    expect(old.aiProfileId, 'writer');
    expect(old.formatterProfileId, isNull);
    expect(old.optimizerProfileId, isNull);
    expect(old.optimizedLore, isNull);
    expect((await db.listRawGenerations(old.id)).single.rawText,
      'Texte déjà généré');

    await db.putSession(old.copyWith(
      formatterProfileId: 'json-only', optimizerProfileId: 'compact-only',
      optimizedLoreHash: 'hash-123', optimizedLore: 'Résumé compact',
      generationOverrides: {
        AiNarrativeTask.narrator: const AiTaskGenerationOverride(
          maxOutputTokens: 16384),
        AiNarrativeTask.jsonifier: const AiTaskGenerationOverride(
          reasoningEffort: 'none'),
      },
    ));
    expect((await db.listRawGenerations(old.id)), hasLength(1));
    await db.close();

    final reopened = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: file);
    addTearDown(reopened.close);
    final saved = (await reopened.findSession('old-session'))!;
    expect(saved.aiProfileId, 'writer');
    expect(saved.formatterProfileId, 'json-only');
    expect(saved.optimizerProfileId, 'compact-only');
    expect(saved.optimizedLoreHash, 'hash-123');
    expect(saved.optimizedLore, 'Résumé compact');
    expect(saved.generationOverrides[AiNarrativeTask.narrator]!
        .maxOutputTokens, 16384);
    expect(saved.generationOverrides[AiNarrativeTask.jsonifier]!
        .reasoningEffort, 'none');
    expect((await reopened.listRawGenerations(old.id)), hasLength(1));
    expect((await reopened.findBook(book.id))!.title, book.title);
  });

  test('SQLite stores compressed narrator context with immutable RAW',
      () async {
    final dir = await Directory.systemTemp.createTemp('domolia-compact-');
    final file = '${dir.path}/compact.sqlite';
    final first = SqliteBookStore(factory: databaseFactoryFfi, databasePath: file);
    addTearDown(() async {
      await first.close();
      await dir.delete(recursive: true);
    });
    await first.putBook(const BookDefinition(id: 'book', title: 'Livre'));
    const session = BookSession(id: 'session', bookId: 'book', title: 'Partie',
        timeline: [
          ChatEntry(id: 0, speaker: ChatSpeaker.player,
            name: 'Vous', text: 'Je regarde'),
          ChatEntry(id: 1, speaker: ChatSpeaker.narrator,
            name: 'Narrateur', text: 'Une porte grince.'),
        ]);
    await first.putSession(session);
    await first.saveNarrativeSnapshot(session, const [
      RawGeneration(playerEventId: 0, rawText: 'Une porte grince.',
        compactText: 'La porte grince.', firstEventId: 1, lastEventId: 1),
    ]);
    await first.close();
    final reopened = SqliteBookStore(
        factory: databaseFactoryFfi, databasePath: file);
    addTearDown(reopened.close);
    final saved = (await reopened.listRawGenerations('session')).single;
    expect(saved.rawText, 'Une porte grince.');
    expect(saved.compactText, 'La porte grince.');
    expect(saved.isStructured, true);
  });

  test('SQLite v6 RAW records migrate with null compact memory', () async {
    final dir = await Directory.systemTemp.createTemp('domolia-v6-compact-');
    final file = '${dir.path}/v6.sqlite';
    addTearDown(() async => dir.delete(recursive: true));
    final legacy = await databaseFactoryFfi.openDatabase(
      file, options: OpenDatabaseOptions(version: 6,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE raw_generations ('
          'session_id TEXT NOT NULL, player_event_id INTEGER NOT NULL, '
          'raw_text TEXT NOT NULL, first_event_id INTEGER, last_event_id INTEGER, '
          'PRIMARY KEY(session_id, player_event_id))');
        await db.insert('raw_generations', {
          'session_id': 'legacy', 'player_event_id': 1,
          'raw_text': 'RAW avant migration',
          'first_event_id': 2, 'last_event_id': 2,
        });
      }));
    await legacy.close();

    final upgraded = SqliteBookStore(
        factory: databaseFactoryFfi, databasePath: file);
    addTearDown(upgraded.close);
    final saved = (await upgraded.listRawGenerations('legacy')).single;
    expect(saved.rawText, 'RAW avant migration');
    expect(saved.compactText, isNull);
    expect(saved.isStructured, true);
  });

}


const _integrationConfig = AiConfiguration(
  baseUrl: defaultAiBaseUrl, model: defaultAiModel, apiKey: 'test',
);

class _PipelineProvider implements AiChatProvider {
  int calls = 0;

  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => [];

  @override
  Future<String> complete(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) async {
    calls++;
    return '${jsonEncode({
      'type': 'message', 'speaker': 'narrator',
      'name': 'Narrateur', 'text': 'Le château apparaît.',
    })}\n';
  }
}
