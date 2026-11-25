# Templates de formats Domolia

Ce dossier contient des **exemples conformes aux formats actuellement utilisés** par Domolia, sans données privées.

| Fichier | Usage | Importable ? |
| --- | --- | --- |
| `livre_template.json` | Définition portable d'un Livre v3 avec Lore et configuration artistique (style, format, exclusions) | **Oui**, via Livres → Importer JSON |
| `illustration_prompt_template.json` | Export du prompt graphique historique et de ses métadonnées | **Non** : export de diagnostic |
| `conversation_template.json` | Exemple d'export de conversation | **Non** : format d'export, pas de fonction d'import |
| `diagnostic_ia_template.json` | Exemple d'export de diagnostic IA | **Non** : format d'export, pas de fonction d'import |
| `narrateur_theatral_template.txt` | Sortie courante du narrateur : didascalies et répliques balisées | **Non** : sortie textuelle du modèle |

## Règles importantes

- Le format de Livre est `domolia.book` v3 (v1 et v2 restent importables). Le champ `tags` au niveau du Livre n'accepte actuellement que `nsfw` ; les genres et thèmes vont dans `lore.global` et les tags libres des fiches de Lore.
- `illustration` contient les paramètres **du Livre** : `style`, `negativePrompt`, `coverPrompt`, `size`, `quality`, `count`, `maximumCostUsd`. Les clés API, fournisseurs et modèles restent exclusivement dans les paramètres locaux de l'application.
- Les exclusions visuelles sont des instructions de génération et non une garantie absolue du fournisseur. Les couvertures générées sont recodées pour tenir dans la limite portable de 1 Mio.
- `extensions` doit être un objet vide. `cover` peut être `null` ou un objet `{ "mime": "...", "base64": "..." }` contenant une vraie image PNG/JPEG/WebP.
- Tous les champs des fiches de Lore sont obligatoires dans le JSON, même lorsqu'ils sont vides. Les références sont des identifiants de fiches existantes, jamais des noms.
- Les scénarios et événements définissent un **cadre narratif**, pas des événements déjà survenus. La mémoire dynamique reste propre à chaque Partie.
- Les dates et échanges dans les exports d'exemple sont **fictifs** ; ne pas les utiliser comme métriques de production.
- Les sorties JSON/NDJSON du narrateur ne sont pas prises en charge. Le texte libre sans balise est une narration.
- Le narrateur actuel peut proposer un marqueur `[IMAGE]` ; celui-ci devient un événement `image_intent` sans déclencher de génération payante. Les images enregistrées sont locales à la Partie et ne figurent pas en base64 dans les exports de conversation.
- Le narrateur actuel produit un script théâtral : `*` (didascalie), `@Nom` (réplique) et `---` (ellipse). Ces blocs sont convertis localement en événements de conversation.

## Sources de vérité

- `lib/books/book_definition.dart` et `lib/books/book_lore.dart` : schéma et validation des Livres.
- `lib/chat/chat_exports.dart` : export conversation et diagnostic.
- `lib/chat/theatrical_script_decoder.dart` : décodage du script et de la prose libre.
- `docs/books/format.md` : contrat du Livre.

**Maintenance :** mettre à jour ces exemples et leurs tests lorsqu'un format évolue. Les exports ne sont pas des fichiers à réimporter dans l'application.
