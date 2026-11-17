# Templates de formats Domolia

Ce dossier contient des **exemples conformes aux formats actuellement utilisés** par Domolia, sans données privées.

| Fichier | Usage | Importable ? |
| --- | --- | --- |
| `livre_template.json` | Définition portable d'un Livre v2 avec Lore et références | **Oui**, via Livres → Importer JSON |
| `conversation_template.json` | Exemple d'export de conversation | **Non** : format d'export, pas de fonction d'import |
| `diagnostic_ia_template.json` | Exemple d'export de diagnostic IA | **Non** : format d'export, pas de fonction d'import |
| `narrateur_streaming_template.ndjson` | Exemples de messages structurés émis en streaming | **Non** : sortie du modèle, une ligne JSON par événement |
| `lore_template.json` | Fragment Lore autonome identique au `lore` du Livre | **Non** : à insérer dans le Livre |
| `echange_ia_template.json` | Un échange HTTP/SSE `domolia-ai-exchange-v1` | **Non** : diagnostic individuel |
| `live_memory_operations_template.json` | JSON d'opérations renvoyé par l'extracteur Live Memory | **Non** : sortie de modèle IA |
| `app_logs_template.jsonl` | Journal applicatif : un objet JSON par ligne | **Non** : export de logs |

## Règles importantes

- Le format de Livre est `domolia.book` v2. Le champ `tags` au niveau du Livre n'accepte actuellement que `nsfw` ; les genres et thèmes vont dans `lore.global` et les tags libres des fiches de Lore.
- `extensions` doit être un objet vide. `cover` peut être `null` ou un objet `{ "mime": "...", "base64": "..." }` contenant une vraie image PNG/JPEG/WebP.
- Tous les champs des fiches de Lore sont obligatoires dans le JSON, même lorsqu'ils sont vides. Les références sont des identifiants de fiches existantes, jamais des noms.
- Les scénarios et événements définissent un **cadre narratif**, pas des événements déjà survenus. La mémoire dynamique reste propre à chaque Partie.
- Les dates et échanges dans les exports d'exemple sont **fictifs** ; ne pas les utiliser comme métriques de production.
- Le streaming NDJSON ne doit pas contenir de message `player`. Un `scene_change` est un événement distinct.

## Sources de vérité

- `lib/books/book_definition.dart` et `lib/books/book_lore.dart` : schéma et validation des Livres.
- `lib/chat/chat_exports.dart` : export conversation et diagnostic.
- `lib/chat/chat_protocol.dart` : décodage NDJSON.
- `docs/books/format.md` : contrat du Livre.

## Modèles complémentaires

Le fragment `lore_template.json` correspond exactement au champ `lore` du Livre importable. Il n'existe **pas** d'import autonome de Lore.

`live_memory_operations_template.json` démontre le contrat `LiveMemoryOperation.parse` : les champs `sourceSide` et `quote` doivent identifier une citation présente **à l'identique** dans la narration validée ou le message du joueur. L'exemple suppose un message joueur : « Je promets de revenir avant minuit. » ; ce n'est pas un export de souvenir stocké en base.

`echange_ia_template.json` montre une trace HTTP factice avec les identifiants expurgés. Ces diagnostics ne doivent jamais contenir de vraies clés.

`app_logs_template.jsonl` contient des entrées factices conforme au journal local (JSONL : un objet par ligne).

Les exemples de conversation, diagnostics et mémoire **ne peuvent pas être importés** dans l'application : seuls les Livres portables le peuvent.

**Maintenance :** mettre à jour ces exemples et leurs tests lorsqu'un format évolue. Les exports ne sont pas des fichiers à réimporter dans l'application.
