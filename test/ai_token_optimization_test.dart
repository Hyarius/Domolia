import 'dart:convert';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/books/book_lore.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/narrative_reference_tools.dart';
import 'package:domolia/chat/raw_generation.dart';
import 'package:domolia/memory/live_memory.dart';
import 'package:flutter_test/flutter_test.dart';

const _config = AiConfiguration(
    baseUrl: defaultAiBaseUrl, model: defaultAiModel, apiKey: 'fake-key');

class _FakeProvider implements AiChatProvider {
  String raw = 'Une pluie fine tombe.';
  List<AiMessage>? formattedContext;
  int narrationCalls = 0, formatterCalls = 0;

  @override
  Future<List<AiModel>> listModels(AiConfiguration c) async => const [];

  @override
  Future<String> complete(AiConfiguration c, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) async {
    if (messages.first.content.contains('JSONificateur')) {
      formatterCalls++;
      formattedContext = messages;
      return jsonEncode({'events': [
        {'type': 'message', 'start': 0, 'end': raw.length,
         'speaker': 'narrator', 'name': 'Narrateur'},
      ]});
    }
    narrationCalls++;
    return raw;
  }
}

void main() {
  test('Search Lore returns exact matched non-secret attribute in one round',
      () {
    const lore = BookLore(characters: [
      LoreCharacter(id: 'liora-valen', name: 'Liora Valen',
        description: 'Archiviste qui porte un médaillon.',
        background: 'Le revers du médaillon a pour inscription AUBE-731.',
        secrets: 'Code secret interdit'),
      LoreCharacter(id: 'liora-vallen', name: 'Liora Vallen',
        description: 'Messagère qui porte un pendentif.',
        background: 'Le pendentif a pour inscription NACRE-204.'),
    ]);
    final tools = NarrativeReferenceTools(
        lore: () => lore, timeline: () => const [],
        rawGenerations: () => const []);
    final a = jsonDecode(tools.execute('search_lore',
        '{"query":"inscription médaillon Liora Valen","limit":2}'))
        as Map<String, dynamic>;
    final results = a['results'] as List;
    final valen = results.cast<Map<String, dynamic>>()
        .firstWhere((v) => v['id'] == 'liora-valen');
    expect(valen['excerpt'], contains('AUBE-731'));
    expect(valen['matchedField'], 'background');
    expect(jsonEncode(a), isNot(contains('Code secret interdit')));
    final b = jsonDecode(tools.execute('search_lore',
        '{"query":"inscription pendentif Liora Vallen","limit":2}'))
        as Map<String, dynamic>;
    expect((b['results'] as List).first['excerpt'], contains('NACRE-204'));
  });

  test('JSONifier receives no chat history for self-contained narration',
      () async {
    final fake = _FakeProvider();
    final chat = NarrativeChatController(
        provider: fake, configuration: () => _config);
    addTearDown(chat.dispose);
    chat.restoreTimeline([
      for (var i = 0; i < 12; i++)
        ChatEntry(id: i, speaker: ChatSpeaker.character,
          name: 'Personnage', text: ['Très long discours précédent $i',
              ...List.filled(40, 'mystère')].join(' ')),
    ]);
    await chat.send('Je regarde la pluie');
    final prompt = fake.formattedContext!.last.content;
    expect(prompt, isNot(contains('Contexte précédent')));
    expect(prompt, contains(fake.raw));
    expect(fake.narrationCalls, 1);
    expect(fake.formatterCalls, 1);
  });

  test('Ambiguous quoted speech retains a bounded cast context', () async {
    final fake = _FakeProvider()..raw = 'Liora murmure : « Reviens. »';
    final chat = NarrativeChatController(
        provider: fake, configuration: () => _config);
    addTearDown(chat.dispose);
    chat.restoreTimeline([
      for (var i = 0; i < 8; i++)
        ChatEntry(id: i, speaker: ChatSpeaker.character,
          name: 'Acteur $i',
          text: ['Mot $i.', ...List.filled(500, 'énorme')].join(' ')),
    ]);
    await chat.send('Je l’écoute');
    final prompt = fake.formattedContext!.last.content;
    expect(prompt, contains('Contexte précédent'));
    expect(prompt, contains('Acteur 7'));
    expect(prompt, isNot(contains('Acteur 0')));
    expect(prompt, isNot(contains(List.filled(300, 'énorme').join(' '))));
  });

  test('10/100/1000 turns: context stays bounded and older facts consultable',
      () {
    for (final length in [10, 100, 1000]) {
      final history = <ChatTimelineEvent>[];
      final raws = <RawGeneration>[];
      for (var turn = 0; turn < length; turn++) {
        final id = turn * 3;
        history.add(ChatEntry(id: id, speaker: ChatSpeaker.player,
            name: 'Vous', text: 'Action $turn, parole courte.'));
        history.add(ChatEntry(id: id + 1, speaker: ChatSpeaker.narrator,
            name: 'Narrateur', text: 'Résultat $turn.'));
        raws.add(RawGeneration(playerEventId: id,
            rawText: ['Long RAW original pour le tour $turn.',
              ...List.filled(40, 'texte')].join(' '),
            compactText: 'Tour $turn, action attestée.',
            firstEventId: id + 1, lastEventId: id + 1));
      }
      final chat = NarrativeChatController(
          provider: _FakeProvider(), configuration: () => _config);
      chat.restoreTimeline(history, rawGenerations: raws);
      final context = chat.buildNarratorContext(hybrid: true);
      final text = context.map((m) => m.content).join('\n');
      expect(text.length, lessThan(8500),
          reason: 'History cap at $length turns');
      expect(text, contains('Tour ${length - 1}'));
      chat.dispose();
    }
  });

  test('Memory selector handles 1000 facts with provenance and bounded size',
      () {
    final facts = [
      for (var i = 0; i < 1000; i++)
        LiveMemoryFact(
          id: 'character:actor-$i:detail',
          category: 'character', entityId: 'actor-$i',
          label: 'Personnage $i', field: 'detail',
          text: 'Détail source $i.',
          kind: 'stable', certainty: 'reported',
          visibility: 'player', importance: i == 3 ? 5 : 2,
          sourceTurnId: i, sourceSide: 'raw',
          sourceQuote: 'Détail source $i.',
        ),
    ];
    final selection = const LiveMemorySelector(maxCharacters: 3600)
        .build(facts, ['actor-3']);
    expect(selection.length, lessThanOrEqualTo(3600));
    expect(selection, contains('tour 3'));
    expect(selection, contains('reported'));
    expect(facts, hasLength(1000));
  });
}
