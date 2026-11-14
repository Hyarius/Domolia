import 'dart:async';
import 'dart:convert';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeStreamingProvider implements AiChatProvider, AiStreamingChatProvider {
  StreamController<AiStreamChunk>? pipe;
  List<AiMessage>? lastContext;
  int requests = 0;
  bool returnError = false;

  @override
  Stream<AiStreamChunk> streamChat(
    AiConfiguration configuration, {
    required List<AiMessage> messages,
    int maxTokens = 1200,
  }) {
    requests++;
    lastContext = messages;
    if (returnError) {
      return Stream.error(
        const AiProviderException('Clé API refusée. Vérifiez votre clé.'),
      );
    }
    return pipe!.stream;
  }

  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async => [];

  @override
  Future<String> complete(
    AiConfiguration configuration, {
    required List<AiMessage> messages,
    int maxTokens = 1200,
  }) async => throw StateError('The streaming implementation should be used');
}

class SimpleProvider implements AiChatProvider {
  String text = '';
  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => [];
  @override
  Future<String> complete(
    AiConfiguration config, {
    required List<AiMessage> messages,
    int maxTokens = 1200,
  }) async => text;
}

const credentials = AiConfiguration(
  baseUrl: defaultAiBaseUrl,
  model: defaultAiModel,
  apiKey: 'ou-test',
);

String line(String speaker, String name, String text) => jsonEncode({
  'speaker': speaker,
  'name': name,
  'text': text,
});

void main() {
  late FakeStreamingProvider provider;
  late NarrativeChatController chat;

  setUp(() {
    provider = FakeStreamingProvider();
    chat = NarrativeChatController(
      provider: provider,
      configuration: () => credentials,
    );
  });
  tearDown(() {
    chat.dispose();
    provider.pipe?.close();
  });

  test('Streaming progressively reveals speaker-specific bubbles', () async {
    provider.pipe = StreamController<AiStreamChunk>.broadcast();
    final pending = chat.send('Je frappe à la porte.');
    expect(chat.busy, true);
    expect(chat.messages, hasLength(1));
    expect(chat.messages.single.speaker, ChatSpeaker.player);
    expect(chat.preview!.speaker, ChatSpeaker.narrator);
    expect(provider.lastContext!.first.role, 'system');
    expect(provider.lastContext!.last.role, 'user');
    expect(provider.lastContext!.first.content, contains('jamais'));

    provider.pipe!.add(AiStreamChunk(
      text: '{"speaker":"narrator","name":"Narrateur","text":"La por',
    ));
    await Future<void>.delayed(Duration.zero);
    expect(chat.preview!.text, 'La por');
    provider.pipe!.add(AiStreamChunk(text: 'te s’ouvre."}\n'));
    await Future<void>.delayed(Duration.zero);
    expect(chat.messages, hasLength(2));
    expect(chat.messages[1].speaker, ChatSpeaker.narrator);

    provider.pipe!.add(AiStreamChunk(
      text: line('character', 'Lina', 'Bonsoir, entre !'),
      promptTokens: 100,
      completionTokens: 42,
    ));
    await provider.pipe!.close();
    await pending;
    expect(chat.busy, false);
    expect(chat.preview, isNull);
    expect(chat.messages.map((m) => m.name),
        ['Vous', 'Narrateur', 'Lina']);
    expect(chat.promptTokens, 100);
    expect(chat.completionTokens, 42);
    expect(chat.error, isNull);
  });

  test('Stop cancels the stream without removing player action', () async {
    provider.pipe = StreamController<AiStreamChunk>.broadcast();
    final pending = chat.send('Je cours.');
    await Future<void>.delayed(Duration.zero);
    chat.stop();
    await pending;
    expect(chat.busy, false);
    expect(chat.error, contains('interrompue'));
    expect(chat.messages.where((m) => m.speaker == ChatSpeaker.player),
        hasLength(1));
    expect(chat.preview, isNull);
  });

  test('Retry after an invalid response never duplicates player message', () async {
    provider.pipe = StreamController<AiStreamChunk>.broadcast();
    final first = chat.send('Où suis-je ?');
    provider.pipe!.add(const AiStreamChunk(text: 'Je suis du texte sans JSON\n'));
    await provider.pipe!.close();
    await first;
    expect(chat.error, isNotNull);
    expect(chat.messages, hasLength(1));

    provider.pipe = StreamController<AiStreamChunk>.broadcast();
    final retry = chat.retry();
    provider.pipe!.add(AiStreamChunk(
      text: line('narrator', 'Narrateur', 'Tu es dans une auberge.'),
    ));
    await provider.pipe!.close();
    await retry;
    expect(chat.error, isNull);
    expect(chat.messages, hasLength(2));
    expect(chat.messages.where((m) => m.speaker == ChatSpeaker.player),
        hasLength(1));
  });

  test('Regenerate replaces AI replies, preserving previous player input', () async {
    provider.pipe = StreamController<AiStreamChunk>.broadcast();
    final first = chat.send('Je regarde autour de moi.');
    provider.pipe!.add(AiStreamChunk(
      text: line('narrator', 'Narrateur', 'La forêt est sombre.'),
    ));
    await provider.pipe!.close();
    await first;
    expect(chat.messages.last.text, 'La forêt est sombre.');

    provider.pipe = StreamController<AiStreamChunk>.broadcast();
    final second = chat.regenerate();
    provider.pipe!.add(AiStreamChunk(
      text: line('character', 'Lina', 'Une lueur se rapproche.'),
    ));
    await provider.pipe!.close();
    await second;
    expect(chat.messages.map((m) => m.name), ['Vous', 'Lina']);
    expect(chat.messages.length, 2);
  });

  test('Network error is sanitized and retryable', () async {
    provider.returnError = true;
    await chat.send('Bonjour');
    expect(chat.error, contains('Clé API refusée'));
    expect(chat.messages, hasLength(1));
    provider.returnError = false;
    provider.pipe = StreamController<AiStreamChunk>.broadcast();
    final next = chat.retry();
    provider.pipe!.add(AiStreamChunk(
      text: line('narrator', 'Narrateur', 'Bonjour !'),
    ));
    await provider.pipe!.close();
    await next;
    expect(chat.error, isNull);
    expect(chat.messages, hasLength(2));
  });

  test('Without key, no HTTP request is made', () async {
    final noKey = NarrativeChatController(
      provider: provider,
      configuration: () => const AiConfiguration(
        baseUrl: defaultAiBaseUrl, model: defaultAiModel, apiKey: '',
      ),
    );
    await noKey.send('Salut');
    expect(noKey.error, contains('clé API'));
    expect(provider.requests, 0);
    noKey.dispose();
  });

  test('Empty model stream reports an error', () async {
    provider.pipe = StreamController<AiStreamChunk>.broadcast();
    final run = chat.send('Je suis ici');
    await provider.pipe!.close();
    await run;
    expect(chat.error, contains('aucun message'));
  });

  test('Non-streaming providers still render the same speaker protocol', () async {
    final fallback = SimpleProvider()
      ..text = line('character', 'Noé', 'Suis-moi.');
    final controller = NarrativeChatController(
      provider: fallback,
      configuration: () => credentials,
    );
    await controller.send('Qui est là ?');
    expect(controller.messages.map((m) => m.name), ['Vous', 'Noé']);
    expect(controller.error, isNull);
    controller.dispose();
  });

  test('Player message length is capped without network request', () async {
    await chat.send('a' * 4001);
    expect(chat.messages, isEmpty);
    expect(chat.error, contains('trop long'));
    expect(provider.requests, 0);
  });
  test('Scene change splits the timeline and current scene image context',
      () async {
    final fake = SimpleProvider()
      ..text = [
        jsonEncode({
          'type': 'message',
          'speaker': 'narrator',
          'name': 'Narrateur',
          'text': 'Dans la forêt.',
        }),
        '{"type":"scene_change"}',
        jsonEncode({
          'type': 'message',
          'speaker': 'character',
          'name': 'Lina',
          'text': 'Nous entrons dans la maison.',
        }),
      ].join('\n');
    final current = NarrativeChatController(
      provider: fake, configuration: () => credentials,
    );
    await current.send('Je suis Lina.');
    expect(current.timeline, hasLength(4));
    expect(current.timeline[0], isA<ChatEntry>());
    expect(current.timeline[1], isA<ChatEntry>());
    expect(current.timeline[2], isA<ChatSceneChange>());
    expect(current.timeline[3], isA<ChatEntry>());
    expect(current.messages, hasLength(3));
    expect(current.currentSceneMessages.map((x) => x.text),
        ['Nous entrons dans la maison.']);
    expect(current.timeline[2].id, isNot(current.timeline[3].id));
    current.dispose();
  });

  test('Scene boundary is included in follow-up model context', () async {
    provider.pipe = StreamController<AiStreamChunk>.broadcast();
    final first = chat.send('Je quitte la forêt.');
    provider.pipe!.add(AiStreamChunk(text:
        '{"type":"scene_change"}\n'
        '{"type":"message","speaker":"narrator",'
        '"name":"Narrateur","text":"Une maison apparaît."}\n'));
    await provider.pipe!.close();
    await first;
    expect(chat.timeline.whereType<ChatSceneChange>(), hasLength(1));
    expect(chat.currentSceneMessages.map((event) => event.text),
        ['Une maison apparaît.']);

    provider.pipe = StreamController<AiStreamChunk>.broadcast();
    final second = chat.send('J’entre dans la maison.');
    final context = provider.lastContext!;
    expect(context.map((event) => event.content),
        contains('{"type":"scene_change"}'));
    provider.pipe!.add(AiStreamChunk(
      text: line('character', 'Lina', 'Entre.'),
    ));
    await provider.pipe!.close();
    await second;
    expect(chat.currentSceneMessages.map((event) => event.text),
        ['Une maison apparaît.', 'J’entre dans la maison.', 'Entre.']);
  });

  test('Regenerate removes scene dividers generated in the previous turn',
      () async {
    provider.pipe = StreamController<AiStreamChunk>.broadcast();
    final first = chat.send('Nous partons.');
    provider.pipe!.add(const AiStreamChunk(text:
        '{"type":"scene_change"}\n'
        '{"type":"message","speaker":"narrator",'
        '"name":"Narrateur","text":"Nous arrivons."}\n'));
    await provider.pipe!.close();
    await first;
    expect(chat.timeline.whereType<ChatSceneChange>(), hasLength(1));

    provider.pipe = StreamController<AiStreamChunk>.broadcast();
    final rerun = chat.regenerate();
    provider.pipe!.add(AiStreamChunk(
      text: line('narrator', 'Narrateur', 'Nous restons ici.'),
    ));
    await provider.pipe!.close();
    await rerun;
    expect(chat.timeline.whereType<ChatSceneChange>(), isEmpty);
    expect(chat.messages.map((m) => m.text),
        ['Nous partons.', 'Nous restons ici.']);
  });

  test('A scene change alone is not a valid AI response', () async {
    final onlyDivider = SimpleProvider()..text = '{"type":"scene_change"}';
    final current = NarrativeChatController(
      provider: onlyDivider, configuration: () => credentials,
    );
    await current.send('Une action');
    expect(current.error, contains('aucun message'));
    current.dispose();
  });

}
