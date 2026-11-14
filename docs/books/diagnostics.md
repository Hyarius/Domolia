# Exports de diagnostic des conversations et des requêtes IA

Les exports sont des fichiers JSON **déclenchés volontairement par l'utilisateur**.
Aucun diagnostic n'est envoyé à un serveur Domolia.

## Dans l'application

- **Ouvrir une partie → Options de la conversation → Exporter la conversation** :
  conversation entière, les **X dernières scènes** ou les **X derniers messages**.
  Les scènes sont délimitées par les événements `scene_change` du moteur.
  Les messages conservent leur identifiant, locuteur, nom et texte.
- **Options de la conversation → Requête IA + réponse brute** :
  sélectionner un échange sauvegardé, y compris une génération antérieure,
  puis enregistrer un seul fichier réunissant la requête et la réponse
  HTTP/SSE effectivement reçue.
- **Options de la conversation → Purger les diagnostics** :
  après confirmation, supprime les diagnostics de **cette partie uniquement**
  sans supprimer les messages, les scènes ni les autres parties.
- La liste **Commencer ou reprendre une partie** propose aussi un bouton
  **Purger les diagnostics** sur chaque partie, sans devoir l'ouvrir.
- **Paramètres → Diagnostics IA** : régler la conservation à **0, 5, 10, 20
  ou 50** échanges par partie (**10** par défaut). La valeur 0 désactive
  les nouvelles captures et efface les diagnostics actuellement conservés.
  Les plus anciens sont automatiquement supprimés lors des nouveaux
  enregistrements. Une purge explicite compacte également la base SQLite.

Les suppressions et purges locales **ne suppriment pas** les fichiers JSON
que l'utilisateur a déjà exportés ailleurs sur le téléphone.

## Format `domolia-conversation-v1`

Le document contient `exportedAtUtc`, `bookTitle`, `sessionTitle`,
`selection`, `totalEventsInConversation`, `exportedEvents` et la liste
ordonnée `events`. Les messages ont `id`, `type: message`, `speaker`,
`name`, `text`; les séparateurs de scène ont `type: scene_change`.

- **X dernières scènes** : sélectionner les scènes à partir des événements
  de séparation, sans couper le texte d'une scène.
- **X derniers messages** : compter les messages, sans compter les séparateurs
  comme des messages ; les séparateurs situés entre les messages retenus
  restent inclus.
- Une conversation ancienne ne contient pas d'horodatage individuel par
  message : il n'est donc pas inventé dans l'export.

## Format `domolia-ai-exchange-v1`

Un export contient :

- `recordedAtUtc`, `completedAtUtc`, `durationMs` et `provider` ;
- `request.method`, `request.url`, `request.headers` masqués,
  `request.rawBody` (texte du corps HTTP effectivement construit), et
  `request.body` (même JSON décodé) ;
- `response.statusCode`, `response.rawBody` (flux SSE ou corps HTTP
  **avant** décodage narratif), `capturedBytes`, `totalBytesReceived` et
  `truncated` ;
- `interpretation.promptTokens`, `completionTokens`, `cancelled`,
  `error` et `events` (scènes et messages décodés réellement ajoutés
  à la conversation).

La capture a lieu directement au niveau des requêtes HTTP de
`OpenAiCompatibleChatProvider` et `ChatGptResponsesProvider`, pas en
reconstruisant artificiellement le prompt. La capture brute est plafonnée à
**1 Mio par réponse** pour empêcher une consommation de stockage excessive.
`truncated: true` indique que ce fichier ne contient pas l'intégralité
du flux. Une génération sans appel HTTP n'a pas d'échange à exporter.

Les champs `Authorization` sont remplacés par `Bearer [REDACTED]` et
les jetons d'accès ou clés API connus sont expurgés des corps capturés.
**Attention :** les prompts, les textes des personnages et les sorties IA
peuvent contenir des informations personnelles ou confidentielles.
Vérifiez le JSON avant de le partager.

La base SQLite migre de la version 1 vers la version 2 sans effacer
les Livres ou leurs parties. Chaque diagnostic reste rattaché à une seule
partie par une clé étrangère ; la suppression de cette partie le supprime
également.
