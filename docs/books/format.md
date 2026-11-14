# Domolia — Format portable des Livres

## Contrat v1

Un export de Livre est un fichier UTF-8 JSON, objet racine unique, de **2 Mio maximum**. `format` vaut `domolia.book` et `version` vaut `1`. Une version inconnue est rejetée, pas interprétée approximativement.

```json
{
  "format": "domolia.book",
  "version": 1,
  "id": "book-123",
  "title": "Le Monde d'ambre",
  "tags": [],
  "cover": null,
  "narrative": {
    "style": "Narration immersive en français.",
    "detailLevel": 3
  },
  "openingMessages": ["Une porte s'ouvre."],
  "extensions": {}
}
```

- `id` : identifiant stable de 1 à 100 caractères ASCII alphanumériques, underscore ou tiret ; une collision à l'import génère un nouvel ID local, sans écrasement.
- `title` : 1 à 120 caractères. `tags` : liste d'identifiants connus, actuellement `nsfw` uniquement et désactivé par défaut.
- `cover` : `null`, ou `{"mime":"image/png|image/jpeg|image/webp","base64":"..."}`. Taille décodée 1 Mio maximum ; type MIME et signature de fichier doivent correspondre.
- `narrative.style` : 1 à 8 000 caractères ; `detailLevel` : entier de 1 à 5.
- `openingMessages` : 1 à 30 entrées de 1 à 2 000 caractères.
- `extensions` : **objet vide obligatoire en v1**. Les scénarios et personnages de PR07 exigeront des champs explicitement validés et une évolution de version.

L'import refuse les champs inconnus, types incorrects, couvertures trop grandes ou mal identifiées, extensions non prises en charge et documents hors limites. Aucun code du JSON n'est exécuté.

## Frontières de confidentialité

L'export contient uniquement la définition partageable. Il n'inclut jamais clé API, jeton OAuth, compte ChatGPT, liaison locale `profile_id`, historique de conversations, scènes personnelles, progression, fiches du joueur, mémoire de Partie ou identifiant de session.

Les liaisons IA sont stockées séparément dans SQLite local et font référence à des configurations existantes du stockage chiffré. Un import ne crée **aucune** liaison à une IA. La personne qui importe choisit son propre profil.

## Versionnement et migrations

- SQLite local : `user_version = 1` ; les tables `books`, `book_bindings` et `sessions` sont distinctes. Toute modification du schéma passera par une migration non destructive dans `onUpgrade`.
- JSON portable : `version = 1`. Toute évolution de schéma partagé exige un parseur et un validateur explicites, des tests v1→vN et un contrat de compatibilité documenté.
- Configuration globale du narrateur PR04 : reste lisible pour migration volontaire vers le Livre `legacy-narrator-v1`. La création est idempotente, l'original n'est pas supprimé.
- Les configurations IA existantes et leurs secrets ne font pas l'objet d'une migration non chiffrée.
