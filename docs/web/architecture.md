# Audit d'architecture — 15 novembre 2026

**État audité** : Hyarius/Domolia main, commit 53dd2d68a6e164c43819acbad3a7c1e33eaf37d3 ; impl/app-logging, PR #7 ouverte et non fusionnée, commit a9203bb56ed6def871edc9000a966d5d53f16824. Analyse statique du dépôt et de la documentation des dépendances ; aucun binaire Flutter Web n'a encore été lancé.

## Inventaire et compatibilité

| Composant réel | Situation observée | Adaptation proposée |
| --- | --- | --- |
| `pubspec.yaml` | Flutter/Dart, `sqflite ^2.4.2`, `path_provider`, `file_picker`, `flutter_secure_storage`, `http`, `shared_preferences` | Conserver si pris en charge sur Web ; examiner les versions résolues et générer le projet `web/` |
| `lib/books/book_store.dart` | `BookStore` abstrait ; `SqliteBookStore` avec `DatabaseFactory` injectable, fichier créé via `getApplicationSupportDirectory()`. Schéma SQLite **v2** sur main | Utiliser la même implémentation SQLite avec une factory Web ; le chemin de base doit être relatif dans la version navigateur |
| `BookDefinition` | JSON `domolia.book` v1 avec couverture PNG/JPEG/WebP base64, validation taille ≤1 Mio | Conserver ce DTO pour les sauvegardes, éviter les URI de fichiers dans la base |
| `BookSession` | ID de Partie, ID de Livre, titre, chronologie sérialisée de messages et changements de scène | Garder les IDs et le format, ajouter un accès portable aux métadonnées d'ordre (actuellement `updated_at` n'est pas exposé par le DTO) |
| `book_bindings` | Référence ID de profil IA, sans clé | Exporter la relation sans exporter le secret du profil |
| `lib/ai/ai_storage.dart` | `SecureAiProfileStore` stocke **ensemble** nom, modèle, fournisseur, clé dans `flutter_secure_storage` | Séparer la projection exportable des secrets ; attention : WebCrypto/LocalStorage n'égale pas Android Keystore |
| `lib/ai/chatgpt_auth.dart` | `dart:io`, `HttpServer.bind(127.0.0.1, 0)`, redirection OAuth locale | Isoler par import conditionnel ; indisponible sur Web tant qu'un parcours approuvé et testé n'existe pas |
| `lib/ai/ai_provider.dart`, `chatgpt_responses.dart` | Client `package:http`, requêtes HTTPS, SSE/stream | Tester navigateur + CORS + réponses streaming par fournisseur ; aucune garantie par simple compilation |
| `lib/updates/update_io.dart` | `dart:io`, `HttpClient`, `File`, `MethodChannel` et installation APK | Garder exclusivement côté Android ; version Web = rafraîchissement du site, sans installateur APK |
| `lib/books/book_editor_page.dart` et `lib/chat/group_chat_page.dart` | `file_picker` et récupération de fichiers | Utiliser octets récupérés ou téléchargement navigateur, éviter les accès par chemin `dart:io` |
| `lib/chat/narrator_settings.dart`, `ai_diagnostic_settings.dart` | `shared_preferences` | Vérifier implémentation Web et inclure les seules préférences non sensibles utiles dans la sauvegarde |
| `lib/main.dart` | Instancie `SecureAiProfileStore`, `SecureChatGptSessionStore`, `SqliteBookStore`, `createProductionUpdateController` dans `initState` | Extraire une composition de services par plateforme ; ne pas importer directement les services `dart:io` depuis un point d'entrée Web |
| `.github/workflows/android-apk.yml` | `flutter create --platforms=android` dans CI, puis analyse/tests et compilation APK | Ne pas perturber ; ajouter plus tard workflow Web indépendant |

### Évolutions en attente dans la PR #7

- `lib/books/book_store.dart` passe en schéma **v3** et ajoute `sessions.profile_id`.
- `BookSession.aiProfileId` permet un profil IA propre à la Partie, distinct de celui du Livre.
- `lib/logging/app_logger.dart` introduit `AppLogStorage`, mais `FileAppLogStorage` et l'initialisation s'appuient sur `dart:io` et `path_provider` ; prévoir `IndexedDbAppLogStorage` avec rétention ou équivalent.
- `BookCoverLoader` utilise les octets du sélecteur puis un chemin Android de secours ; séparer la lecture du fichier de la validation des octets.
- `ConversationSettingsPage`, export et navigation doivent être intégrés aux tests Web.
- **Correctif couverture déjà dans PR #7** : sur main, `BookDefinition.validate` appelle `ascii.decode` pour tester WebP même lorsqu'une couverture PNG/JPEG a été détectée, ce qui rejette à tort les octets non ASCII. La PR #7 utilise des comparaisons de signatures binaires et résout ce point. Ne pas dupliquer ce fix dans PR01 ; vérifier qu'il est fusionné et ajouter un test PNG/JPEG ciblé en PR02.
- **Important** : vérifier la fusion de la PR #7 juste avant d'appliquer toute migration, et adapter le format de sauvegarde aux données réellement fusionnées.

## Architecture ciblée

```text
UI Flutter commune : Livres, Parties, lecture, configurations, paramètres
       |
Contrôleurs et modèles communs : BookLibraryController, NarrativeChatController,
BookDefinition, BookSession, AiConnectionController, export/import
       |
Interfaces : BookStore, AiProfileStore, ChatGptSessionStore, AppLogStorage,
fichier-import/export, préférences, gestion des mises à jour
       |
Assemblage par plateforme (imports conditionnels ; un seul point de composition)
       |                                   |
Android                                Flutter Web
sqflite + fichier                      sqflite_common_ffi_web + IndexedDB
Keystore/secure storage                 stockage Web explicite + avertissement
I/O de fichiers et APK                  FilePicker bytes / téléchargement
journal JSONL local                     journal local borné
OAuth loopback existant                 fonctionnalité désactivée si non vérifiée
```

Les objets métier, contrôleurs et comportements ne dupliquent pas leur code. Un module Web ne doit pas importer une bibliothèque qui importe `dart:io` transitivement si ce symbole est invoqué à la compilation. Préférer des fichiers conditionnels à des conditions de plateforme dispersées dans les widgets. Les classes de test actuelles injectent déjà des faux fournisseurs ou stores.

## Choix provisoire SQLite Web

**Choix prioritaire à tester pour PR02 : `sqflite_common_ffi_web`**. Le package fournit la même API `sqflite` et une base SQLite WASM persistée dans IndexedDB, avec `sqlite3.wasm` et `sqflite_sw.js` à publier sous la base d'URL de l'application. Cela limite la migration du schéma et conserve les requêtes/transactions. La bibliothèque signale toutefois un statut expérimental.

- Un seul `openDatabase` par base logique. Conserver une instance partagée et l'ouvrir sur le nom relatif stable `domolia_books.sqlite`.
- Tester Firefox, Chrome et Edge : persistance après rechargement, fermeture, redémarrage ; vrai scénario avec deux onglets concurrents. Un worker partagé peut synchroniser les onglets ; dans un navigateur/fallback dépourvu de garantie de verrouillage, interdire explicitement une seconde session en écriture plutôt que risquer une corruption.
- Tester `PRAGMA foreign_keys = ON`, migrations v1→v2 puis v2→v3 si PR #7 fusionnée, mise à jour atomique des Parties, suppressions en cascade, enregistrement des couvertures et quotas.
- Échouer clairement si IndexedDB est indisponible. **Ne pas passer silencieusement à une base uniquement mémoire**, puisque la conservation des histoires est un critère produit.
- Évaluer à nouveau Drift seulement si les essais réels démontrent une incompatibilité bloquante ; son intégration exigerait une adaptation plus large de l'accès aux données.

Sources : https://pub.dev/packages/sqflite ; https://pub.dev/packages/sqflite_common_ffi_web ; https://pub.dev/documentation/sqflite_common_ffi_web/latest/ .

## Provenance, protection et volume des données

- GitHub Pages fournit des fichiers statiques ; aucune donnée utilisateur n'y est transmise par le stockage lui-même. Les requêtes IA envoyées volontairement partent cependant vers les fournisseurs configurés.
- IndexedDB appartient à l'origine `https://hyarius.github.io`, pas à un répertoire particulier : utiliser des noms d'espaces et de bases spécifiques à Domolia et garder en tête les autres projets sur ce même domaine.
- Le navigateur conserve normalement IndexedDB après fermeture, mais peut l'effacer à la demande ou sous pression. Demander `navigator.storage.persist()` si disponible, surveiller les erreurs de quota, informer l'utilisateur et mettre les sauvegardes à portée.
- Le contenu d'une base locale, même chiffrée par WebCrypto, peut être accessible par le code exécuté dans l'origine en cas de script compromis/XSS. Aucun secret embarqué dans la compilation et aucune promesse équivalente à Android Keystore.
- Avant PR06, vérifier le comportement des ressources SQLite avec `--base-href /Domolia/`, les codes HTTP et le type MIME WASM ; tester les mises à jour et la configuration de cache/service worker.

Sources : https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria ; https://developer.mozilla.org/en-US/docs/Web/API/StorageManager/persist ; https://docs.flutter.dev/ui/navigation/url-strategies ; https://docs.flutter.dev/platform-integration/web/faq ; https://pub.dev/packages/flutter_secure_storage .

## Risques et points encore non prouvés

1. Support effectif des Web Workers, intégrité SQLite en multi-onglets et migrations sur les trois navigateurs cibles.
2. Fournisseurs IA réellement accessibles en CORS et streaming SSE sans proxy public.
3. Absence de primitive sécurisée équivalente au Keystore pour les clés saisies côté Web.
4. Restauration atomique de SQLite **et** préférences/profils dans plusieurs stores différents : conception de staging, ordre d'application et stratégie de reprise obligatoire.
5. Passage des Parties à un profil IA propre (PR #7) et conservation des ordres/dates de modification.
6. Caches de déploiement, quotas, navigation multi-onglets, compatibilité des images.
7. Analyse/test Android et compilation Web **non exécutés à cette étape** ; le présent document est un audit statique.

Les risques non résolus sont des critères de test à satisfaire, pas des promesses de fonctionnement.
