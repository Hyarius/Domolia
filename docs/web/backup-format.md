# Contrat de sauvegarde Domolia v1 — proposition PR01 pour PR03

## Choix

Proposer un **JSON UTF-8** unique avec extension `.domolia`. Les Livres ont déjà un format JSON versionné avec couverture base64, et la chronologie d'une Partie est elle aussi représentable en JSON. Ce choix est plus simple à migrer, inspecter et valider qu'une archive ZIP tant que les limites de taille sont raisonnables.

Exemple de nom : `Domolia-backup-2026-11-15.domolia` ; type `application/json`. Ce document décrit le **contrat à implémenter en PR03**, pas un export déjà disponible.

## Enveloppe illustrative

```json
{
  "format": "domolia.backup",
  "version": 1,
  "createdAtUtc": "2026-11-15T07:00:00Z",
  "books": [
    {
      "format": "domolia.book",
      "version": 1,
      "id": "book-example",
      "title": "Une aventure",
      "tags": [],
      "cover": null,
      "narrative": {"style": "Raconte l'histoire.", "detailLevel": 3},
      "openingMessages": ["Il était une fois…"],
      "extensions": {}
    }
  ],
  "sessions": [
    {
      "id": "session-example",
      "bookId": "book-example",
      "title": "Partie 1",
      "updatedAtUtc": "2026-11-15T07:00:00Z",
      "aiProfileId": "profile-example",
      "timeline": [
        {"id": 0, "type": "message", "speaker": "player", "name": "Vous", "text": "Bonjour"},
        {"id": 1, "type": "scene_change"}
      ]
    }
  ],
  "bookBindings": [
    {"bookId": "book-example", "aiProfileId": "profile-example"}
  ],
  "aiProfiles": [
    {
      "id": "profile-example",
      "name": "Mon fournisseur",
      "providerType": "customAi",
      "baseUrl": "https://example.invalid/v1",
      "model": "model-example",
      "nsfwCompatibility": "unknown"
    }
  ],
  "preferences": {}
}
```

Les valeurs sont fictives et ne constituent pas une sauvegarde valide produite par l'application aujourd'hui. La présence de `sessions.aiProfileId` suppose la fusion de la PR #7 ; sinon le champ doit être traité explicitement par le premier implémenteur et ne jamais être perdu à la migration.

## Inclusion et exclusions

**Inclure** : toutes les définitions de Livres et couvertures ; Parties avec chronologie complète dans l'ordre, séparateurs de scène et horodatage de classement ; liaisons Livre/Partie → ID de profil IA ; métadonnées non sensibles des profils (nom, type, URL, modèle, compatibilité) ; liste blanche documentée de préférences utiles. Un profil référencé doit être présent comme métadonnées ou apparaître clairement comme non résolu à l'import.

**Exclure par défaut** : clés API, mots de passe, access/refresh/ID tokens, cookies, identifiants OAuth, données du Keystore, journaux JSONL, diagnostics HTTP contenant requêtes/réponses brutes, chemins locaux et fichiers temporaires. Les exports de diagnostics restent séparés. Afficher au téléchargement : « Les connexions IA peuvent nécessiter une nouvelle authentification ».

Les `book_bindings`, `aiProfiles` et `preferences` n'ont pas actuellement de méthode d'export collectif dédiée : les API devront être ajoutées sans exposer les secrets. `updatedAtUtc` nécessite de remonter la colonne `sessions.updated_at` actuelle à un DTO portable.

## Validation avant modification

- Vérifier le type et les clés de l'enveloppe, version exacte acceptée, unicité des IDs, contraintes de titres/texte/médias et relations.
- Passer chaque Livre dans `BookDefinition.importJson` ou l'équivalent strict sans contourner sa validation ; ne jamais accepter un chemin de fichier ou une URL comme image à la place des octets.
- Valider la chronologie avec `BookSession.decodeTimeline` ; empêcher les doublons d'IDs d'événements et les relations Partie → Livre absentes.
- Contrôler les références aux profils, l'allowlist des préférences et rejeter les champs de secrets/diagnostics dans les emplacements réservés aux métadonnées.
- Définir des bornes concrètes en PR03 (proposition de départ : taille totale ≤100 Mio, ≤1 Mio par couverture conforme au format Livre actuel), testées sur Android et Web. Des exports plus grands peuvent justifier ZIP dans une **version future** du format.
- Ne pas prétendre que le fichier est confidentiel : il est lisible et contient le texte des conversations. Une somme SHA-256 peut détecter une corruption accidentelle, **pas** authentifier l'émetteur.

## Restaurer sans perdre les données actuelles

1. Lire le fichier choisi, analyser l'intégralité, valider les bornes et calculer le plan de restauration **sans écriture**.
2. Afficher le nombre de Livres et de Parties, le traitement des profils IA, les conflits et les deux choix : **Fusionner** ou **Remplacer**.
3. Fusion : si un ID correspond à une entrée identique, ne pas dupliquer ; si contenu différent, attribuer un nouvel ID stable, remapper tous les enfants et bindings, et ne jamais associer automatiquement un nouvel objet à des secrets appartenant à un autre profil.
4. Remplacement : demander confirmation forte ; ne remplacer que les données utilisateur visées par l'archive. Conserver les secrets protégés non concernés ; ne jamais effacer la bibliothèque en préambule d'une importation potentiellement invalide.
5. Faire les changements SQLite dans **une seule transaction**. Pour les préférences et métadonnées de profils stockées ailleurs, concevoir un journal de restauration/staging avec reprise ou compensation testée : l'ensemble doit rester cohérent après crash ou quota dépassé.
6. N'actualiser l'interface qu'après commit réussi ; en cas d'échec, conserver l'état antérieur et afficher l'erreur sans divulguer de secrets.
7. Remonter les liaisons IA absentes ou ambiguës dans l'interface pour reconfiguration.

Ne pas réutiliser directement `exportConversation` (format `domolia-conversation-v1`, export partiel possible) ni l'export de Livre `domolia.book` (ne contient pas les Parties) comme sauvegarde complète.

## Compatibilité et tests PR03

- Même corpus golden JSON sur Android, navigateur Web et tests Dart VM.
- Android→Web, Web→Android, Firefox→Chrome/Edge, changement de PC et version ancienne compatible.
- Base vide, fusion idempotente, collisions Livre/Partie/profil, chronologies complexes, couvertures, fichier tronqué ou malformé, quota et interruption lors du commit.
- Vérifier les non-régressions : aucune clé/jeton dans l'archive, aucune perte de données sur erreur, même ordre de conversations après import.
