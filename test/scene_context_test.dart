import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_lore.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const book = BookDefinition(
  id: 'atelier',
  title: 'La dernière épreuve',
  narrativeStyle: 'Dialogues secs. Humour discret.',
  tags: {'nsfw'},
  lore: BookLore(
    global: LoreGlobal(
      overview: 'Une imprimerie à Nantes.',
      initialContext: 'Liv tient la boutique en attendant son associée.',
    ),
    characters: [
      LoreCharacter(
        id: 'liv',
        name: 'Liv',
        role: 'Imprimeuse',
        personality: 'Répond volontiers par un prix.',
        motivations: 'Récupérer la presse familiale.',
        secrets: 'Le syndic est son frère.',
      ),
    ],
  ),
);

const config = AiConfiguration(
  baseUrl: defaultAiBaseUrl,
  model: 'offline',
  apiKey: 'fake',
);

class OfflineScene implements AiChatProvider {
  final prompts = <List<AiMessage>>[];
  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async => [];
  @override
  Future<String> complete(
    AiConfiguration configuration, {
    required List<AiMessage> messages,
    int maxTokens = 1200,
  }) async {
    prompts.add(messages);
    return '*\nLiv retourne le bon de commande.\n'
        '@Liv\nMême le papier coûte plus cher.';
  }
}

NarrativeChatController party(OfflineScene provider) => NarrativeChatController(
  provider: provider,
  configuration: () => config,
  structuredStreamingEnabled: true,
  narrator: book.narrator,
  loreProvider: () => book.lore,
);

List<ChatTimelineEvent> played(int count) => [
  for (var n = 0; n < count; n++) ...[
    ChatEntry(
      id: 2 * n,
      speaker: ChatSpeaker.player,
      name: 'Vous',
      text: n == 0
          ? 'Je vérifie le billet de consigne.'
          : 'Je regarde la feuille $n.',
    ),
    ChatEntry(
      id: 2 * n + 1,
      speaker: ChatSpeaker.character,
      name: 'Liv',
      text: n == 0
          ? '${'La pluie tambourine. ' * 22}La consigne porte le numéro 517.'
          : 'Regardez la marge du feuillet $n. '
                'Il y a assez de place pour une ligne de plus, si vous payez le supplément.',
    ),
  ],
];

void main() {
  test(
    'a new Party sends one request and casts speaking roles locally',
    () async {
      const defaults = BookSession(id: 'p', bookId: 'atelier', title: 'Partie');
      expect(defaults.memoryEnabled, false);
      expect(defaults.toolCallingEnabled, false);
      final provider = OfflineScene();
      final chat = party(provider);
      addTearDown(chat.dispose);
      await chat.send('Je demande son prix à Liv.');
      expect(chat.error, isNull);
      final prompt = provider.prompts.single;
      expect(prompt.last.content, 'Je demande son prix à Liv.');
      expect(prompt.first.content, contains('Humour discret'));
      expect(prompt.first.content, contains('adulte'));
      expect(prompt.first.content, contains('Récupérer la presse familiale'));
      expect(prompt.first.content, isNot(contains('Le syndic')));
      expect(prompt.first.content, isNot(contains('[IMAGE]')));
      expect(chat.messages.map((e) => e.speaker), [
        ChatSpeaker.player,
        ChatSpeaker.narrator,
        ChatSpeaker.character,
      ]);
      expect(chat.messages.last.name, 'Liv');
    },
  );

  test(
    'long Party recalls the old evidence and keeps current input verbatim',
    () async {
      final provider = OfflineScene();
      final chat = party(provider);
      addTearDown(chat.dispose);
      chat.restoreTimeline(played(80));
      const action = 'Quel numéro figure sur la consigne ?';
      await chat.send(action);
      final prompt = provider.prompts.single;
      expect(prompt.last.content, action.trim());
      expect(prompt.where((m) => m.content == action), hasLength(1));
      final history = prompt.skip(1).map((m) => m.content).join('\n');
      expect(history, contains('La consigne porte le numéro 517.'));
      expect(history, contains('feuillet 79'));
      expect(history, isNot(contains('feuillet 42')));
      expect(history.length, lessThan(3000));
      await chat.resumeFromPlayerMessage(0);
      final rewound = provider.prompts.last.map((m) => m.content).join('\n');
      expect(rewound, isNot(contains('517')));
      expect(rewound, isNot(contains('feuillet 79')));
    },
  );

  test('the opening of the active scene survives a long dialogue', () async {
    final provider = OfflineScene();
    final chat = party(provider);
    addTearDown(chat.dispose);
    chat.restoreTimeline([
      const ChatSceneChange(id: 0),
      const ChatEntry(
        id: 1,
        speaker: ChatSpeaker.narrator,
        name: 'Narrateur',
        text: 'La grille du quai se referme.',
      ),
      const ChatSceneChange(id: 2),
      const ChatEntry(
        id: 3,
        speaker: ChatSpeaker.narrator,
        name: 'Narrateur',
        text: 'La réception ouvre au deuxième étage.',
      ),
      for (final event in played(50).whereType<ChatEntry>())
        ChatEntry(
          id: event.id + 4,
          speaker: event.speaker,
          name: event.name,
          text: event.text,
        ),
    ]);
    await chat.send('Et maintenant ?');
    final prompt = provider.prompts.single.map((m) => m.content).join('\n');
    expect(prompt, contains('La réception ouvre au deuxième étage.'));
    expect(prompt, isNot(contains('La grille du quai se referme.')));
  });

  test(
    'long prior reply still hands off its last line to a short answer',
    () async {
      final provider = OfflineScene();
      final chat = party(provider);
      addTearDown(chat.dispose);
      chat.restoreTimeline([
        const ChatEntry(
          id: 0,
          speaker: ChatSpeaker.player,
          name: 'Vous',
          text: 'Je lis.',
        ),
        ChatEntry(
          id: 1,
          speaker: ChatSpeaker.character,
          name: 'Liv',
          text: '${'Quelque chose est écrit. ' * 200}Vous signez ?',
        ),
      ]);
      final action = 'Oui. ${'À condition que ce soit écrit. ' * 123}';
      await chat.send(action);
      final prompt = provider.prompts.single;
      expect(prompt.last.content, action.trim());
      expect(prompt[prompt.length - 2].content, endsWith('Vous signez ?'));
    },
  );
}
