import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/raw_generation.dart';
import 'package:domolia/memory/live_memory.dart';
import 'package:domolia/memory/live_memory_coordinator.dart';

LiveMemoryOperation ring(int turn) => LiveMemoryOperation(
  action: 'upsert',
  fact: LiveMemoryFact(
    id: 'character:elise:ring',
    category: 'character',
    entityId: 'elise',
    label: 'Élise',
    field: 'ring',
    text: 'Bague en argent',
    kind: 'stable',
    certainty: 'confirmed',
    visibility: 'player',
    importance: 4,
    sourceTurnId: turn,
    sourceSide: 'raw',
    sourceQuote: 'bague en argent',
  ),
);

BookSession session(String id) => BookSession(
  id: id,
  bookId: 'book',
  title: 'Partie $id',
  timeline: [
    const ChatEntry(
      id: 1,
      speaker: ChatSpeaker.player,
      name: 'Vous',
      text: 'Je regarde Élise.',
    ),
    const ChatEntry(
      id: 2,
      speaker: ChatSpeaker.narrator,
      name: 'Narrateur',
      text: 'Élise porte une bague en argent.',
    ),
  ],
);

RawGeneration raw([String text = 'Élise porte une bague en argent.']) =>
    RawGeneration(playerEventId: 1, rawText: text).structured(2, 2);

class ScriptedMemoryAi implements AiChatProvider {
  ScriptedMemoryAi(this.responses);
  final List<String> responses;
  int calls = 0;
  List<AiMessage>? lastRequest;

  @override
  Future<String> complete(
    AiConfiguration configuration, {
    required List<AiMessage> messages,
    int maxTokens = 1024,
  }) async {
    calls++;
    lastRequest = messages;
    return responses.removeAt(0);
  }

  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => const [
    AiModel('test-model'),
  ];
}

String output(String quote) => jsonEncode({
  'operations': [
    {
      'action': 'upsert',
      'id': 'character:elise:ring',
      'category': 'character',
      'entity': 'elise',
      'label': 'Élise',
      'field': 'ring',
      'text': 'Élise porte une bague en argent.',
      'kind': 'stable',
      'certainty': 'confirmed',
      'visibility': 'player',
      'importance': 4,
      'sourceSide': 'raw',
      'quote': quote,
    },
  ],
});

void main() {
  setUpAll(sqfliteFfiInit);

  late SqliteBookStore db;
  setUp(() async {
    db = SqliteBookStore(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    await db.putBook(const BookDefinition(id: 'book', title: 'Livre'));
    await db.putSession(session('a'));
    await db.putSession(session('b'));
  });
  tearDown(() => db.close());

  test('independent Parties and cascade deletion', () async {
    await db.saveNarrativeSnapshot(session('a'), [raw()]);
    await db.commitMemoryTurn('a', raw(), [ring(1)]);
    expect(
      (await db.loadMemoryTurns('a')).single.single.fact.text,
      'Bague en argent',
    );
    expect(await db.loadMemoryTurns('b'), isEmpty);
    await db.deleteSession('a');
    expect(await db.loadMemoryTurns('a'), isEmpty);
    expect(await db.findSession('b'), isNotNull);
    await expectLater(
      db.commitMemoryTurn('a', raw(), [ring(1)]),
      throwsStateError,
    );
  });

  test('regeneration invalidates obsolete memory atomically', () async {
    await db.saveNarrativeSnapshot(session('a'), [raw()]);
    await db.commitMemoryTurn('a', raw(), [ring(1)]);
    final changed = raw('Élise ne porte aucune bague.');
    await db.saveNarrativeSnapshot(session('a'), [changed]);
    expect(await db.loadMemoryTurns('a'), isEmpty);
    await expectLater(
      db.commitMemoryTurn('a', raw(), [ring(1)]),
      throwsStateError,
    );
  });

  test(
    'rewind prunes facts but preserves protected manual correction',
    () async {
      await db.saveNarrativeSnapshot(session('a'), [raw()]);
      await db.commitMemoryTurn('a', raw(), [ring(1)]);
      await db.saveMemoryOverride(
        'a',
        LiveMemoryOverride(
          'character:elise:ring',
          fact: ring(1).fact.copyWith(
            text: 'Correction conservée',
            pinned: true,
            manual: true,
            sourceSide: 'manual',
            sourceQuote: 'Correction manuelle utilisateur',
          ),
        ),
      );
      await db.saveNarrativeSnapshot(
        session('a').copyWith(timeline: [session('a').timeline.first]),
        [],
      );
      expect(await db.loadMemoryTurns('a'), isEmpty);
      final facts = LiveMemoryProjection.replay(
        await db.loadMemoryTurns('a'),
        await db.loadMemoryOverrides('a'),
      );
      expect(facts.single.text, 'Correction conservée');
      expect(facts.single.pinned, isTrue);
    },
  );

  test(
    'completed memory extraction resumes after interrupted launch',
    () async {
      await db.saveNarrativeSnapshot(session('a'), [raw()]);
      final fake = ScriptedMemoryAi([output('bague en argent')]);
      final memory = LiveMemoryCoordinator(
        sessionId: 'a',
        store: db,
        isEnabled: () async => true,
        resolveConnection: () async => LiveMemoryAiEndpoint(
          fake,
          const AiConfiguration(
            baseUrl: 'https://example.com',
            model: 'test-model',
            apiKey: 'test-key',
          ),
        ),
      );
      await memory.refresh();
      expect(memory.pendingCount, 1);
      await memory.analyzePending();
      expect(memory.pendingCount, 0);
      expect(memory.facts.single.text, 'Élise porte une bague en argent.');
      await memory.analyzePending();
      expect(fake.calls, 1);
      memory.dispose();
    },
  );

  test('structured NDJSON is memorized from readable narrative, not JSON',
      () async {
    const serialized = '{"type":"message","speaker":"narrator",'
        '"name":"Narrateur","text":"Élise porte une bague en argent."}\n';
    final source = raw(serialized);
    await db.saveNarrativeSnapshot(session('a'), [source]);
    final fake = ScriptedMemoryAi([output('bague en argent')]);
    final memory = LiveMemoryCoordinator(
      sessionId: 'a', store: db, isEnabled: () async => true,
      resolveConnection: () async => LiveMemoryAiEndpoint(
        fake,
        const AiConfiguration(baseUrl: 'https://example.com',
          model: 'test-model', apiKey: 'test-key'),
      ),
    );
    await memory.analyzePending();
    expect(memory.facts.single.sourceQuote, 'bague en argent');
    expect(fake.calls, 1);
    final prompt = fake.lastRequest!.last.content;
    expect(prompt, contains('Élise porte une bague en argent.'));
    expect(prompt, isNot(contains('"speaker":"narrator"')));
    memory.dispose();
  });

  test('invalid JSON leaves an unprocessed turn for retry', () async {
    await db.saveNarrativeSnapshot(session('a'), [raw()]);
    final fake = ScriptedMemoryAi(['invalid', output('bague en argent')]);
    final memory = LiveMemoryCoordinator(
      sessionId: 'a',
      store: db,
      isEnabled: () async => true,
      resolveConnection: () async => LiveMemoryAiEndpoint(
        fake,
        const AiConfiguration(
          baseUrl: 'https://example.com',
          model: 'test-model',
          apiKey: 'test-key',
        ),
      ),
    );
    await memory.analyzePending();
    expect(memory.pendingCount, 1);
    expect(memory.facts, isEmpty);
    await memory.analyzePending();
    expect(memory.pendingCount, 0);
    expect(fake.calls, 2);
    memory.dispose();
  });

  test(
    'memory task can be disabled without destroying existing memories',
    () async {
      await db.saveNarrativeSnapshot(session('a'), [raw()]);
      final fake = ScriptedMemoryAi([output('bague en argent')]);
      final memory = LiveMemoryCoordinator(
        sessionId: 'a',
        store: db,
        isEnabled: () async => false,
        resolveConnection: () async => LiveMemoryAiEndpoint(
          fake,
          const AiConfiguration(
            baseUrl: 'https://example.com',
            model: 'test-model',
            apiKey: 'test-key',
          ),
        ),
      );
      await memory.analyzePending();
      expect(fake.calls, 0);
      expect(memory.pendingCount, 1);
      memory.dispose();
    },
  );

  test('manual tombstone remains after full reanalysis', () async {
    await db.saveNarrativeSnapshot(session('a'), [raw()]);
    await db.commitMemoryTurn('a', raw(), [ring(1)]);
    await db.saveMemoryOverride(
      'a',
      const LiveMemoryOverride('character:elise:ring', deleted: true),
    );
    await db.clearGeneratedMemory('a');
    await db.commitMemoryTurn('a', raw(), [ring(1)]);
    final facts = LiveMemoryProjection.replay(
      await db.loadMemoryTurns('a'),
      await db.loadMemoryOverrides('a'),
    );
    expect(facts, isEmpty);
  });
}
