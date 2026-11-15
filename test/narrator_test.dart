import 'dart:convert';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/narrator.dart';
import 'package:flutter_test/flutter_test.dart';

const config = AiConfiguration(
  baseUrl: defaultAiBaseUrl, model: defaultAiModel, apiKey: 'mock-only',
);
const raw = 'La porte s’ouvre.';

class _Provider implements AiChatProvider {
  final calls = <List<AiMessage>>[];
  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => [];
  @override
  Future<String> complete(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) async {
    calls.add(messages);
    return messages.first.content.contains('JSONificateur')
        ? jsonEncode({'events': [
            {'type': 'message', 'start': 0, 'end': raw.length,
              'speaker': 'narrator', 'name': 'Narrateur'},
          ]})
        : raw;
  }
}

class _StreamingProvider extends _Provider implements AiStreamingChatProvider {
  @override
  Stream<AiStreamChunk> streamChat(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) async* {
    yield AiStreamChunk(text: await complete(
        config, messages: messages, maxTokens: maxTokens));
  }
}

void main() {
  test('Default Narrator has only literary and role-playing constraints', () {
    const n = Narrator();
    expect(n.systemPrompt, contains('jeu de rôle en français'));
    expect(n.systemPrompt, contains('personnage joueur'));
    expect(n.systemPrompt, isNot(contains('NDJSON')));
    expect(n.systemPrompt, isNot(contains('scene_change')));
    expect(n.systemPrompt, isNot(contains('"type"')));
  });

  test('Narrator composes role-play and Book style without formatter rules', () {
    const n = Narrator(
      protocolPrompt: '  RÈGLES  ', narrativePrompt: '  STYLE  ',
    );
    expect(n.systemPrompt, 'RÈGLES\n\nSTYLE');
  });

  test('Non-streaming sends literary prompt and then formatter prompt', () async {
    final provider = _Provider();
    final chat = NarrativeChatController(
      provider: provider, configuration: () => config,
      narrator: const Narrator(narrativePrompt: 'Univers marin simulé'),
    );
    addTearDown(chat.dispose);
    await chat.send('Je regarde la mer.');
    expect(provider.calls, hasLength(2));
    expect(provider.calls[0].first.content, endsWith('Univers marin simulé'));
    expect(provider.calls[0].last.content, 'Je regarde la mer.');
    expect(provider.calls[1].first.content, contains('JSONificateur'));
    expect(chat.messages.last.text, raw);
  });

  test('Streaming transports both passes without streaming bubbles', () async {
    final provider = _StreamingProvider();
    final chat = NarrativeChatController(
      provider: provider, configuration: () => config,
    );
    addTearDown(chat.dispose);
    await chat.send('Je pousse la porte.');
    expect(provider.calls, hasLength(2));
    expect(chat.rawGenerations.single.rawText, raw);
    expect(chat.preview, isNull);
    expect(chat.error, isNull);
  });
}
