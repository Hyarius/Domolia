# Domolia — Format portable des Livres

## Contrat v3 (Lore, narration et illustration)

Un Livre exporté est un JSON UTF-8 `domolia.book` **version 3**, limité à **2 Mio**. Les anciens formats **v1 et v2 restent importables**. Les anciens Livres sans champ d'illustration reçoivent des réglages artistiques par défaut. Aucun historique de Partie n'entre dans cette définition.

```json
{
  "format": "domolia.book",
  "version": 3,
  "id": "book-123",
  "title": "Le Monde d'ambre",
  "tags": [],
  "cover": null,
  "narrative": {"style": "Narration immersive.", "detailLevel": 3, "illustrationMode": "suggestions"},
  "illustration": {
    "size": "1024x1536",
    "quality": null,
    "count": 1,
    "style": "Aquarelle sombre, lumière diffuse",
    "negativePrompt": "texte, sous-titres, bulles, filigranes, signatures",
    "coverPrompt": "Une tour d'ambre émergeant de la brume",
    "maximumCostUsd": null
  },
  "openingMessages": ["Une porte s'ouvre."],
  "extensions": {},
  "lore": {
    "global": {
      "universe": "Ambre", "overview": "Un empire divisé.",
      "genre": "Fantastique", "era": "Âge des rois",
      "initialContext": "Le couronnement approche.",
      "history": "", "rules": "", "conflicts": "",
      "directions": "", "secrets": ""
    },
    "characters": [], "places": [], "scenarios": [], "events": []
  }
}
```

### Types et références

Tous les éléments ont un identifiant stable ASCII (`id`), un nom (`name`), une description, des alias, des tags et des secrets. Les listes de références portent **des IDs**, jamais des noms :

- Personnage : `appearance`, `personality`, `background`, `role`, `motivations`, `values`, `relatedCharacterIds`, `homePlaceId`.
- Lieu : `type`, `atmosphere`, `history`, `features`, `characterIds`, `placeIds`.
- Scénario : `summary`, `importance` (`main` / `secondary`), `initialContext`, `objectives`, `introduction`, `characterIds`, `placeIds`, `eventIds`.
- Événement : `trigger` (`planned`, `conditional`, `optional`), `condition`, `mandatory` (booléen), `timing`, `consequences`, `priority` (0–10), `characterIds`, `placeIds`, `scenarioIds`.

Les données de Lore sont strictement typées : aucun champ inconnu, aucun ID en double ou lien vers une fiche inexistante n'est accepté. Chaque section comporte au plus **250 fiches** ; le Lore encodé est plafonné à **1,5 Mio**. Le format v1 conserve ses limites : couverture décodée de 1 Mio, style jusqu'à 8 000 caractères, 1 à 30 ouvertures de 1 à 2 000 caractères. Les textes de Lore sont limités à 12 000 caractères par champ long. Les alias et tags sont limités et validés.

La suppression d'une fiche référencée nécessite confirmation et détache les liens dans une opération de sauvegarde unique. Un échec laisse l'ancienne définition intacte. Des modifications dans une Partie ne modifient jamais le canon du Livre.

### Paramètres artistiques et génération des couvertures

Le bloc portable `illustration` décrit **les choix propres au Livre**, et non une connexion API : `style` (1 à 160 caractères), `negativePrompt` (0 à 1 500 caractères), `coverPrompt` (1 à 2 000 caractères, éditable avant chaque génération de couverture), `size` (format admis par Domolia), `quality` (optionnelle), `count` (1 à 4) et `maximumCostUsd` (optionnel). Un plafond strict sans prix garanti bloque la génération. Certains formats ou qualités peuvent être incompatibles avec le modèle sélectionné ; Domolia vérifie cette compatibilité avant l'appel payant.

Les informations de fournisseur, modèle, metteur en scène IA et clé sont **locales**, dans les paramètres graphiques de l'application (surcharge éventuelle par Partie pour les connexions). Elles ne se trouvent ni dans le Livre exporté ni dans le Lore.

Une demande `[IMAGE]` produit un `image_intent` dans la Partie. La génération ne démarre qu'après confirmation explicite. Le prompt final associe une scène attestée et les choix artistiques du Livre. Le *negative prompt* est incorporé sous forme d'instructions d'exclusion pour les API n'offrant pas de champ dédié, sans garantie absolue de suppression des éléments.

L'éditeur du Livre permet aussi de **générer une couverture** avec la connexion graphique configurée. Cette opération est séparée de la Partie, facturable et confirmée avant l'envoi ; elle ne reçoit que les informations publiques de présentation du Lore, jamais ses secrets. L'image résultante est compressée localement sous la limite de **1 Mio** de la couverture portable, puis intégrée au champ `cover` en PNG/JPEG/WebP. Les illustrations de Partie restent stockées séparément ; leurs binaires ne sont pas exportés avec le Livre.

### Intégration RAW et budget

La première passe du narrateur reçoit le Lore. **Le JSONificateur n'en reçoit aucune instruction**. Le sélecteur déterministe travaille avec un budget distinct (par défaut **8 000 caractères UTF-16**). Ordre de sélection :

1. Directives de confidentialité et de souveraineté du joueur.
2. Lore global canonique : faits, contexte, règles, intentions séparées, secrets du narrateur.
3. Personnages et lieux explicitement reconnus dans les derniers tours (nom/alias, comparaison insensible aux accents) ; une fiche retenue est transmise entière.
4. Scénarios principaux, scénarios mentionnés ou liés à ces fiches.
5. Événements mentionnés ou liés (priorité décroissante).

Les fiches secondaires sont omises entièrement si le budget est insuffisant, avec indication explicite ou rejet clair si cet avertissement ne tient pas. **Les faits globaux et les fiches mentionnées ne sont pas tronqués** : un budget insuffisant provoque une erreur explicite, jamais une version amputée présentée comme complète. L'identification d'un mot n'établit jamais qu'une condition s'est produite. Les événements conditionnels sont présentés comme des possibilités non validées. L'IA doit toujours respecter les secrets et la liberté du joueur ; aucun moteur de progression ne prétend garantir un événement obligatoire.

### Persistance, compatibilité et confidentialité

SQLite utilise le schéma **v14** et conserve le JSON portable dans `books.definition_json`. Les définitions v1/v2 sont migrées à la lecture/export en v3 ; les colonnes du Livre ne nécessitent pas de migration dédiée. La migration SQLite v14 ajoute le `negative_prompt` appliqué aux générations d'images, sans toucher au contenu narratif des Parties.

L'export n'inclut jamais clé API, OAuth, profils IA, `profile_id`, diagnostics, échanges techniques, mémoires ou Parties. Les profils AI restent une liaison **locale**, non portée par le Livre. Une collision d'ID de Livre lors d'un import génère un nouvel ID sans écraser l'existant. Les versions futures inconnues sont rejetées.

**Séparation des données :** le Livre contient le canon et les paramètres artistiques, la Partie contient les intentions et ses images locales, tandis que la configuration et les secrets API restent dans l'appareil.
