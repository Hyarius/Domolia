import 'dart:async';

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
    expect(provider.lastPrompt!.first.content, contains('NDJSON'));
    provider.fragments.add(const AiStreamChunk(
      text: '{"type":"message","speaker":"character",'
          '"name":"Oren","text":"Bonsoir',
    ));
    await _tick();
    expect(chat.timeline.whereType<ChatEntry>().last.text, 'Bonsoir');
    expect(chat.timeline.whereType<ChatEntry>().last.inProgress, true);
    expect(persisted.whereType<ChatEntry>().length, 1);
    provider.fragments.add(const AiStreamChunk(
      text: ', voyageur."}\\n'
          '{"type":"message","speaker":"narrator","name":"Narrateur",'
          '"text":"La pluie cesse."}\\n',
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

  test('malformed second line discards the entire provisional reply', () async {
    final pending = chat.send('Je regarde.');
    await _tick();
    provider.fragments.add(const AiStreamChunk(
      text: '{"type":"message","speaker":"narrator",'
          '"name":"Narrateur","text":"Le vent souffle."}\\n'
          '{"type":"message","speaker":"player",'
          '"name":"Vous","text":"Je vole."}\\n',
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
      text: '{"type":"message","speaker":"narrator",'
          '"name":"Narrateur","text":"La porte',
    ));
    await _tick();
    expect(chat.timeline.whereType<ChatEntry>().length, 2);
    chat.stop();
    expect(chat.timeline.whereType<ChatEntry>().length, 1);
    await pending;
    expect(persistedRaw, isEmpty);
  });
}
