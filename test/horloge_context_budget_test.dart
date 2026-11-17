import 'dart:convert';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/books/book_lore.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/narrative_reference_tools.dart';
import 'package:domolia/chat/raw_generation.dart';
import 'package:flutter_test/flutter_test.dart';

const _configuration = AiConfiguration(
  baseUrl: defaultAiBaseUrl, model: defaultAiModel, apiKey: 'fake-key');

class _OfflineProvider implements AiChatProvider {
  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async =>
      const [];

  @override
  Future<String> complete(AiConfiguration configuration, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) async => throw StateError('No remote AI requests in context tests');
}

void main() {
  test('Current scene retains similar characters while old details stay searchable', () {
    const lore = BookLore(
      characters: [
        LoreCharacter(id: 'tomas', name: 'Tomas',
          description: 'Aubergiste du Cadran.'),
        LoreCharacter(id: 'eline-vare', name: 'Éline Vare',
          description: 'Messagère distincte de l’archiviste.'),
        LoreCharacter(id: 'eline-varre', name: 'Éline Varre',
          description: 'Archiviste distincte de la messagère.'),
        LoreCharacter(id: 'mara', name: 'Mara',
          description: 'Gardienne du phare.'),
      ],
      places: [
        LorePlace(id: 'auberge', name: 'Auberge du Cadran',
          description: 'Comptoir et horloge à l’arrêt.'),
        LorePlace(id: 'phare', name: 'Phare de Valbrume',
          description: 'Tour côtière et registre des marées.'),
      ],
    );
    final timeline = <ChatTimelineEvent>[];
    final filler = List.filled(65, 'description de la marche').join(' ');
    for (var i = 0; i < 18; i++) {
      timeline.add(ChatEntry(id: i * 2, speaker: ChatSpeaker.player,
          name: 'Vous',
          text: i == 0
              ? 'Je demande à Tomas pourquoi il propose le ticket bleu 47.'
              : i == 17
                  ? 'Je parle à Éline Varre et Mara au Phare de Valbrume.'
                  : 'Je traverse la ville, étape $i.'));
      timeline.add(ChatEntry(id: i * 2 + 1,
          speaker: ChatSpeaker.narrator, name: 'Narrateur',
          text: i == 0
              ? 'Tomas propose le ticket bleu 47, mais le joueur ne le prend pas.'
              : i == 17
                  ? 'Éline Varre consulte le registre, Mara attend.'
                  : 'Étape $i. $filler'));
    }
    const raw = RawGeneration(playerEventId: 0,
      rawText: 'Tomas propose le ticket bleu 47, mais le joueur ne le prend pas.',
      compactText: 'Ticket bleu 47 proposé, non récupéré.',
      firstEventId: 1, lastEventId: 1);
    final narrow = NarrativeChatController(
      provider: _OfflineProvider(), configuration: () => _configuration,
      loreProvider: () => lore);
    final previousBudget = NarrativeChatController(
      provider: _OfflineProvider(), configuration: () => _configuration,
      loreProvider: () => lore, hybridRecentBudget: 7000);
    addTearDown(narrow.dispose);
    addTearDown(previousBudget.dispose);
    narrow.restoreTimeline(timeline, rawGenerations: [raw]);
    previousBudget.restoreTimeline(timeline, rawGenerations: [raw]);

    final focused = narrow.buildNarratorContext(hybrid: true);
    final earlier = previousBudget.buildNarratorContext(hybrid: true);
    final focusedHistory = focused.skip(1)
        .map((message) => message.content).join('\n');
    final earlierHistory = earlier.skip(1)
        .map((message) => message.content).join('\n');
    expect(focusedHistory.length, lessThan(earlierHistory.length));
    expect(focusedHistory.length, lessThanOrEqualTo(5200));
    expect(focused.first.content, contains('Éline Varre'));
    expect(focused.first.content, isNot(contains('PERSONNAGE CANONIQUE — Éline Vare')));
    expect(focused.first.content, contains('Mara'));
    expect(focused.first.content, contains('Phare de Valbrume'));
    expect(focusedHistory, contains('Je parle à Éline Varre'));

    final tools = NarrativeReferenceTools(
      lore: () => lore, timeline: () => timeline,
      rawGenerations: () => const [raw]);
    final search = jsonDecode(tools.execute('search_history',
        '{"query":"ticket bleu 47"}')) as Map<String, dynamic>;
    expect((search['results'] as List).single['player_event_id'], 0);
    final original = jsonDecode(tools.execute('get_history_excerpt',
        '{"player_event_id":0}')) as Map<String, dynamic>;
    expect(original['turns'][0]['raw_original'],
        contains('le joueur ne le prend pas'));
  });
}
