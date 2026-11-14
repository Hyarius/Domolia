import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/narrator.dart';
import 'package:flutter_test/flutter_test.dart';

const _configuration = AiConfiguration(
  baseUrl: defaultAiBaseUrl,
  model: defaultAiModel,
  apiKey: 'mock-only',
);

const _validReply =
    '{"type":"message","speaker":"narrator","name":"Narrateur",'
    '"text":"La porte s’ouvre."}';

class _RecordingProvider implements AiChatProvider {
  List<AiMessage>? sent;

  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => [];

  @override
  Future<String> complete(
    AiConfiguration config, {
    required List<AiMessage> messages,
    int maxTokens = 1200,
  }) async {
    sent = messages;
    return _validReply;
  }
}

class _RecordingStreamProvider
    implements AiChatProvider, AiStreamingChatProvider {
  List<AiMessage>? sent;

  @override
  Stream<AiStreamChunk> streamChat(
    AiConfiguration config, {
    required List<AiMessage> messages,
    int maxTokens = 1200,
  }) {
    sent = messages;
    return Stream.value(const AiStreamChunk(text: _validReply));
  }

  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => [];

  @override
  Future<String> complete(
    AiConfiguration config, {
    required List<AiMessage> messages,
    int maxTokens = 1200,
  }) async => throw StateError('Streaming should be selected');
}

void main() {
  test('Default Narrator keeps the JSON contract separate from storytelling', () {
    const narrator = Narrator();

    expect(narrator.protocolPrompt, contains('"type":"message"'));
    expect(narrator.protocolPrompt, contains('"type":"scene_change"'));
    expect(narrator.protocolPrompt, contains('NDJSON'));
    expect(narrator.protocolPrompt, contains('Ne crée jamais de message du joueur'));
    expect(narrator.narrativePrompt, contains('français'));
    expect(narrator.narrativePrompt, contains('personnage joueur'));
    expect(narrator.narrativePrompt, contains('changement de scène'));
    expect(narrator.narrativePrompt, isNot(contains('"type":"scene_change"')));
  });

  test('Narrator merges exactly two subprompts into one in stable order', () {
    const narrator = Narrator(
      protocolPrompt: '  PROTOCOLE DE TEST  ',
      narrativePrompt: '  HISTOIRE DE TEST  ',
    );
    expect(
      narrator.systemPrompt,
      'PROTOCOLE DE TEST\n\nHISTOIRE DE TEST',
    );
    expect('PROTOCOLE DE TEST'.allMatches(narrator.systemPrompt), hasLength(1));
    expect('HISTOIRE DE TEST'.allMatches(narrator.systemPrompt), hasLength(1));
  });

  test('Non-streaming request sends a single merged system message', () async {
    final provider = _RecordingProvider();
    final chat = NarrativeChatController(
      provider: provider,
      configuration: () => _configuration,
      narrator: const Narrator(
        protocolPrompt: 'Contrat JSON simulé',
        narrativePrompt: 'Univers marin simulé',
      ),
    );
    addTearDown(chat.dispose);

    await chat.send('Je regarde la mer.');

    final sent = provider.sent!;
    expect(sent.where((message) => message.role == 'system'), hasLength(1));
    expect(sent.first.content, 'Contrat JSON simulé\n\nUnivers marin simulé');
    expect(sent.last.role, 'user');
    expect(sent.last.content, 'Je regarde la mer.');
    expect(chat.error, isNull);
    expect(chat.messages.last.name, 'Narrateur');
  });

  test('Streaming request uses the same default merged prompt', () async {
    final provider = _RecordingStreamProvider();
    final chat = NarrativeChatController(
      provider: provider,
      configuration: () => _configuration,
    );
    addTearDown(chat.dispose);

    await chat.send('Je pousse la porte.');

    final sent = provider.sent!;
    expect(sent.where((message) => message.role == 'system'), hasLength(1));
    expect(sent.first.content, const Narrator().systemPrompt);
    expect(sent.first.content, contains('scene_change'));
    expect(sent.first.content, contains('jeu de rôle en français'));
    expect(chat.messages.last.text, 'La porte s’ouvre.');
    expect(chat.error, isNull);
  });

  test('A new Narrator changes future instructions without changing parsing',
      () async {
    final provider = _RecordingProvider();
    const configured = Narrator(
      narrativePrompt: 'Raconte une histoire de pirates.',
    );
    final chat = NarrativeChatController(
      provider: provider,
      configuration: () => _configuration,
      narrator: configured,
    );
    addTearDown(chat.dispose);

    await chat.send('Je monte sur le bateau.');
    expect(provider.sent!.first.content, startsWith(
      defaultNarratorProtocolPrompt.trim(),
    ));
    expect(provider.sent!.first.content,
        endsWith('Raconte une histoire de pirates.'));
    expect(chat.messages.last.speaker.name, 'narrator');
  });
}
