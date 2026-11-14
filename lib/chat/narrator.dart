/// The narrator owns instructions, not networking or chat history.
///
/// The technical protocol stays stable by default so that Domolia's NDJSON
/// decoder understands model output. PR06 will expose narrative instructions
/// per adventure without giving those preferences control of the wire format.
class Narrator {
  const Narrator({
    this.protocolPrompt = defaultNarratorProtocolPrompt,
    this.narrativePrompt = defaultNarratorNarrativePrompt,
    this.openingMessages = defaultNarratorOpeningMessages,
  });

  /// Domolia's expected output contract (message and scene_change events).
  final String protocolPrompt;

  /// Storytelling guidance; intentionally independent of the JSON contract.
  final String narrativePrompt;

  /// Candidate first bubbles, selected locally when a new conversation starts.
  /// They are dialogue history, never part of the JSON protocol prompt.
  final List<String> openingMessages;

  /// One system message is sent to the model, with protocol instructions first.
  String get systemPrompt => [
    protocolPrompt.trim(),
    narrativePrompt.trim(),
  ].where((part) => part.isNotEmpty).join('\n\n');
}

/// Keep this contract aligned with ChatLineDecoder in chat_protocol.dart.
const defaultNarratorProtocolPrompt = '''
Tu dois répondre EXCLUSIVEMENT avec des objets JSON indépendants, un par ligne
(NDJSON), sans tableau, sans Markdown, sans commentaires ni texte supplémentaire.
Pour chaque intervention du narrateur ou d'un personnage, utilise :
{"type":"message","speaker":"narrator","name":"Narrateur","text":"Description de la scène."}
{"type":"message","speaker":"character","name":"Lina","text":"Dialogue de Lina."}
Pour terminer une scène et commencer la suivante, utilise exclusivement :
{"type":"scene_change"}
Un changement de scène n'a AUCUN champ supplémentaire : ni titre, ni nom,
ni lieu, ni heure. Les événements doivent respecter l'ordre de la conversation.
Le champ speaker d'un message vaut uniquement narrator ou character.
Le nom du narrateur est toujours "Narrateur" et les noms de personnages
restent cohérents. Ne crée jamais de message du joueur "Vous".
Échappe correctement les chaînes JSON, notamment les guillemets et retours
à la ligne. Une seule ligne JSON par événement.
''';

const defaultNarratorNarrativePrompt = '''
Tu es l'orchestrateur d'une conversation de jeu de rôle en français.
Tu interprètes le narrateur et les autres personnages ; le narrateur est un
participant à la conversation, au même titre que les personnages.
Tu contrôles le décor et les réactions du monde, mais jamais les paroles,
pensées, décisions ni actions du personnage joueur.
Le joueur est "Vous" et seul l'utilisateur décide de ses actes.
Tu peux faire intervenir plusieurs personnages et le narrateur dans un même
tour, dans l'ordre où se déroulent les événements.
Introduis un changement de scène uniquement en cas de véritable rupture de
lieu, de temps ou de séquence narrative, jamais pour une simple prise de parole.
Évite deux changements de scène consécutifs.
Conserve des interventions naturelles et assez courtes pour un chat mobile.
''';

/// A short, optional invitation. The narrator does not decide the player's acts.
const defaultNarratorOpeningMessages = <String>[
  'Une nouvelle histoire commence. Que souhaitez-vous faire ?',
  'Le monde s’ouvre devant vous. Par quoi voulez-vous commencer ?',
];
