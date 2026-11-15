# Domolia Web — feuille de route

## But et périmètre

Une seule application Flutter utilisable sur Android et dans Firefox/Chrome/Edge sur PC, sans installation. Les fichiers statiques sont publiés à https://hyarius.github.io/Domolia/ et les données utilisateur restent **locales au navigateur**. Il n'y a ni backend personnel, ni compte requis, ni synchronisation implicite.

Cette feuille de route Web (PR01–PR06) est indépendante de docs/rp/PR01.md–PR17.md. Les numéros sont **logiques** et non des numéros de Pull Requests GitHub.

**Références d'audit (15 novembre 2026)** : branche main au commit 53dd2d68a6e164c43819acbad3a7c1e33eaf37d3 ; PR GitHub #7 ouverte, non fusionnée, sur impl/app-logging (commit a9203bb56ed6def871edc9000a966d5d53f16824). Ne jamais intégrer implicitement les fonctionnalités de cette PR dans la base : après sa fusion, réauditer les migrations SQLite v3, logs, couvertures et paramètres IA de Partie avant PR02/PR03.

## Décisions initiales

1. **Même métier** : conserver BookDefinition, BookSession, BookStore, AiChatProvider, contrôleurs et widgets. Introduire des adaptateurs aux frontières de plateforme, pas une seconde application.
2. **Stockage Web** : expérimenter en priorité sqflite_common_ffi_web (SQLite WASM + IndexedDB), compatible avec l'API sqflite existante. Ne valider le choix qu'après tests réels de fermeture/réouverture, migration et concurrence multi-onglets sur navigateurs cibles.
3. **Sauvegarde obligatoire** : format domolia.backup v1, JSON portable et versionné, couvertures intégrées, import fusion/remplacement. Aucune clé API, jeton OAuth ou trace sensible automatiquement incluse.
4. **Identifiants IA** : distinguer les métadonnées exportables des secrets protégés. Reconfiguration nécessaire si secret absent à la restauration.
5. **Données navigateur** : demander la persistance quand possible, expliquer les suppressions par le navigateur et proposer téléchargement/restauration. La persistance n'est pas une sauvegarde.
6. **IA Web** : chaque fournisseur et le streaming exigent tests CORS/HTTP réels sans clé embarquée ; OAuth ChatGPT loopback Android incompatible par défaut et non annoncé comme disponible.
7. **Publication** : les PR vérifient le Web, mais seule la branche de publication approuvée déploie GitHub Pages. Aucune modification de la livraison APK Android.

Voir [architecture et inventaire](architecture.md), [format de sauvegarde](backup-format.md), [compatibilité IA](ai-compatibility.md) et [matrice de validation](validation.md).

## Découpage des PR

| Document | Livrable | Prérequis et condition de sortie |
| --- | --- | --- |
| [PR01](PR01.md) | Audit, choix et risques, roadmap, tests de contrat existant | Documentation vérifiée sur main et PR #7 ; pas de publication |
| [PR02](PR02.md) | SQLite Web/IndexedDB, démarrage multiplateforme, persistance | PR01 ; redémarrage + migrations + multi-onglets réellement testés |
| [PR03](PR03.md) | Sauvegarde/restauration Android ↔ Web et écran commun | PR02 ; fichier portable, import atomique, collisions, tests croisés |
| [PR04](PR04.md) | Services Web et connexions IA par capacité | PR02 ; PR03 si nécessité de migrations des profils ; aucune connexion non vérifiée |
| [PR05](PR05.md) | UI bureau responsive, logs, navigation, sauvegardes | PR02–PR04 ; tests d'utilisation souris/clavier + Android |
| [PR06](PR06.md) | CI Web, GitHub Pages, gestion du cache et doc d'usage | PR02–PR05 ; validation post-publication et zéro régression Android |

## Règles transversales

- Une branche et une Pull Request par étape. **Aucune fusion sans autorisation explicite**.
- Aucune clé API ni secret dans le dépôt, le build Web, les logs ou les archives par défaut.
- Aucune écriture dans GitHub Pages : données conservées dans le navigateur uniquement.
- Favoriser les tests de navigateur et les vrais périphériques. Une compilation ne prouve pas la persistance.
- Conserver la CI et la compatibilité Android. Toute migration doit préserver les bases existantes.
- Lorsqu'une API du navigateur rend une fonctionnalité impossible, afficher une indisponibilité compréhensible au lieu de prétendre qu'elle fonctionne.
- Chaque PR documente les tests réellement exécutés, les limites et les blocages. Ne pas modifier la cible GitHub Pages sans décision explicite.
