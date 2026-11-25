import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/raw_generation.dart';
import 'package:flutter_test/flutter_test.dart';

const config = AiConfiguration(
  baseUrl: defaultAiBaseUrl,
  model: defaultAiModel,
  apiKey: 'test-token',
);

class _NarratorProvider implements AiChatProvider,
    AiStreamingChatProvider, AiToolCallingChatProvider {
  List<AiMessage>? plainContext;
  List<AiToolMessage>? toolContext;

  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async => [];

  @override
  Future<String> complete(AiConfiguration configuration, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) => throw StateError('No second call allowed.');

  @override
  Stream<AiStreamChunk> streamChat(AiConfiguration configuration, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) async* {
    plainContext = messages;
    yield const AiStreamChunk(
      text: '[NARRATION]\nTomas attend votre réaction.\n',
    );
  }

  @override
  Stream<AiToolStreamChunk> streamToolChat(AiConfiguration configuration, {
    required List<AiToolMessage> messages,
    required List<AiToolDefinition> tools,
    int maxTokens = 1200,
  }) async* {
    toolContext = messages;
    yield const AiToolStreamChunk(
      text: '[PERSONNAGE:Tomas]\n« Je vous écoute. »\n',
      finishReason: 'stop',
    );
  }
}

List<ChatTimelineEvent> get history => const [
  ChatEntry(id: 0, speaker: ChatSpeaker.narrator, name: 'Narrateur',
    text: 'La pluie glisse contre les vitres.'),
  ChatEntry(id: 1, speaker: ChatSpeaker.player, name: 'Vous',
    text: 'Je demande des nouvelles à Tomas.'),
  ChatEntry(id: 2, speaker: ChatSpeaker.narrator, name: 'Narrateur',
    text: 'Tomas repose une tasse.'),
  ChatEntry(id: 3, speaker: ChatSpeaker.character, name: 'Tomas',
    text: '« Trois soirs de suite. »', status: 'à voix basse'),
  ChatSceneChange(id: 4),
  ChatEntry(id: 5, speaker: ChatSpeaker.narrator, name: 'Narrateur',
    text: 'Résumé narratif factuel du tour :\nLe vent se lève.'),
  ChatEntry(id: 6, speaker: ChatSpeaker.player, name: 'Vous',
    text: 'Je regarde le quai.'),
  ChatEntry(id: 7, speaker: ChatSpeaker.character, name: 'Éline Vare',
    text: '« Puis-je vous aider ? »'),
];

List<RawGeneration> get raws => const [
  RawGeneration(
    playerEventId: 1,
    rawText: '[NARRATION]\nTomas repose une tasse.',
    compactText: 'Tomas : « Trois soirs de suite. »',
    firstEventId: 2, lastEventId: 5,
  ),
  RawGeneration(
    playerEventId: 6,
    rawText: '[PERSONNAGE:Éline Vare]\n« Puis-je vous aider ? »',
    compactText: 'Résumé narratif factuel du tour :\nÉline Vare : Dialogue',
    firstEventId: 7, lastEventId: 7,
  ),
];

void expectTheatricalHistory(List<String> assistantTexts) {
  final script = assistantTexts.join('\n');
  expect(script, contains('*\nTomas repose une tasse.'));
  expect(script, contains(
    '@Tomas|à voix basse\n« Trois soirs de suite. »'));
  expect(script, contains('---\n*\nLe vent se lève.'));
  expect(script, contains('@Éline Vare\n« Puis-je vous aider ? »'));
  expect(script, isNot(contains('Résumé narratif factuel du tour')));
  expect(script, isNot(contains('Tomas : « Trois soirs de suite. »')));
  expect(script, isNot(contains('Éline Vare : Dialogue')));
}

void main() {
  test('theatre history is reconstructed from UI events, never compact RAW',
      () {
    final chat = NarrativeChatController(
      provider: _NarratorProvider(), configuration: () => config,
      structuredStreamingEnabled: true,
    );
    addTearDown(chat.dispose);
    chat.restoreTimeline(history, rawGenerations: raws);
    final context = chat.buildNarratorContext(
      hybrid: true, theatricalOutput: true);
    expectTheatricalHistory([
      for (final message in context)
        if (message.role == 'assistant') message.content,
    ]);
    final userMessages = [
      for (final message in context)
        if (message.role == 'user') message.content,
    ];
    expect(userMessages, ['Je demande des nouvelles à Tomas.',
        'Je regarde le quai.']);
  });

  test('normal streaming narrator receives theatrical few-shot history',
      () async {
    final provider = _NarratorProvider();
    final chat = NarrativeChatController(
      provider: provider, configuration: () => config,
      structuredStreamingEnabled: true,
    );
    addTearDown(chat.dispose);
    chat.restoreTimeline(history, rawGenerations: raws);
    await chat.send('Je demande à Tomas ce qu’il sait.');
    expect(chat.error, isNull);
    expectTheatricalHistory([
      for (final message in provider.plainContext!)
        if (message.role == 'assistant') message.content,
    ]);
    expect(chat.messages.last.text, 'Tomas attend votre réaction.');
  });

  test('tool-calling streaming also receives theatrical history',
      () async {
    final provider = _NarratorProvider();
    final chat = NarrativeChatController(
      provider: provider, configuration: () => config,
      structuredStreamingEnabled: true,
      resolveConnection: () async => NarrativeAiEndpoint(
        provider: provider, configuration: config, toolCallingEnabled: true),
    );
    addTearDown(chat.dispose);
    chat.restoreTimeline(history, rawGenerations: raws);
    await chat.send('Je demande à Tomas ce qu’il sait.');
    expect(chat.error, isNull);
    expectTheatricalHistory([
      for (final message in provider.toolContext!)
        if (message.role == 'assistant') message.content,
    ]);
    expect(chat.messages.last.name, 'Tomas');
    expect(chat.messages.last.text, '« Je vous écoute. »');
  });
}
