# Stratégie de validation Android / Web

**PR01 : état des essais** — audit statique effectué, tests de contrat ajoutés ; pas de SDK Flutter/Dart installé dans l'environnement de préparation, donc aucune exécution locale de `flutter test`, `flutter analyze` ou compilation Web. Seuls des workflows GitHub peuvent fournir ensuite leur résultat effectif. Ne pas marquer un navigateur testé sans l'avoir lancé.

## Garde-fous automatisés par PR

- `flutter analyze` et `flutter test` (tests unitaires/Widget actuels Android sans appel IA payant) restent obligatoires.
- `test/portable_data_contract_test.dart` verrouille le roundtrip JSON d'un Livre avec couverture, la chronologie d'une Partie et le rejet d'IDs de messages incohérents.
- PR02 ajoute des tests SQLite réels de migration v1/v2/v3, réouverture, persistance couverture/Partie, conflits entre écritures, perte de quota et fallback worker.
- PR03 ajoute corpus de sauvegardes Android/Web, fusions idempotentes, collisions, remplacement atomique, fichier malformé, perte de courant simulée et aucun secret.
- PR04 ajoute validations de transports en mocks et essais CORS/SSE manuels tracés par fournisseur.
- PR05 ajoute tests de widgets à largeur écran et scénarios souris/clavier.
- PR06 ajoute `flutter build web --base-href /Domolia/`, vérification HTTP du déploiement Pages et cycle de cache/mises à jour.

## Matrice de validation manuelle — ne renseigner qu'après exécution

| Cas | Firefox PC | Chrome PC | Edge PC | Android |
| --- | --- | --- | --- | --- |
| Créer un Livre et une couverture ; recharger | À faire PR02 | À faire PR02 | À faire PR02 | Re-vérifier |
| Partie, messages et scène ; fermer et réouvrir le navigateur | À faire PR02 | À faire PR02 | À faire PR02 | Re-vérifier |
| Deux onglets en écriture / migrations | À faire PR02 | À faire PR02 | À faire PR02 | N/A |
| Sauvegarder / charger / fusionner / remplacer | À faire PR03 | À faire PR03 | À faire PR03 | À faire PR03 |
| API compatible ; liste de modèles et SSE | À faire PR04 | À faire PR04 | À faire PR04 | Re-vérifier |
| Logs, import/export couvertures, menus contextuels | À faire PR05 | À faire PR05 | À faire PR05 | Re-vérifier |
| Publication Pages, mise à jour Web et conservation de données | À faire PR06 | À faire PR06 | À faire PR06 | Sans objet |

## Scénarios de défaillance prioritaires

- Stockage navigateur désactivé, quota atteint, mode privé, suppression des données du site ; erreur compréhensible, aucune réussite fictive.
- Fichier de sauvegarde malformé ou invalide, couverture piégée, collision de profils, sauvegarde ancienne.
- PR #7 fusionnée entre deux étapes : migration v2→v3 et export de `sessions.profile_id`.
- Fichiers `sqlite3.wasm` et `sqflite_sw.js` mal servis après déploiement sous `/Domolia/`.
- Version Web mise à jour pendant une conversation ou une restauration ; afficher erreur et ne pas perdre les écritures déjà confirmées.

L'étape Web n'est pas acceptée uniquement parce que `flutter build web` termine avec le code 0.
