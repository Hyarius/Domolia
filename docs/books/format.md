# Domolia — Format portable des Livres

> Modèles JSON complets et vérifiés : [`template/livre_template.json`](../../template/livre_template.json) (import direct) et [`template/README.md`](../../template/README.md) (autres formats).

## Contrat v2 (Lore canonique)

Un Livre exporté est un JSON UTF-8 `domolia.book` **version 2**, limité à **2 Mio**. Les anciens fichiers **v1 restent importables** et deviennent v2 à la prochaine sauvegarde, avec un Lore vide. Aucun historique de Partie n'entre dans cette définition.

```json
{
  "format": "domolia.book",
  "version": 2,
  "id": "book-123",
  "title": "Le Monde d'ambre",
  "tags": [],
  "cover": null,
  "narrative": {"style": "Narration immersive.", "detailLevel": 3},
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

### Intégration RAW et budget

La première passe du narrateur reçoit le Lore. **Le JSONificateur n'en reçoit aucune instruction**. Le sélecteur déterministe travaille avec un budget distinct (par défaut **8 000 caractères UTF-16**). Ordre de sélection :

1. Directives de confidentialité et de souveraineté du joueur.
2. Lore global canonique : faits, contexte, règles, intentions séparées, secrets du narrateur.
3. Personnages et lieux explicitement reconnus dans les derniers tours (nom/alias, comparaison insensible aux accents) ; une fiche retenue est transmise entière.
4. Scénarios principaux, scénarios mentionnés ou liés à ces fiches.
5. Événements mentionnés ou liés (priorité décroissante).

Les fiches secondaires sont omises entièrement si le budget est insuffisant, avec indication explicite ou rejet clair si cet avertissement ne tient pas. **Les faits globaux et les fiches mentionnées ne sont pas tronqués** : un budget insuffisant provoque une erreur explicite, jamais une version amputée présentée comme complète. L'identification d'un mot n'établit jamais qu'une condition s'est produite. Les événements conditionnels sont présentés comme des possibilités non validées. L'IA doit toujours respecter les secrets et la liberté du joueur ; aucun moteur de progression ne prétend garantir un événement obligatoire.

### Persistance, compatibilité et confidentialité

SQLite conserve le schéma **v4** ; la colonne `books.definition_json` contient désormais du JSON v2. Une migration des tables n'est pas nécessaire : les anciennes définitions v1 sont interprétées sans perte et réécrites au format v2 lors de leur édition. Les tables `sessions`, `book_bindings` et `raw_generations` restent indépendantes.

L'export n'inclut jamais clé API, OAuth, profils IA, `profile_id`, diagnostics, échanges techniques, mémoires ou Parties. Les profils AI restent une liaison **locale**, non portée par le Livre. Une collision d'ID de Livre lors d'un import génère un nouvel ID sans écraser l'existant. Les versions futures inconnues sont rejetées.

**Évolution ultérieure :** conserver la définition canonique immuable dans le Livre et référencer ses IDs dans la mémoire dynamique propre à chaque Partie. Les découvertes, déplacements, relations et événements effectivement réalisés nécessiteront un état de progression explicite, non disponible dans cette PR.
