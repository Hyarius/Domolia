import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_lore.dart';
import 'package:domolia/chat/chat_protocol.dart';

const book = BookDefinition(
  id: 'atelier',
  title: 'La dernière épreuve',
  narrativeStyle: 'Dialogues secs. Humour discret.',
  tags: {'nsfw'},
  lore: BookLore(
    global: LoreGlobal(
      overview: 'Une imprimerie à Nantes.',
      rules: 'Une feuille coûte huit francs chez Liv.',
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
