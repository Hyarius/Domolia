import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/raw_generation.dart';

const _config = AiConfiguration(
  baseUrl: defaultAiBaseUrl, model: defaultAiModel, apiKey: 'fake-key');

String _line(String text, {String name = 'Narrateur',
    String role = 'narrator'}) => jsonEncode({
  'type': 'message', 'speaker': role, 'name': name, 'text': text,
}) + '\n';

class _FakeStream implements AiChatProvider, AiStreamingChatProvider {
  final updates = StreamController<AiStreamChunk>.broadcast(sync: true);
  int calls = 0;
  List<AiMessage>? lastContext;
  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async => [];
  @override
  Future<String> complete(AiConfiguration configuration, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) => throw StateError('stream expected');
  @override
  Stream<AiStreamChunk> streamChat(AiConfiguration configuration, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) {
    calls++;
    lastContext = messages;
    return updates.stream;
  }
}

class _FakeComplete implements AiChatProvider {
  _FakeComplete(this.reply);
  String reply;
  int calls = 0;
  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async => [];
  @override
  Future<String> complete(AiConfiguration configuration, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) async {
    calls++;
    return reply;
  }
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 80 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(done(), isTrue);
}

void main() {
  test('one request: first draft arrives before full AI reply or storage', () async {
    final provider = _FakeStream();
    final saved = <List<ChatTimelineEvent>>[];
    final chat = NarrativeChatController(
      provider: provider, configuration: () => _config,
      onPersistState: (timeline, raws) async {
        saved.add(List.of(timeline));
      },
    );
    addTearDown(chat.dispose);
    addTearDown(provider.updates.close);
    final sending = chat.send('Je frappe.');
    await _until(() => provider.calls == 1);
    expect(provider.lastContext!.first.content, contains('NDJSON'));
    expect(chat.messages, hasLength(1));
    final frame = _line('La porte s’ouvre.');
    provider.updates.add(AiStreamChunk(text: frame.substring(0, 72)));
    expect(chat.previewEvents, isNotEmpty);
    expect(chat.messages, hasLength(1));
    expect(saved.last.whereType<ChatEntry>(), hasLength(1));
    provider.updates.add(AiStreamChunk(text: frame.substring(72)));
    expect(chat.previewEvents.first.id, 1);
    await provider.updates.close();
    await sending;
    expect(provider.calls, 1);
    expect(chat.error, isNull);
    expect(chat.messages.map((m) => m.text),
        ['Je frappe.', 'La porte s’ouvre.']);
    expect(chat.messages.last.id, 1);
    expect(chat.previewEvents, isEmpty);
    expect(chat.rawGenerations.single.isStructured, true);
    expect(chat.rawGenerations.single.rawText, 'La porte s’ouvre.');
    expect(saved.last.whereType<ChatEntry>(), hasLength(2));
  });

  test('stop clears drafts and discards later fragments and memory source', () async {
    final provider = _FakeStream();
    final chat = NarrativeChatController(
      provider: provider, configuration: () => _config);
    addTearDown(chat.dispose);
    addTearDown(provider.updates.close);
    final pending = chat.send('Je regarde.');
    await _until(() => provider.calls == 1);
    provider.updates.add(AiStreamChunk(text:
        '{"type":"message","speaker":"narrator","name":"Narrateur",'
        '"text":"L’auberge'));
    expect(chat.preview, isNotNull);
    chat.stop();
    provider.updates.add(AiStreamChunk(text: ' est calme."}\n'));
    await pending;
    expect(chat.previewEvents, isEmpty);
    expect(chat.messages, hasLength(1));
    expect(chat.rawGenerations, isEmpty);
    expect(chat.busy, false);
  });

  test('invalid streamed structure cannot publish a valid prefix', () async {
    final provider = _FakeStream();
    final chat = NarrativeChatController(
        provider: provider, configuration: () => _config);
    addTearDown(chat.dispose);
    addTearDown(provider.updates.close);
    final pending = chat.send('Bonjour.');
    await _until(() => provider.calls == 1);
    provider.updates.add(AiStreamChunk(text: _line('Début valide.')));
    expect(chat.previewEvents, hasLength(1));
    provider.updates.add(const AiStreamChunk(text: '{broken}\n'));
    await pending;
    expect(chat.error, isNotNull);
    expect(chat.previewEvents, isEmpty);
    expect(chat.messages, hasLength(1));
    expect(chat.rawGenerations, isEmpty);
  });

  test('non-streaming providers still use only a single generation', () async {
    final provider = _FakeComplete(_line('Le pont apparaît.'));
    final chat = NarrativeChatController(
        provider: provider, configuration: () => _config);
    addTearDown(chat.dispose);
    await chat.send('Je pars.');
    expect(provider.calls, 1);
    expect(chat.error, isNull);
    expect(chat.messages.last.text, 'Le pont apparaît.');
  });

  test('legacy RAW can be recovered as narration without another API call', () async {
    final provider = _FakeComplete(_line('Jamais demandé.'));
    final chat = NarrativeChatController(
        provider: provider, configuration: () => _config);
    addTearDown(chat.dispose);
    chat.restoreTimeline(const [
      ChatEntry(id: 3, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Je parle.'),
    ], rawGenerations: const [
      RawGeneration(playerEventId: 3, rawText: 'Ancien texte littéraire.'),
    ]);
    await chat.retry();
    expect(provider.calls, 0);
    expect(chat.messages.last.text, 'Ancien texte littéraire.');
    expect(chat.pendingRaw, isNull);
    expect(chat.rawGenerations.single.isStructured, true);
  });

  test('failed snapshot leaves no committed AI bubble or memory source', () async {
    final provider = _FakeComplete(_line('Le port est calme.'));
    final chat = NarrativeChatController(
      provider: provider, configuration: () => _config,
      onPersistState: (timeline, raws) async {
        if (raws.any((r) => r.isStructured)) {
          throw StateError('disk full');
        }
      },
    );
    addTearDown(chat.dispose);
    await chat.send('Bonjour.');
    expect(chat.messages, hasLength(1));
    expect(chat.previewEvents, isEmpty);
    expect(chat.rawGenerations, isEmpty);
    expect(chat.error, isNotNull);
  });
}
