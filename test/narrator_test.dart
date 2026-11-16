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
  test('Response length and scene pacing are independent controls', () {
    for (var length = 1; length <= 5; length++) {
      for (var pacing = 1; pacing <= 5; pacing++) {
        final narrator = Narrator(tuning: NarrativeTuning(
          responseLength: length,
          scenePacing: pacing,
        ));
        final prompt = narrator.systemPrompt;
        expect(prompt, contains('Rythme de ce tour'));
        expect(prompt, contains('Ne joue jamais à la place'));
        expect(prompt, isNot(contains('NDJSON')));
      }
    }
    const short = NarrativeTuning(responseLength: 2, scenePacing: 1);
    const long = NarrativeTuning(responseLength: 5, scenePacing: 1);
    expect(short.prompt, contains('90 à 170 mots'));
    expect(long.prompt, contains('450 à 700 mots'));
    expect(short.prompt, contains('conséquence immédiate'));
    expect(long.prompt, contains('conséquence immédiate'));
  });

  test('Style keyword parsing, deduplication and validation', () {
    final words = NarrativeTuning.parseKeywords(
        ' Sensoriel, Immersif, sensoriel, Dialogué, ');
    expect(words, ['Sensoriel', 'Immersif', 'Dialogué']);
    final tune = NarrativeTuning(styleKeywords: words);
    expect(tune.prompt, contains('Sensoriel, Immersif, Dialogué'));
    expect(() => const NarrativeTuning(responseLength: 0).validate(),
        throwsFormatException);
    expect(() => const NarrativeTuning(scenePacing: 6).validate(),
        throwsFormatException);
    expect(() => NarrativeTuning(
      styleKeywords: List.filled(9, 'Tag')).validate(),
      throwsFormatException);
    expect(() => const NarrativeTuning(
      styleKeywords: ['Line\nBreak']).validate(), throwsFormatException);
  });

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
    expect(n.systemPrompt, startsWith('RÈGLES\n\nSTYLE\n\n'));
    expect(n.systemPrompt, contains('90 à 170 mots'));
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
    expect(provider.calls[0].first.content, contains('Univers marin simulé'));
    expect(provider.calls[0].first.content, contains('rends la main au joueur'));
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
