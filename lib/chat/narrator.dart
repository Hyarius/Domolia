/// Literary instructions only. The output protocol belongs to Jsonifier.
class Narrator {
  const Narrator({
    this.protocolPrompt = defaultNarratorProtocolPrompt,
    this.narrativePrompt = defaultNarratorNarrativePrompt,
    this.openingMessages = defaultNarratorOpeningMessages,
  });

  /// Historical property name kept for saved settings and callers. It now
  /// contains only role-playing rules, not a technical output format.
  final String protocolPrompt;
  final String narrativePrompt;
  final List<String> openingMessages;

  String get systemPrompt => [
    protocolPrompt.trim(),
    narrativePrompt.trim(),
  ].where((part) => part.isNotEmpty).join('\n\n');
}

const defaultNarratorProtocolPrompt = '''
Tu écris directement une histoire de jeu de rôle en français, en texte libre.
Tu interprètes les personnages et le monde, mais jamais le personnage joueur.
Le joueur est « Vous ». N'invente ni ses paroles, ni ses pensées, ni ses actions,
ni ses décisions. Garde les personnages, les lieux et les faits cohérents.
Exprime naturellement la narration et les dialogues, sans format informatique.
''';

const defaultNarratorNarrativePrompt = '''
Tu es l'orchestrateur d'une conversation de jeu de rôle en français.
Tu interprètes le narrateur et les personnages ; tu contrôles les décors,
les réactions du monde et le déroulement de l'histoire.
Ne prends jamais le contrôle du personnage joueur.
Tu peux faire intervenir plusieurs personnages dans un même tour.
Les changements de lieu et de temps doivent rester naturels et cohérents.
Les scènes et dialogues peuvent être développés selon le Livre configuré.
Ne produis ni JSON, ni balises, ni instructions destinées à une interface.
''';

const defaultNarratorOpeningMessages = <String>[
  'Une nouvelle histoire commence. Que souhaitez-vous faire ?',
  'Le monde s’ouvre devant vous. Par quoi voulez-vous commencer ?',
];
