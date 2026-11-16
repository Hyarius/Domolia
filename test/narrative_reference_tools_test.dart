import 'dart:convert';

import 'package:domolia/books/book_lore.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/narrative_reference_tools.dart';
import 'package:domolia/chat/raw_generation.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> decoded(String value) =>
    jsonDecode(value) as Map<String, dynamic>;

void main() {
  const canon = BookLore(
    characters: [
      LoreCharacter(id: 'liv', name: 'Liv', aliases: ['Livia'],
        description: 'Archiviste de la tour', secrets: 'Une clé cachée',
        relatedCharacterIds: ['erik']),
      LoreCharacter(id: 'erik', name: 'Erik',
        description: 'Gardien du village'),
    ],
    places: [
      LorePlace(id: 'tower', name: 'Tour de verre',
        description: 'Une tour près du port', characterIds: ['liv']),
    ],
    scenarios: [
      LoreScenario(id: 'escape', name: 'La fuite',
        characterIds: ['liv'], eventIds: ['storm']),
    ],
    events: [
      LoreEvent(id: 'storm', name: 'La grande tempête',
        trigger: LoreEventTrigger.conditional,
        description: 'La ville est inondée',
        condition: 'Seulement si la cloche sonne',
        secrets: 'Le maire a prévu ce danger',
        characterIds: ['liv'], scenarioIds: ['escape']),
    ],
  );

  late List<ChatTimelineEvent> timeline;
  late List<RawGeneration> raws;
  late NarrativeReferenceTools tools;

  setUp(() {
    timeline = [
      for (var i = 0; i < 130; i++) ...[
        ChatEntry(id: i * 2, speaker: ChatSpeaker.player,
          name: 'Joueur', text: i == 4
              ? 'Je rencontre Liv à la fontaine sacrée'
              : 'Je marche, étape $i'),
        ChatEntry(id: i * 2 + 1, speaker: ChatSpeaker.character,
          name: i == 4 ? 'Liv' : 'Un passant',
          text: i == 4 ? 'Tu peux garder mon médaillon.'
              : 'Il fait froid.'),
      ],
    ];
    raws = [
      for (var i = 0; i < 130; i++)
        RawGeneration(playerEventId: i * 2,
          rawText: i == 4
              ? 'Liv tend un médaillon d’argent au joueur près de la fontaine.'
              : 'Le héros franchit la colline.',
          compactText: i == 4 ? 'Rencontre de Liv et médaillon' : null,
          firstEventId: i * 2 + 1, lastEventId: i * 2 + 1),
    ];
    tools = NarrativeReferenceTools(
      lore: () => canon, timeline: () => timeline,
      rawGenerations: () => raws,
    );
  });

  test('Find aliases and canonical IDs without dumping a whole fiche', () {
    final result = decoded(tools.execute('search_lore',
        '{"query":"Livia","category":"character"}'));
    final entries = result['results'] as List;
    expect(entries, hasLength(1));
    expect(entries.single['id'], 'liv');
    expect(entries.single.containsKey('secrets'), isFalse);
    expect(decoded(tools.execute('get_lore_entry',
        '{"category":"character","id":"liv"}'))['entry']['secrets'],
        'Une clé cachée');
  });

  test('Conditional event remains potential, with condition and relationships', () {
    final result = decoded(tools.execute('get_lore_entry',
        '{"category":"event","id":"storm"}'));
    expect(result['status'], 'potential_not_verified');
    expect(result['conditionsVerified'], false);
    expect(result['entry']['condition'], contains('cloche'));
    expect(result['entry']['scenarioIds'], ['escape']);
    expect(result['entry']['secrets'], contains('maire'));
  });

  test('History finds original text more than 100 turns ago', () {
    final result = decoded(tools.execute('search_history',
        '{"query":"médaillon argent","limit":2}'));
    final entries = result['results'] as List;
    expect(entries, hasLength(1));
    expect(entries.single['player_event_id'], 8);
  });

  test('Fetch original RAW by player turn and by structured event', () {
    final byTurn = decoded(tools.execute('get_history_excerpt',
        '{"player_event_id":8}'));
    expect(byTurn['turns'][0]['raw_original'], contains('fontaine'));
    final byEvent = decoded(tools.execute('get_history_excerpt',
        '{"event_id":9}'));
    expect(byEvent['turns'][0]['player_event_id'], 8);
    final range = decoded(tools.execute('get_history_excerpt',
        '{"player_event_id":8,"count":3}'));
    expect(range['turns'], hasLength(3));
  });

  test('Removed events and RAWs are never returned after rewind', () {
    timeline.removeRange(8, timeline.length);
    raws.removeWhere((raw) => raw.playerEventId >= 8);
    expect(decoded(tools.execute('search_history',
        '{"query":"médaillon"}'))['results'], isEmpty);
    expect(decoded(tools.execute('get_history_excerpt',
        '{"player_event_id":8}'))['error'], 'turn_not_found');
  });

  test('Each instance is isolated to its Party, and canon changes are live', () {
    final other = NarrativeReferenceTools(
      lore: () => const BookLore(), timeline: () => const [],
      rawGenerations: () => const [],
    );
    expect(decoded(other.execute('search_history',
        '{"query":"médaillon"}'))['results'], isEmpty);
    expect(decoded(other.execute('search_lore',
        '{"query":"Liv"}'))['results'], isEmpty);
    var modified = canon;
    final dynamicTools = NarrativeReferenceTools(
      lore: () => modified, timeline: () => timeline,
      rawGenerations: () => raws,
    );
    modified = modified.copyWith(characters: const []);
    expect(decoded(dynamicTools.execute('search_lore',
        '{"query":"Livia"}'))['results'], isEmpty);
  });

  test('Unknown, empty, malformed and oversized requests are safe', () {
    expect(decoded(tools.execute('magic', '{}'))['error'], 'unknown_tool');
    expect(decoded(tools.execute('search_history', '{'))['error'],
        'invalid_arguments');
    expect(decoded(tools.execute('search_history', '{"query":"a"}'))['error'],
        'invalid_arguments');
    expect(decoded(tools.execute('get_history_excerpt',
        '{"player_event_id":8,"count":100}'))['error'], 'invalid_arguments');
    expect(decoded(tools.execute('get_lore_entry',
        '{"category":"character","id":"absent"}'))['error'], 'entry_not_found');
    expect(decoded(tools.execute('search_lore',
        '{"query":"zznothingzz"}'))['results'], isEmpty);
  });

  test('Unstructured legacy turns remain searchable without RAW', () {
    raws.clear();
    final found = decoded(tools.execute('search_history',
        '{"query":"fontaine sacrée"}'))['results'] as List;
    expect(found.single['player_event_id'], 8);
    final old = decoded(tools.execute('get_history_excerpt',
        '{"player_event_id":8}'));
    expect(old['turns'][0]['legacy_excerpt'], contains('fontaine'));
  });
}
