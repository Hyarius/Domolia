# Narrateur : longueur, rythme et mots-clés

Les trois dimensions sont indépendantes :

- **Détail (1–5)** : richesse des descriptions existante dans le Livre.
- **Longueur (1–5)** : cible indicative pour la prochaine réponse RAW (45–90, 90–170, 170–270, 270–450 ou 450–700 mots).
- **Avancement (1–5)** : nombre de temps forts avant de rendre la main (pas à pas, interactif, fluide, soutenu, cinématique).

Le réglage par défaut est **Courte / Interactif (2 / 2)**. Il vise des tours réactifs, de l’ordre de 90 à 170 mots, et un seul temps fort avant l’intervention du joueur. Pour une description courte mais très imagée, choisir détail élevé et longueur courte ; pour une scène de plusieurs actions, augmenter l’avancement indépendamment de la longueur.

Les **mots-clés de style** sont des orientations littéraires : Immersif, Dialogué, Sensoriel, Sobre, Poétique, Tendu, Mystérieux, Humoristique, ou des valeurs saisies à la main. Maximum 8 mots-clés de 32 caractères, séparés par des virgules et dédupliqués sans tenir compte de la casse. Le style libre existant reste prioritaire pour la définition du Livre ; les consignes communes portent sur la fidélité et la qualité de la scène, pas sur un genre littéraire imposé.

## Séparation des passes

Les consignes ci-dessus sont ajoutées **au prompt RAW du narrateur**, après les instructions littéraires du Livre. Une couche de qualité littéraire commune s'applique à tous les Livres, y compris ceux qui conservent un ancien style personnalisé : dialogues de PNJ distincts, action du joueur respectée, rythme naturel, scènes ordinaires sans suspense forcé. Cette couche n'écrase pas le champ artistique du Livre. Le JSONificateur continue de recevoir et structurer le RAW complet ; ses règles, sa sortie et son budget de tokens ne sont pas modifiés. La cible en mots n'est pas un plafond de tokens forcé susceptible de tronquer l’histoire.

Même avec un avancement élevé, le narrateur ne doit jamais inventer les décisions du joueur : une action ou réaction qui dépend du joueur interrompt la scène. Les dialogues et réactions se concluent sur une occasion naturelle de répondre ; il n'est pas nécessaire de terminer par une question rituelle.

## Persistance et compatibilité

- `BookDefinition` sérialise `responseLength`, `scenePacing` et `styleKeywords` dans l'objet `narrative` du format portable v2, sans y exposer les connexions IA ni les credentials.
- Les Livres importés sans ces trois champs restent valides et obtiennent les réglages `2 / 2 / []`.
- La configuration générale du narrateur accepte les anciennes préférences v1 et écrit dorénavant des données v2 dans la même clé locale.
- La migration d'une ancienne configuration générale vers un Livre conserve les trois réglages si présents.
- Le réglage du Livre est appliqué à ses Parties, et la prochaine génération RAW prend en compte la dernière version enregistrée. Les messages déjà produits ne changent pas.

## Vérifications

Les tests couvrent les 25 combinaisons longueur × avancement, les mots-clés, les préférences v1/v2, les exports/imports de Livre, le prompt RAW et les interactions des contrôles. La compilation Android, l'analyse statique et la suite Flutter complète sont exécutées par GitHub Actions.
