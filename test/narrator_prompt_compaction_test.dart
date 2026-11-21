import 'dart:convert';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/books/book_lore.dart';
import 'package:domolia/books/lore_startup_context.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/narrative_reference_tools.dart';
import 'package:domolia/chat/narrator.dart';
import 'package:domolia/chat/theatrical_narrator_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const _config = AiConfiguration(
  baseUrl: defaultAiBaseUrl, model: defaultAiModel, apiKey: 'fake',
);

const _lore = BookLore(
  global: LoreGlobal(
    universe: 'Valbrume',
    overview: 'Le bureau des registres ouvre au matin.',
    initialContext: 'Léa Monel et Léa Monnel sont deux personnes distinctes.',
    rules: 'Le jeton n° 62 est proposé, mais non reçu. '
        'Une promesse dépend d’une autorisation écrite.',
    secrets: 'La gardienne du fanal connaît le dossier scellé.',
  ),
  characters: [
    LoreCharacter(id: 'monel', name: 'Léa Monel',
        description: 'Messagère avec une sacoche orange.'),
    LoreCharacter(id: 'monnel', name: 'Léa Monnel',
        description: 'Archiviste avec des gants gris.'),
  ],
  events: [
    LoreEvent(id: 'sealed', name: 'Ouverture du dossier',
        trigger: LoreEventTrigger.conditional,
        condition: 'Autorisation écrite et ouverture par le joueur.'),
  ],
);

class _OfflineProvider implements AiChatProvider {
  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => [];

  @override
  Future<String> complete(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) => throw StateError('No paid request is allowed in prompt tests.');
}

/// Simulates two tool consultations followed by a final theatrical answer.
/// The mocked provider never touches the network or needs an API key.
class _TwoCycleProvider extends _OfflineProvider
    implements AiToolCallingChatProvider {
  final requests = <List<AiToolMessage>>[];
  final declaredTools = <List<AiToolDefinition>>[];

  @override
  Stream<AiToolStreamChunk> streamToolChat(AiConfiguration config, {
    required List<AiToolMessage> messages,
    required List<AiToolDefinition> tools,
    int maxTokens = 1200,
  }) async* {
    final round = requests.length;
    requests.add(List<AiToolMessage>.of(messages));
    declaredTools.add(List<AiToolDefinition>.of(tools));
    if (round < 2) {
      yield AiToolStreamChunk(
        callIndex: 0, callId: 'call_$round', callName: 'search_lore',
        argumentsDelta: '{"query":"Léa Monel"}',
        finishReason: 'tool_calls',
      );
    } else {
      yield const AiToolStreamChunk(
        text: '[NARRATION]\nL’archiviste attend une réponse.',
        finishReason: 'stop',
      );
    }
  }
}

void main() {
  test('default rules preserve narrative invariants with no contradictions', () {
    final prompt = const Narrator().systemPrompt;
    for (final word in [
      'actions', 'paroles', 'pensées', 'choix', 'possessions',
      'engagements', 'noms se ressemblent', 'Live Memory',
      'événement prévu', 'offre', 'promesse conditionnelle',
      'rumeurs', 'secrets',
    ]) {
      expect(prompt, contains(word));
    }
    expect(prompt, isNot(contains('ni balises')));
    expect(prompt, isNot(contains('sans format informatique')));
    // Includes the literary guardrails even for previously saved Books.
    expect(prompt.length, lessThan(2700));
    expect(prompt, contains('ÉCRITURE ET DIALOGUES'));
    expect(prompt, contains('des répliques naturelles'));
    expect(prompt, contains('Ne force ni rencontre'));
    expect(prompt, contains('Un personnage déjà rencontré'));
    expect(theatricalNarratorProtocol, contains('[NARRATION]'));
    expect(theatricalNarratorProtocol, contains('[PERSONNAGE:Nom]'));
    expect(theatricalNarratorProtocol, contains('[SCENE]'));
    expect(theatricalNarratorProtocol, contains('[JOUEUR]'));
  });

  test('custom Book prompts cannot remove narrative invariants', () {
    const custom = Narrator(
      protocolPrompt: 'RÈGLES PERSONNALISÉES',
      narrativePrompt: 'STYLE PERSONNALISÉ',
    );
    final prompt = custom.systemPrompt;
    expect(prompt, startsWith('RÈGLES PERSONNALISÉES'));
    expect(prompt, contains('Ne joue jamais à la place'));
    expect(prompt, contains('Live Memory'));
    expect(prompt, contains('promesse conditionnelle'));
    expect(prompt, contains('secrets'));
    expect(prompt, contains('ÉCRITURE ET DIALOGUES'));
    expect(prompt, contains('Une réponse de quelques lignes'));
    expect(prompt, contains('STYLE PERSONNALISÉ'));
  });

  test('tuning remains configurable without repeating the player rules', () {
    const tuning = NarrativeTuning(
      responseLength: 1, scenePacing: 5,
      styleKeywords: ['Sobre', 'Mystérieux'],
    );
    expect(tuning.prompt, contains('45 à 90'));
    expect(tuning.prompt, contains('séquence étendue'));
    expect(tuning.prompt, contains('Sobre, Mystérieux'));
    expect(tuning.prompt, isNot(contains('Ne joue jamais')));
  });

  test('prepared starting canon is deterministic and secrets stay out', () {
    const builder = LoreStartupContextBuilder();
    final first = builder.build(_lore);
    expect(builder.build(_lore), first);
    expect(first.length, lessThanOrEqualTo(3600));
    expect(first, contains('Léa Monel'));
    expect(first, contains('Léa Monnel'));
    expect(first, contains('jeton n° 62'));
    expect(first, isNot(contains('gardienne du fanal')));
    expect(first, isNot(contains('Ouverture du dossier')));
  });

  test('same context is built locally, including when tools are absent', () {
    final chat = NarrativeChatController(
      provider: _OfflineProvider(), configuration: () => null,
      loreProvider: () => _lore,
    );
    addTearDown(chat.dispose);
    final first = chat.buildNarratorContext(hybrid: true);
    final second = chat.buildNarratorContext(hybrid: true);
    expect(first.map((m) => m.content).toList(),
        second.map((m) => m.content).toList());
    expect(first.first.role, 'system');
    expect(first.first.content, contains('Léa Monel'));
    expect(first.first.content, contains('Léa Monnel'));
    expect(first.first.content, isNot(contains('gardienne du fanal')));
    expect(chat.buildNarratorContext().first.content,
        contains('jeton n° 62'));
  });

  test('all eight legacy tool names and schemas stay available', () {
    final tools = NarrativeReferenceTools.definitions;
    expect(tools.map((t) => t.name).toList(), [
      'search_memory', 'get_memory_entry', 'get_event_history',
      'search_lore', 'get_lore_entry', 'get_lore_global',
      'search_history', 'get_history_excerpt',
    ]);
    for (final tool in tools) {
      expect(tool.parameters['type'], 'object');
      expect(tool.parameters['properties'], isA<Map>());
    }
    // Character budget is a regression guard, NOT a provider token count.
    expect(jsonEncode(tools.map((t) => t.toJson()).toList()).length,
        lessThan(5000));
  });

  test('tool rounds keep one system message and stop after two cycles',
      () async {
    final provider = _TwoCycleProvider();
    final chat = NarrativeChatController(
      provider: provider, configuration: () => _config,
      loreProvider: () => _lore,
      narrator: const Narrator(
        narrativePrompt: 'Ne produis ni JSON, ni balises, '
            'ni instructions destinées à une interface.',
      ),
      structuredStreamingEnabled: true,
      resolveConnection: () async => NarrativeAiEndpoint(
        provider: provider, configuration: _config, toolCallingEnabled: true),
    );
    addTearDown(chat.dispose);
    await chat.send('Je demande à Léa Monel si elle a vu le jeton.');
    expect(chat.error, isNull);
    expect(provider.requests, hasLength(3));
    expect(provider.declaredTools[0], hasLength(8));
    expect(provider.declaredTools[1], hasLength(8));
    expect(provider.declaredTools[2], isEmpty);
    for (final request in provider.requests) {
      expect(request.where((m) => m.role == 'system'), hasLength(1));
      expect(request.first.content, contains('SCRIPT THÉÂTRAL'));
      expect(request.first.content,
          isNot(contains('Ne produis ni JSON, ni balises')));
    }
    expect(chat.messages.last.text, 'L’archiviste attend une réponse.');
  });
}
