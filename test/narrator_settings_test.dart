import 'dart:convert';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/narrator.dart';
import 'package:domolia/chat/narrator_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemorySettings implements NarratorSettingsStore {
  Narrator? saved;
  bool fail = false;
  int writes = 0;

  @override
  Future<Narrator?> read() async => saved;

  @override
  Future<void> write(Narrator narrator) async {
    if (fail) throw StateError('Storage refused');
    writes++;
    saved = narrator;
  }
}

class _RecordedProvider implements AiChatProvider {
  int calls = 0;
  List<AiMessage>? lastMessages;

  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async => [];

  @override
  Future<String> complete(
    AiConfiguration configuration, {
    required List<AiMessage> messages,
    int maxTokens = 1200,
  }) async {
    calls++;
    lastMessages = messages;
    return '{"type":"message","speaker":"narrator",'
        '"name":"Narrateur","text":"Le monde vous répond."}';
  }
}

const _configuration = AiConfiguration(
  baseUrl: defaultAiBaseUrl,
  model: defaultAiModel,
  apiKey: 'mock-key-not-real',
);

void main() {
  test('Default Narrator supplies at least one opening without API calls', () {
    final provider = _RecordedProvider();
    final chat = NarrativeChatController(
      provider: provider,
      configuration: () => _configuration,
      selectOpeningIndex: (_) => 0,
    );
    addTearDown(chat.dispose);

    chat.beginConversation();
    expect(chat.timeline, hasLength(1));
    expect(chat.messages.single.speaker, ChatSpeaker.narrator);
    expect(chat.messages.single.name, 'Narrateur');
    expect(chat.messages.single.text,
        defaultNarratorOpeningMessages.first);
    expect(provider.calls, 0);
    expect(chat.currentSceneMessages, hasLength(1));
    chat.beginConversation();
    expect(chat.timeline, hasLength(1));
  });

  test('Opening randomly picks one item, but is never regenerated', () async {
    final provider = _RecordedProvider();
    var selections = 0;
    final chat = NarrativeChatController(
      provider: provider,
      configuration: () => _configuration,
      narrator: const Narrator(openingMessages: ['Ouverture A', 'Ouverture B']),
      selectOpeningIndex: (count) {
        expect(count, 2);
        selections++;
        return 1;
      },
    );
    addTearDown(chat.dispose);
    chat.beginConversation();
    expect(chat.messages.single.text, 'Ouverture B');
    chat.beginConversation();
    expect(selections, 1);

    await chat.send('Je réponds.');
    expect(provider.calls, 1);
    expect(chat.messages.map((e) => e.text),
        ['Ouverture B', 'Je réponds.', 'Le monde vous répond.']);

    final sent = provider.lastMessages!;
    expect(sent.first.role, 'system');
    expect(sent[1].role, 'assistant');
    expect(sent[1].content, contains('"text":"Ouverture B"'));
    expect(sent[2].role, 'user');

    await chat.regenerate();
    expect(chat.messages.first.text, 'Ouverture B');
    expect(chat.messages.where((message) => message.text == 'Ouverture B'),
        hasLength(1));
    expect(selections, 1);
    expect(provider.calls, 2);
  });

  test('A new chat uses the saved settings; later edits affect future turns',
      () async {
    final store = _MemorySettings();
    final settings = NarratorSettingsController(store: store);
    addTearDown(settings.dispose);
    await settings.initialize();
    expect(settings.narrator.narrativePrompt, defaultNarratorNarrativePrompt);

    expect(await settings.save(
      style: 'Narre comme un conte maritime.',
      openingMessagesText: 'Au port !\nÀ bord !',
    ), true);

    final provider = _RecordedProvider();
    final chat = NarrativeChatController(
      provider: provider,
      configuration: () => _configuration,
      narratorProvider: () => settings.narrator,
      selectOpeningIndex: (_) => 0,
    );
    addTearDown(chat.dispose);

    chat.beginConversation();
    expect(chat.messages.single.text, 'Au port !');
    await chat.send('Je monte à bord.');
    expect(provider.lastMessages!.first.content,
        endsWith('Narre comme un conte maritime.'));

    await settings.save(
      style: 'Narre comme un conte mystérieux.',
      openingMessagesText: 'Dans une grotte.',
    );
    await chat.send('Je regarde autour.');
    expect(provider.lastMessages!.first.content,
        endsWith('Narre comme un conte mystérieux.'));
    expect(chat.messages.first.text, 'Au port !');
    expect(chat.messages.where((m) => m.speaker == ChatSpeaker.player),
        hasLength(2));
    expect(provider.calls, 2);
  });

  test('Settings validation never overwrites the last good configuration',
      () async {
    final store = _MemorySettings();
    final settings = NarratorSettingsController(store: store);
    addTearDown(settings.dispose);
    await settings.initialize();
    final original = settings.narrator;
    expect(await settings.save(style: ' ', openingMessagesText: 'Bonjour'),
        false);
    expect(await settings.save(style: 'Un style', openingMessagesText: ''),
        false);
    expect(await settings.save(
      style: 'Un style',
      openingMessagesText: List.filled(31, 'Bonjour').join('\n'),
    ), false);
    expect(settings.narrator, same(original));
    expect(store.writes, 0);

    store.fail = true;
    expect(await settings.save(
      style: 'Un style',
      openingMessagesText: 'Début',
    ), false);
    expect(settings.narrator, same(original));
  });

  test('Local persistence stores narrative data but never the JSON protocol',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalNarratorSettingsStore();
    expect(await store.read(), isNull);
    const narrator = Narrator(
      narrativePrompt: 'Ambiance fantastique',
      openingMessages: ['Entrée A', 'Entrée B'],
    );
    await store.write(narrator);
    final restored = (await store.read())!;
    expect(restored.narrativePrompt, 'Ambiance fantastique');
    expect(restored.openingMessages, ['Entrée A', 'Entrée B']);
    expect(restored.protocolPrompt, defaultNarratorProtocolPrompt);

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('domolia.narrator.settings.v1')!;
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    expect(decoded.keys, containsAll(['version', 'style', 'openingMessages']));
    expect(decoded.containsKey('protocolPrompt'), false);
    expect(raw.contains('"scene_change"'), false);
  });

  test('Existing settings are restored in a freshly created controller',
      () async {
    final store = _MemorySettings();
    final first = NarratorSettingsController(store: store);
    await first.initialize();
    await first.save(
      style: 'Récit en noir et blanc',
      openingMessagesText: 'Entrée unique',
    );
    first.dispose();

    final second = NarratorSettingsController(store: store);
    addTearDown(second.dispose);
    await second.initialize();
    expect(second.narrator.narrativePrompt, 'Récit en noir et blanc');
    expect(second.narrator.openingMessages, ['Entrée unique']);
  });
}
