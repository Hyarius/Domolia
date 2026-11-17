# Modèles des formats Domolia

Ce répertoire rassemble les modèles des formats réellement utilisés par Domolia. **Seul le Livre peut être importé directement.**

| Fichier | Utilisation | Import dans l'application |
| --- | --- | --- |
| `livre_template.json` | Livre complet `domolia.book` v2, avec Lore, personnages, lieux, scénario et événements | **Oui** : Livres → Importer JSON |
| `lore_template.json` | Objet `lore` isolé, à intégrer au Livre | Non, fragment |
| `narration_stream_template.ndjson` | Sortie du narrateur structuré, un objet par ligne | Non, sortie IA |
| `conversation_template.json` | Export `domolia-conversation-v1` | Non, export en lecture seule |
| `echange_ia_template.json` | Trace HTTP `domolia-ai-exchange-v1` | Non, diagnostic |
| `diagnostic_ia_template.json` | Export agrégé `domolia-ai-pipeline-trace-v1` | Non, diagnostic |
| `live_memory_operations_template.json` | Format de sortie IA de l'extracteur de mémoire | Non, sortie IA |
| `app_logs_template.jsonl` | Journal applicatif, un objet JSON par ligne | Non, log |

## Modèle de Livre

Copier `livre_template.json`, modifier `id`, `title`, `narrative`, `openingMessages` et `lore`, puis importer le JSON UTF-8. Conserver les champs exigés par `BookDefinition.importJson`.

- `format` vaut **`domolia.book`**, `version` vaut **2**.
- `id` : 1 à 100 caractères ASCII, lettres, chiffres, `_` ou `-`.
- **`tags` au niveau du Livre accepte uniquement `"nsfw"`** actuellement ; les autres catégories sont des tags *de fiches de Lore*.
- `cover: null` sans image ; sinon `mime` + `base64` d'une image PNG/JPEG/WebP réelle (taille limitée à 1 Mio).
- `extensions` doit être **`{}`** : les extensions non vides sont refusées.
- Tous les identifiants référencés dans le Lore doivent exister. Laisser `null` pour `homePlaceId` lorsqu'il n'y a pas de lieu.
- Le Livre ne contient pas les Parties, les souvenirs dynamiques, les profils IA, ni les clés API.

## Autres formats

- `.ndjson` et `.jsonl` = **un objet JSON par ligne**, pas un tableau JSON.
- Les sorties du narrateur sont décodées par `ChatLineDecoder`. Les rôles IA autorisés sont `narrator` et `character`, jamais `player`.
- Les opérations de mémoire sont validées par `LiveMemoryOperation.parse`, avec une citation `quote` exactement présente dans le texte du joueur ou dans la narration finalisée. L'exemple correspond à `Je promets de revenir avant minuit.`.
- Les formats de conversation, d'échange IA et de diagnostic sont des **exports**. Aucune fonctionnalité de réimport de Partie ou de diagnostic n'existe à ce jour.
- Dans `diagnostic_ia_template.json`, le statut `jsonified` est un **nom historique** de l'export pour un RAW validé, y compris avec le nouveau narrateur structuré. Il n'implique pas un deuxième appel IA.
- Les diagnostics d'exemple sont fictifs et ne doivent jamais être remplacés par de vraies clés API.

Le test `test/template_formats_test.dart` vérifie les modèles d'après les parseurs de production. Si un schéma évolue, mettre à jour **le modèle et son test**.

Voir aussi : [format des Livres](../docs/books/format.md), [diagnostics](../docs/books/diagnostics.md), [Live Memory](../docs/live_memory.md).
