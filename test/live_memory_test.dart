import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:domolia/memory/live_memory.dart';
import 'package:domolia/chat/narrative_reference_tools.dart';
import 'package:domolia/books/book_lore.dart';

LiveMemoryFact fact(
  String id,
  String text, {
  String category = 'character',
  String field = 'detail',
  String kind = 'stable',
  int turn = 1,
  int importance = 3,
  String certainty = 'confirmed',
}) => LiveMemoryFact(
  id: id,
  category: category,
  entityId: 'elise',
  label: 'Élise',
  field: field,
  text: text,
  kind: kind,
  certainty: certainty,
  visibility: 'player',
  importance: importance,
  sourceTurnId: turn,
  sourceSide: 'raw',
  sourceQuote: text,
);

LiveMemoryOperation operation(LiveMemoryFact f, {String action = 'upsert'}) =>
    LiveMemoryOperation(action: action, fact: f);

void main() {
  test('strict schema and literal provenance reject invented assertions', () {
    final payload = jsonEncode({
      'operations': [
        {
          'action': 'upsert',
          'id': 'character:elise:gait',
          'category': 'character',
          'entity': 'elise',
          'label': 'Élise',
          'field': 'gait',
          'text': 'Élise boite de la jambe gauche.',
          'kind': 'stable',
          'certainty': 'confirmed',
          'visibility': 'player',
          'importance': 3,
          'sourceSide': 'raw',
          'quote': 'boite de la jambe gauche',
        },
      ],
    });
    final parsed = LiveMemoryOperation.parse(
      payload,
      playerEventId: 1,
      playerText: 'Bonjour',
      validatedRaw: 'Élise boite de la jambe gauche.',
    );
    expect(parsed.single.fact.sourceTurnId, 1);
    expect(parsed.single.fact.sourceQuote, 'boite de la jambe gauche');
    expect(
      () => LiveMemoryOperation.parse(
        payload,
        playerEventId: 1,
        playerText: 'Bonjour',
        validatedRaw: 'Elle marche.',
      ),
      throwsFormatException,
    );
    expect(
      () => LiveMemoryOperation.parse(
        '{"operations":{}}',
        playerEventId: 1,
        playerText: 'Bonjour',
        validatedRaw: 'Elle marche.',
      ),
      throwsFormatException,
    );
    expect(
      () => LiveMemoryOperation.parse(
        'not json',
        playerEventId: 1,
        playerText: 'Bonjour',
        validatedRaw: 'Elle marche.',
      ),
      throwsFormatException,
    );
  });

  test('state changes and promise fulfillment preserve event chronology', () {
    final inn = fact(
      'state:elise:location',
      'Élise est à l’auberge',
      category: 'state',
      kind: 'state',
      field: 'location',
    );
    final road = fact(
      'state:elise:location',
      'Élise est sur la route',
      category: 'state',
      kind: 'state',
      field: 'location',
      turn: 4,
    );
    final promise = fact(
      'commitment:letter:status',
      'Promesse en attente',
      category: 'commitment',
      kind: 'state',
      field: 'status',
      turn: 2,
    );
    final completed = fact(
      'commitment:letter:status',
      'Promesse accomplie',
      category: 'commitment',
      kind: 'state',
      field: 'status',
      turn: 29,
    );
    final history = LiveMemoryProjection.replay([
      [operation(inn)],
      [operation(promise)],
      [operation(road)],
      [operation(completed)],
    ], const []);
    expect(
      history.singleWhere((f) => f.id == inn.id).text,
      'Élise est sur la route',
    );
    expect(
      history.singleWhere((f) => f.id == promise.id).text,
      'Promesse accomplie',
    );
    final rewound = LiveMemoryProjection.replay([
      [operation(inn)],
      [operation(promise)],
    ], const []);
    expect(
      rewound.singleWhere((f) => f.id == inn.id).text,
      'Élise est à l’auberge',
    );
    expect(
      rewound.singleWhere((f) => f.id == promise.id).text,
      'Promesse en attente',
    );
  });

  test('rumors are retained as unverified reports', () {
    final rumor = fact(
      'character:victor:rumor',
      'Victor aurait trahi le roi.',
      certainty: 'reported',
    );
    expect(LiveMemoryFact.fromJson(rumor.toJson()).certainty, 'reported');
    final projected = LiveMemoryProjection.replay([
      [operation(rumor)],
    ], const []);
    expect(projected.single.certainty, 'reported');
  });

  test('manual overrides and tombstones win even after replay', () {
    final initial = fact('character:elise:ring', 'Bague en argent');
    final corrected = initial.copyWith(
      text: 'Bague en or',
      manual: true,
      pinned: true,
      sourceSide: 'manual',
      sourceQuote: 'Correction manuelle utilisateur',
    );
    final projected = LiveMemoryProjection.replay(
      [
        [operation(initial)],
        [operation(initial.copyWith(text: 'Bague en cuivre'))],
      ],
      [LiveMemoryOverride(initial.id, fact: corrected)],
    );
    expect(projected.single.text, 'Bague en or');
    expect(projected.single.pinned, isTrue);
    expect(
      LiveMemoryProjection.replay(
        [
          [operation(initial)],
        ],
        [LiveMemoryOverride(initial.id, deleted: true)],
      ),
      isEmpty,
    );
  });

  test(
    'thirty-turn adventure retains early details and current commitments',
    () {
      final gait = fact(
        'character:elise:gait',
        'Élise boite de la jambe gauche.',
        field: 'gait',
      );
      final ring = fact(
        'character:elise:ring',
        'Élise porte une bague en argent.',
        field: 'ring',
      );
      final brother = fact(
        'relationship:elise:victor',
        'Victor est le frère d’Élise.',
        category: 'relationship',
        field: 'brother',
        turn: 2,
      );
      final pending = fact(
        'commitment:letter:status',
        'Le joueur a promis de retrouver la lettre.',
        category: 'commitment',
        field: 'status',
        kind: 'state',
        turn: 3,
      );
      final turns = <List<LiveMemoryOperation>>[
        [operation(gait), operation(ring)],
        [operation(brother)],
        [operation(pending)],
      ];
      for (var index = 4; index <= 28; index++) {
        turns.add([
          operation(
            fact(
              'event:turn-$index:observation',
              'Événement $index pendant la quête.',
              category: 'event',
              field: 'observation',
              kind: 'event',
              turn: index,
            ),
          ),
        ]);
      }
      turns.add([
        operation(pending.copyWith(text: 'La lettre a été retrouvée.')),
      ]);
      turns.add([
        operation(
          fact(
            'event:turn-30:gratitude',
            'Élise remercie le joueur.',
            category: 'event',
            field: 'gratitude',
            kind: 'event',
            turn: 30,
          ),
        ),
      ]);
      final memories = LiveMemoryProjection.replay(turns, const []);
      expect(memories.length, 30);
      expect(memories.any((f) => f.text.contains('jambe gauche')), isTrue);
      expect(memories.any((f) => f.text.contains('bague en argent')), isTrue);
      expect(
        memories.singleWhere((f) => f.id == pending.id).text,
        'La lettre a été retrouvée.',
      );
      final selected = const LiveMemorySelector(maxCharacters: 1300)
          .build(memories, ['Je retourne voir Élise à l’auberge']);
      expect(selected, contains('jambe gauche'));
      expect(selected, contains('bague en argent'));
    },
  );

  test('hybrid memory lookup is read-only and respects query budgets', () {
    final gait = fact(
      'character:elise:gait',
      'Élise boite de la jambe gauche.',
      field: 'gait',
    );
    final tools = NarrativeReferenceTools(
      lore: () => const BookLore(),
      timeline: () => const [],
      rawGenerations: () => const [],
      memory: () => [gait],
    );
    final result = jsonDecode(
      tools.execute('search_memory', '{"query":"Élise"}'),
    ) as Map<String, dynamic>;
    expect(result['source'], 'active_party_live_memory');
    expect((result['results'] as List).length, 1);
    final detail = jsonDecode(
      tools.execute('get_memory_entry', '{"id":"character:elise:gait"}'),
    ) as Map<String, dynamic>;
    expect((detail['entry'] as Map)['sourceTurnId'], 1);
    expect(tools.execute('write_memory', '{}'), contains('unknown_tool'));
  });

  test(
    'historical memory lookup sees previous states but current lookup does not',
    () {
      final past = fact(
        'state:elise:location',
        'Élise est à l’auberge.',
        category: 'state',
        kind: 'state',
        field: 'location',
        turn: 1,
      );
      final current = fact(
        'state:elise:location',
        'Élise est sur la route.',
        category: 'state',
        kind: 'state',
        field: 'location',
        turn: 12,
      );
      final tools = NarrativeReferenceTools(
        lore: () => const BookLore(),
        timeline: () => const [],
        rawGenerations: () => const [],
        memory: () => [current],
        memoryHistory: () => [past, current],
      );
      final active = jsonDecode(
        tools.execute('search_memory', '{"query":"Élise"}'),
      ) as Map<String, dynamic>;
      expect((active['results'] as List), hasLength(1));
      final historical = jsonDecode(
        tools.execute('get_event_history', '{"query":"Élise"}'),
      ) as Map<String, dynamic>;
      final records = historical['results'] as List;
      expect(records, hasLength(2));
      expect(records.map((e) => e['source_turn_id']), containsAll([1, 12]));
      expect(
        records.map((e) => e['text']),
        containsAll(['Élise est à l’auberge.', 'Élise est sur la route.']),
      );
    },
  );
}
