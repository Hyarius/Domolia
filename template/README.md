# Templates de formats Domolia

Ce dossier contient des **exemples conformes aux formats actuellement utilisés** par Domolia, sans données privées.

| Fichier | Usage | Importable ? |
| --- | --- | --- |
| `livre_template.json` | Définition portable d'un Livre v2 avec Lore et références | **Oui**, via Livres → Importer JSON |
| `conversation_template.json` | Exemple d'export de conversation | **Non** : format d'export, pas de fonction d'import |
| `diagnostic_ia_template.json` | Exemple d'export de diagnostic IA | **Non** : format d'export, pas de fonction d'import |
| `narrateur_theatral_template.txt` | Sortie courante du narrateur : didascalies et répliques balisées | **Non** : sortie textuelle du modèle |
| `narrateur_streaming_template.ndjson` | Ancien protocole, reconnu pour compatibilité | **Non** : exemple historique |

## Règles importantes

- Le format de Livre est `domolia.book` v2. Le champ `tags` au niveau du Livre n'accepte actuellement que `nsfw` ; les genres et thèmes vont dans `lore.global` et les tags libres des fiches de Lore.
- `extensions` doit être un objet vide. `cover` peut être `null` ou un objet `{ "mime": "...", "base64": "..." }` contenant une vraie image PNG/JPEG/WebP.
- Tous les champs des fiches de Lore sont obligatoires dans le JSON, même lorsqu'ils sont vides. Les références sont des identifiants de fiches existantes, jamais des noms.
- Les scénarios et événements définissent un **cadre narratif**, pas des événements déjà survenus. La mémoire dynamique reste propre à chaque Partie.
- Les dates et échanges dans les exports d'exemple sont **fictifs** ; ne pas les utiliser comme métriques de production.
- Le narrateur actuel produit un script théâtral : `[NARRATION]`, `[PERSONNAGE:Nom]` et `[SCENE]`. Ces blocs sont convertis localement en événements de conversation.
- Le décodeur accepte encore le NDJSON historique, mais aucune sortie n'est autorisée à écrire un message `player` ou `[JOUEUR]`.

## Sources de vérité

- `lib/books/book_definition.dart` et `lib/books/book_lore.dart` : schéma et validation des Livres.
- `lib/chat/chat_exports.dart` : export conversation et diagnostic.
- `lib/chat/theatrical_script_decoder.dart` : décodage du script, de la prose et du NDJSON historique.
- `docs/books/format.md` : contrat du Livre.

**Maintenance :** mettre à jour ces exemples et leurs tests lorsqu'un format évolue. Les exports ne sont pas des fichiers à réimporter dans l'application.
