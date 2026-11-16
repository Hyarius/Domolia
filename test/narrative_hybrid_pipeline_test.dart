import 'dart:convert';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/books/book_lore.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const config = AiConfiguration(
  baseUrl: defaultAiBaseUrl, model: defaultAiModel, apiKey: 'fake',
);

class FakeToolProvider implements AiChatProvider, AiToolCallingChatProvider {
  final List<List<AiToolMessage>> requests = [];
  final List<List<AiToolDefinition>> offered = [];
  final List<List<AiToolInvocation>> calls = [];
  int narratorFallbacks = 0;
  int formatterCalls = 0;
  bool rejectTools = false;
  bool emitIncomplete = false;
  bool repeatedlyCall = false;
  String raw = 'Liv observe le médaillon ancien.';

  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => [];

  @override
  Future<String> complete(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 2400,
  }) async {
    if (messages.first.content.contains('JSONificateur')) {
      formatterCalls++;
      return jsonEncode({'events': [
        {'type': 'message', 'start': 0, 'end': raw.length,
         'speaker': 'narrator', 'name': 'Narrateur'}
      ]});
    }
    narratorFallbacks++;
    return raw;
  }

  @override
  Stream<AiToolStreamChunk> streamToolChat(AiConfiguration config, {
    required List<AiToolMessage> messages,
    required List<AiToolDefinition> tools,
    int maxTokens = 2400,
  }) async* {
    requests.add(List.of(messages));
    offered.add(List.of(tools));
    if (rejectTools && requests.length == 1) {
      throw const AiToolsUnsupportedException();
    }
    if (requests.length == 1 || repeatedlyCall && tools.isNotEmpty) {
      yield const AiToolStreamChunk(callIndex: 0,
          callId: 'search_1', callName: 'search_history',
          argumentsDelta: '{"query":');
      if (emitIncomplete) return;
      yield const AiToolStreamChunk(callIndex: 0,
          argumentsDelta: '"médaillon ancien"}');
      yield const AiToolStreamChunk(finishReason: 'tool_calls');
    } else {
      yield AiToolStreamChunk(text: raw);
      yield const AiToolStreamChunk(finishReason: 'stop');
    }
    yield const AiToolStreamChunk(promptTokens: 100, completionTokens: 20);
  }
}

void main() {
  late FakeToolProvider provider;
  late NarrativeChatController chat;
  setUp(() {
    provider = FakeToolProvider();
    chat = NarrativeChatController(
      provider: provider, configuration: () => config,
      resolveConnection: () async => NarrativeAiEndpoint(
        provider: provider, configuration: config,
        toolCallingEnabled: true,
      ),
      loreProvider: () => const BookLore(
        characters: [LoreCharacter(id: 'liv', name: 'Liv')],
      ),
    );
  });
  tearDown(() => chat.dispose());

  test('Tool call is technical; RAW persists only after resumed text', () async {
    chat.restoreTimeline(const [
      ChatEntry(id: 0, speaker: ChatSpeaker.player, name: 'Joueur',
        text: 'Je retrouve le médaillon ancien'),
      ChatEntry(id: 1, speaker: ChatSpeaker.narrator, name: 'Narrateur',
        text: 'Le médaillon brille.'),
    ]);
    await chat.send('Liv, te souviens-tu de cela ?');
    expect(provider.requests, hasLength(2));
    expect(provider.offered.first, hasLength(7));
    final resumed = provider.requests.last;
    final technical = resumed.where((m) => m.role == 'tool').single;
    expect(technical.toolCallId, 'search_1');
    expect(technical.content, contains('médaillon'));
    expect(resumed.where((m) => m.role == 'assistant' &&
        m.calls.isNotEmpty).single.calls.single.name, 'search_history');
    expect(provider.formatterCalls, 1);
    expect(chat.rawGenerations.last.rawText, provider.raw);
    expect(chat.messages.any((m) => m.text.contains('search_history')), false);
    expect(chat.error, isNull);
  });

  test('Direct response does not require a second tool request', () async {
    // A first request with an explicit empty tool list can still answer.
    provider.requests.add(const []);
    await chat.send('Que vois-tu ?');
    expect(provider.requests, hasLength(2));
    expect(provider.formatterCalls, 1);
    expect(chat.rawGenerations.single.rawText, provider.raw);
  });

  test('Explicit unsupported tools fallback to normal narrator and formatter', () async {
    provider.rejectTools = true;
    await chat.send('Bonjour');
    expect(provider.requests, hasLength(1));
    expect(provider.narratorFallbacks, 1);
    expect(provider.formatterCalls, 1);
    expect(chat.rawGenerations.single.rawText, provider.raw);
    expect(chat.error, isNull);
  });

  test('An incomplete tool stream never executes a lookup or saves RAW', () async {
    provider.emitIncomplete = true;
    await chat.send('Un message');
    expect(chat.rawGenerations, isEmpty);
    expect(provider.formatterCalls, 0);
    expect(chat.error, isNotNull);
  });

  test('Disabling tools preserves the classic RAW→JSONifier path', () async {
    chat.dispose();
    chat = NarrativeChatController(
      provider: provider, configuration: () => config,
      resolveConnection: () async => NarrativeAiEndpoint(
        provider: provider, configuration: config,
        toolCallingEnabled: false,
      ),
    );
    await chat.send('Bonjour');
    expect(provider.requests, isEmpty);
    expect(provider.narratorFallbacks, 1);
    expect(provider.formatterCalls, 1);
  });

  test('Tool consultation loop is bounded and finishes with tools disabled', () async {
    provider.repeatedlyCall = true;
    await chat.send('Rappelle ce moment');
    expect(provider.requests.length, 3);
    expect(provider.offered[0], hasLength(7));
    expect(provider.offered[1], hasLength(7));
    expect(provider.offered[2], isEmpty);
    expect(chat.rawGenerations.single.rawText, provider.raw);
  });
}
