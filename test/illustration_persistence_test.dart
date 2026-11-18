import 'dart:io';
import 'dart:typed_data';

import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_lore.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/illustration/illustration_records.dart';
import 'package:domolia/illustration/visual_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  const intent = ChatIllustrationIntent(
    id: 3, playerEventId: 1, description: 'Soren ferme le tiroir.');
  List<ChatTimelineEvent> timeline() => [
    const ChatEntry(id: 1, speaker: ChatSpeaker.player,
      name: 'Vous', text: 'Je regarde le tiroir.'),
    const ChatEntry(id: 2, speaker: ChatSpeaker.narrator,
      name: 'Narrateur', text: 'Soren referme lentement le tiroir.'),
    intent,
  ];

  test('SQLite persists image records and rejects a rewound result', () async {
    final dir = await Directory.systemTemp.createTemp('domolia-img-sql-');
    final file = '${dir.path}/books.sqlite';
    final first = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: file);
    addTearDown(() async {
      await first.close();
      await dir.delete(recursive: true);
    });
    await first.putBook(const BookDefinition(
      id: 'b', title: 'Le Registre de Sel'));
    final session = BookSession(id: 's', bookId: 'b',
      title: 'Partie', timeline: timeline());
    await first.putSession(session);
    final scene = const VisualSceneSelector().select(
      intent: intent, timeline: timeline(), lore: const BookLore());
    final record = StoredIllustration(
      requestId: 'request-first', sessionId: 's',
      intentId: intent.id, sourceHash: scene.sourceHash,
      state: IllustrationJobState.available, provider: 'openai',
      model: 'gpt-image-2', createdAtUtc: DateTime.utc(2026, 11, 17),
      prompt: 'Soren referme le tiroir.',
      negativePrompt: 'aucune bulle de texte',
      appearanceProposals: const [
        {
          'id': 'party:soren',
          'identity': 'Adulte aux cheveux bruns et courts',
          'current': 'Chemise sombre, main sur la poignée du tiroir',
        },
      ],
      fileNames: const ['img-request-first-0.png'],
    );
    expect(await first.saveIllustrationIfCurrent(record), isTrue);
    expect((await first.listIllustrations('s')).single.negativePrompt,
      'aucune bulle de texte');
    expect((await first.listIllustrations('s')).single.fileNames,
      ['img-request-first-0.png']);
    expect((await first.listIllustrations('s')).single.appearanceProposals,
      [{
        'id': 'party:soren',
        'identity': 'Adulte aux cheveux bruns et courts',
        'current': 'Chemise sombre, main sur la poignée du tiroir',
      }]);
    await first.close();
    final second = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: file);
    addTearDown(second.close);
    expect((await second.listIllustrations('s')).single.model,
      'gpt-image-2');
    expect((await second.listIllustrations('s')).single.negativePrompt,
      'aucune bulle de texte');
    expect((await second.listIllustrations('s')).single.appearanceProposals.single['id'],
      'party:soren');
    await second.updateSession(session.copyWith(
      timeline: timeline().take(2).toList()));
    expect(await second.listIllustrations('s'), isEmpty);
    expect(await second.saveIllustrationIfCurrent(record), isFalse);
    expect(await second.retainedIllustrationFiles(), isEmpty);
  });

  test('Changing a previous message invalidates an in-flight result',
      () async {
    final dir = await Directory.systemTemp.createTemp('domolia-img-hash-');
    final db = SqliteBookStore(
      factory: databaseFactoryFfi,
      databasePath: '${dir.path}/books.sqlite');
    addTearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });
    await db.putBook(const BookDefinition(id: 'b', title: 'Test'));
    final session = BookSession(id: 's', bookId: 'b',
      title: 'Test', timeline: timeline());
    await db.putSession(session);
    final hash = const VisualSceneSelector().select(
      intent: intent, timeline: timeline(), lore: const BookLore()).sourceHash;
    final record = StoredIllustration(
      requestId: 'request-old', sessionId: 's',
      intentId: 3, sourceHash: hash,
      state: IllustrationJobState.generating,
      provider: 'openuncensored', model: 'visual',
      createdAtUtc: DateTime.utc(2026, 11, 17),
    );
    expect(await db.saveIllustrationIfCurrent(record), isTrue);
    await db.updateSession(session.copyWith(timeline: [
      const ChatEntry(id: 1, speaker: ChatSpeaker.player,
        name: 'Vous', text: 'Je quitte le bureau.'),
      ...timeline().skip(1),
    ]));
    expect(await db.listIllustrations('s'), isEmpty);
    expect(await db.saveIllustrationIfCurrent(record), isFalse);
  });

  test('Existing v14 illustration schema upgrades without losing prompts',
      () async {
    final dir = await Directory.systemTemp.createTemp('domolia-img-v14-');
    final file = '${dir.path}/books.sqlite';
    addTearDown(() => dir.delete(recursive: true));
    final old = await databaseFactoryFfi.openDatabase(file,
      options: OpenDatabaseOptions(version: 14, onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE illustration_generations ('
          'request_id TEXT PRIMARY KEY, session_id TEXT NOT NULL, '
          'intent_id INTEGER NOT NULL, source_hash TEXT NOT NULL, '
          'state TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, '
          'created_at INTEGER NOT NULL, prompt TEXT NOT NULL, '
          "negative_prompt TEXT NOT NULL DEFAULT '', "
          'files_json TEXT NOT NULL, mime_type TEXT, error TEXT, '
          'cost_usd REAL)',
        );
        await db.insert('illustration_generations', {
          'request_id': 'legacy',
          'session_id': 's',
          'intent_id': 3,
          'source_hash': 'hash',
          'state': 'ready',
          'provider': 'director',
          'model': 'text',
          'created_at': 1,
          'prompt': 'Description historique',
          'negative_prompt': 'texte',
          'files_json': '[]',
        });
      }));
    await old.close();

    final upgraded = SqliteBookStore(
      factory: databaseFactoryFfi, databasePath: file);
    addTearDown(upgraded.close);
    final db = await upgraded.database;
    final columns = await db.rawQuery('PRAGMA table_info(illustration_generations)');
    expect(columns.map((c) => c['name']), contains('appearance_proposals_json'));
    final records = await upgraded.listIllustrations('s');
    expect(records.single.prompt, 'Description historique');
    expect(records.single.appearanceProposals, isEmpty);
  });

  test('Binary images survive restart and orphan pruning', () async {
    final dir = await Directory.systemTemp.createTemp('domolia-img-files-');
    addTearDown(() => dir.delete(recursive: true));
    final files = LocalIllustrationFiles(root: () async => dir);
    final pixels = Uint8List.fromList([
      137,80,78,71,13,10,26,10,1,2,3,
    ]);
    final kept = await files.save('request-first-0', pixels, 'image/png');
    final orphan = await files.save(
      'request-orphan-0', Uint8List.fromList([255,216,255,1,2,3]),
      'image/jpeg');
    final restarted = LocalIllustrationFiles(root: () async => dir);
    expect(await restarted.read(kept), pixels);
    await restarted.pruneOrphans({kept});
    expect(await restarted.read(kept), pixels);
    expect(await restarted.read(orphan), isNull);
    expect(await restarted.read('../secrets'), isNull);
  });
}
