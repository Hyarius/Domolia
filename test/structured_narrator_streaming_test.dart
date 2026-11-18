import 'dart:async';
import 'dart:convert';

import 'package:domolia/memory/live_memory.dart';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/raw_generation.dart';
import 'package:flutter_test/flutter_test.dart';

const _config = AiConfiguration(
  baseUrl: defaultAiBaseUrl, model: defaultAiModel, apiKey: 'fake',
);

class _StreamingNarrator implements AiChatProvider, AiStreamingChatProvider {
  final fragments = StreamController<AiStreamChunk>.broadcast();
  int calls = 0;
  List<AiMessage>? lastPrompt;

  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => [];
  @override
  Future<String> complete(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) => throw StateError('Unexpected second AI call');

  @override
  Stream<AiStreamChunk> streamChat(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) {
    calls++;
    lastPrompt = messages;
    return fragments.stream;
  }
}


class _ToolNarrator implements AiChatProvider, AiToolCallingChatProvider {
  final first = StreamController<AiToolStreamChunk>.broadcast();
  final finalTurn = StreamController<AiToolStreamChunk>.broadcast();
  int calls = 0;

  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => [];
  @override
  Future<String> complete(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) => throw StateError('Unexpected standalone narrator or JSONifier');

  @override
  Stream<AiToolStreamChunk> streamToolChat(AiConfiguration config, {
    required List<AiToolMessage> messages,
    required List<AiToolDefinition> tools,
    int maxTokens = 1200,
  }) {
    calls++;
    return calls == 1 ? first.stream : finalTurn.stream;
  }

  Future<void> close() async {
    await first.close();
    await finalTurn.close();
  }
}


class _RetryOnceNarrator implements AiChatProvider, AiStreamingChatProvider {
  int calls = 0;

  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => [];

  @override
  Future<String> complete(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) => throw StateError('The narrator must stream');

  @override
  Stream<AiStreamChunk> streamChat(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) {
    calls++;
    if (calls == 1) {
      return Stream.error(const AiProviderException(
        'Aucune réponse du fournisseur sous 25 s.',
        kind: AiProviderErrorKind.timeout,
      ));
    }
    return Stream.value(const AiStreamChunk(
      text: '[NARRATION]\nLa porte s’ouvre.',
    ));
  }
}

Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late _StreamingNarrator provider;
  late NarrativeChatController chat;
  late List<ChatTimelineEvent> persisted;
  late List<RawGeneration> persistedRaw;
  var saves = 0;

  setUp(() {
    provider = _StreamingNarrator();
    persisted = [];
    persistedRaw = [];
    saves = 0;
    chat = NarrativeChatController(
      provider: provider, configuration: () => _config,
      structuredStreamingEnabled: true,
      onPersistState: (timeline, raw) async {
        saves++;
        persisted = List.of(timeline);
        persistedRaw = List.of(raw);
      },
    );
  });

  tearDown(() async {
    chat.dispose();
    await provider.fragments.close();
  });

  test('renders partial character text before completion; commits once', () async {
    final pending = chat.send('Je pousse la porte.');
    await _tick();
    expect(provider.calls, 1);
    expect(provider.lastPrompt!.first.content, contains('SCRIPT THÉÂTRAL'));
    provider.fragments.add(const AiStreamChunk(
      text: '[PERSONNAGE:Oren]\nBonsoir',
    ));
    await _tick();
    expect(chat.timeline.whereType<ChatEntry>().last.text, 'Bonsoir');
    expect(chat.timeline.whereType<ChatEntry>().last.inProgress, true);
    expect(persisted.whereType<ChatEntry>().length, 1);
    provider.fragments.add(const AiStreamChunk(
      text: ', voyageur.\n[NARRATION]\nLa pluie cesse.\n',
    ));
    await _tick();
    expect(chat.timeline.whereType<ChatEntry>().length, 3);
    expect(persisted.whereType<ChatEntry>().length, 1);
    provider.fragments.add(const AiStreamChunk(text: ''));
    await provider.fragments.close();
    await pending;
    expect(chat.error, isNull);
    expect(chat.timeline.whereType<ChatEntry>().length, 3);
    expect(chat.messages.last.text, 'La pluie cesse.');
    expect(chat.messages.every((e) => !e.inProgress), true);
    expect(persistedRaw, hasLength(1));
    expect(persistedRaw.single.isStructured, true);
    expect(provider.calls, 1);
    expect(saves, 2);
  });

  test('literary prose fallback streams as narrator and persists once', () async {
    final pending = chat.send('Je regarde Tomas.');
    await _tick();
    provider.fragments.add(const AiStreamChunk(
      text: "L'homme soutient votre regard un instant.",
    ));
    await _tick();
    expect(chat.timeline.whereType<ChatEntry>().last.text,
        "L'homme soutient votre regard un instant.");
    expect(chat.timeline.whereType<ChatEntry>().last.inProgress, true);
    expect(persisted.whereType<ChatEntry>().length, 1);
    provider.fragments.add(const AiStreamChunk(
      text: '\n\n— Bonsoir, répond Tomas.',
    ));
    await provider.fragments.close();
    await pending;
    expect(chat.error, isNull);
    expect(provider.calls, 1);
    expect(chat.messages.last.text, contains('Bonsoir, répond Tomas.'));
    expect(chat.messages.last.speaker, ChatSpeaker.narrator);
    expect(chat.messages.last.inProgress, false);
    expect(persistedRaw, hasLength(1));
    expect(persistedRaw.single.rawText,
        "L'homme soutient votre regard un instant.\n\n— Bonsoir, répond Tomas.");
    expect(persistedRaw.single.validatedNarrative,
        persistedRaw.single.rawText);
    expect(saves, 2);
  });

  test('malformed JSON must not silently fall back to prose', () async {
    final pending = chat.send('Je regarde la porte.');
    await _tick();
    provider.fragments.add(const AiStreamChunk(
      text: '{"type":"message","speaker":"narrator","text":\n',
    ));
    await provider.fragments.close();
    await pending;
    expect(chat.error, isNotNull);
    expect(persistedRaw, isEmpty);
    expect(chat.messages.length, 1);
  });

  test('tool round discards free-text draft before final stage script', () async {
    final tool = _ToolNarrator();
    addTearDown(tool.close);
    final toolChat = NarrativeChatController(
      provider: tool, configuration: () => _config,
      structuredStreamingEnabled: true,
      resolveConnection: () async => NarrativeAiEndpoint(
        provider: tool, configuration: _config, toolCallingEnabled: true),
    );
    addTearDown(toolChat.dispose);
    final pending = toolChat.send('Je cherche une information.');
    await _tick();
    tool.first.add(const AiToolStreamChunk(text: 'Brouillon littéraire.'));
    await _tick();
    expect(toolChat.timeline.whereType<ChatEntry>().last.inProgress, true);
    tool.first.add(const AiToolStreamChunk(callIndex: 0,
      callId: 'search', callName: 'search_lore',
      argumentsDelta: '{"query":"Tomas"}',
    ));
    await _tick();
    expect(toolChat.timeline.whereType<ChatEntry>().length, 1);
    tool.first.add(const AiToolStreamChunk(finishReason: 'tool_calls'));
    await tool.first.close();
    await _tick();
    tool.finalTurn.add(const AiToolStreamChunk(text:
      '[NARRATION]\nRéponse après recherche.\n'));
    await tool.finalTurn.close();
    await pending;
    expect(toolChat.error, isNull);
    expect(toolChat.messages.last.text, 'Réponse après recherche.');
    expect(toolChat.messages.last.text, isNot(contains('Brouillon')));
    expect(tool.calls, 2);
  });

  test('malformed second line discards the entire provisional reply', () async {
    final pending = chat.send('Je regarde.');
    await _tick();
    provider.fragments.add(const AiStreamChunk(
      text: '[NARRATION]\nLe vent souffle.\n'
          '[PERSONNAGE:Vous]\nJe vole.\n',
    ));
    await provider.fragments.close();
    await pending;
    expect(chat.error, isNotNull);
    expect(chat.timeline.whereType<ChatEntry>().length, 1);
    expect(persisted.whereType<ChatEntry>().length, 1);
    expect(persistedRaw, isEmpty);
  });

  test('stop removes draft and prevents late publication', () async {
    final pending = chat.send('Je regarde.');
    await _tick();
    provider.fragments.add(const AiStreamChunk(
      text: '[NARRATION]\nLa porte',
    ));
    await _tick();
    expect(chat.timeline.whereType<ChatEntry>().length, 2);
    chat.stop();
    expect(chat.timeline.whereType<ChatEntry>().length, 1);
    await pending;
    expect(persistedRaw, isEmpty);
  });
  test('tool consultation discards technical draft and streams final reply',
      () async {
    final tool = _ToolNarrator();
    addTearDown(tool.close);
    final eventsSaved = <List<ChatTimelineEvent>>[];
    final toolChat = NarrativeChatController(
      provider: tool, configuration: () => _config,
      structuredStreamingEnabled: true,
      resolveConnection: () async => NarrativeAiEndpoint(
        provider: tool, configuration: _config,
        toolCallingEnabled: true,
      ),
      onPersistState: (events, raws) async {
        eventsSaved.add(List.of(events));
      },
    );
    addTearDown(toolChat.dispose);
    final pending = toolChat.send('Je cherche Oren.');
    await _tick();
    expect(tool.calls, 1);
    tool.first.add(const AiToolStreamChunk(
      text: '[NARRATION]\nBrouillon',
    ));
    await _tick();
    expect(toolChat.timeline.whereType<ChatEntry>().last.inProgress, true);
    tool.first.add(const AiToolStreamChunk(callIndex: 0,
      callId: 'search', callName: 'search_lore',
      argumentsDelta: '{"query":"Oren"}',
    ));
    await _tick();
    expect(toolChat.timeline.whereType<ChatEntry>().length, 1);
    tool.first.add(const AiToolStreamChunk(finishReason: 'tool_calls'));
    await tool.first.close();
    await _tick();
    expect(tool.calls, 2);
    tool.finalTurn.add(const AiToolStreamChunk(
      text: '[PERSONNAGE:Oren]\nBienvenue',
    ));
    await _tick();
    expect(toolChat.timeline.whereType<ChatEntry>().last.text, 'Bienvenue');
    expect(toolChat.timeline.whereType<ChatEntry>().last.inProgress, true);
    expect(eventsSaved.last.whereType<ChatEntry>().length, 1);
    tool.finalTurn.add(const AiToolStreamChunk(text: '.\n'));
    await tool.finalTurn.close();
    await pending;
    expect(toolChat.error, isNull);
    expect(toolChat.messages.last.text, 'Bienvenue.');
    expect(toolChat.rawGenerations, hasLength(1));
    expect(toolChat.rawGenerations.single.rawText, contains('Bienvenue.'));
    expect(tool.calls, 2);
  });


  test('Structured retry preserves player message after provider timeout',
      () async {
    final fallback = _RetryOnceNarrator();
    final local = NarrativeChatController(
      provider: fallback, configuration: () => _config,
      structuredStreamingEnabled: true,
    );
    addTearDown(local.dispose);
    await local.send('Je regarde la porte.');
    final player = local.messages.single;
    expect(local.errorKind, AiProviderErrorKind.timeout);
    expect(local.messages, hasLength(1));
    expect(local.rawGenerations, isEmpty);

    await local.retry();
    expect(local.error, isNull);
    expect(local.errorKind, isNull);
    expect(local.messages, hasLength(2));
    expect(local.messages.first.id, player.id);
    expect(local.messages.first.text, 'Je regarde la porte.');
    expect(local.messages.last.text, 'La porte s’ouvre.');
    expect(local.rawGenerations, hasLength(1));
    expect(fallback.calls, 2);
  });

  test('existing pending RAW is recovered locally, without JSONifier',
      () async {
    chat.restoreTimeline(const [
      ChatEntry(id: 4, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Je regarde la porte.'),
    ], rawGenerations: const [
      RawGeneration(playerEventId: 4,
          rawText: 'La porte se ferme derrière vous.'),
    ]);
    await chat.retry();
    expect(chat.error, isNull);
    expect(chat.messages.last.text, 'La porte se ferme derrière vous.');
    expect(chat.rawGenerations.single.isStructured, true);
    expect(provider.calls, 0);
    expect(persistedRaw, hasLength(1));
  });

  test('Live Memory quotes come from validated theatrical content',
      () {
    final source = RawGeneration(playerEventId: 1, rawText:
        '[PERSONNAGE:Oren]\nLe ticket bleu porte le numéro 47.\n')
        .structured(2, 2, compactText:
            'Oren : Le ticket bleu porte le numéro 47.');
    expect(source.validatedNarrative,
        'Oren : Le ticket bleu porte le numéro 47.');
    final payload = jsonEncode({'operations': [{
      'action': 'upsert',
      'id': 'object:ticket:number',
      'category': 'object', 'entity': 'ticket',
      'label': 'Ticket bleu', 'field': 'number',
      'text': 'Le ticket bleu porte le numéro 47.',
      'kind': 'state', 'certainty': 'confirmed',
      'visibility': 'player', 'importance': 3,
      'sourceSide': 'raw', 'quote': 'numéro 47',
    }]});
    final operations = LiveMemoryOperation.parse(payload,
        playerEventId: 1, playerText: 'Je regarde le ticket.',
        validatedRaw: source.validatedNarrative);
    expect(operations.single.fact.sourceQuote, 'numéro 47');
    expect(() => LiveMemoryOperation.parse(payload,
        playerEventId: 1, playerText: 'Je regarde le ticket.',
        validatedRaw: 'Oren ne mentionne aucun numéro.'),
        throwsFormatException);
  });

}
