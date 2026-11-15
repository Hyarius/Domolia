# OpenUncensored — Architecture des crédits et des clés

Mise à jour : 15 novembre 2026. Références : https://openuncensored.com/docs ,
https://openuncensored.com/agents.md et https://openuncensored.com/terms .

## Ordre de livraison (décision)

**Fusionner cette PR OpenUncensored en premier, après approbation explicite.**
La branche `impl/android/11-hybrid-ai-tool-calling` doit ensuite être
actualisée à partir de `main` (rebase ou merge avec résolution des conflits),
puis adaptée au fournisseur et aux modèles gérés par cette PR. Ne pas tenter
de fusionner le tool calling avant cette PR.

Fichiers communs identifiés : `lib/ai/ai_controller.dart` et `lib/main.dart`.
La future branche tool calling doit se conformer aux nouveaux identifiants
de profils gérés et à la source de vérité du catalogue, pas réinstaller un
sélecteur de fournisseurs ou écraser les clés. La présence de cette PR ne
signifie pas que le tool calling est déjà actif : il reste désactivé tant
que l'autre chantier n'est pas intégré.

## Architecture

- `openuncensored_api.dart` : client HTTP testable et isolé, retours
  validés, erreurs assainies ; aucun vrai achat dans les tests.
- `openuncensored_vault.dart` : coffre `flutter_secure_storage` avec
  historique de clés, solde consulté, modèle choisi et paiement reprenable.
- `openuncensored_controller.dart` : validation de clé par consultation
  des crédits, états de paiement, migration non destructive, activation et
  sélection par tâche.
- `openuncensored_credits_page.dart` : paramètres natifs, page solde,
  liste `Mes clés`, sélection de montant, Stripe externe, récupération
  et réactivation d'une clé antérieure.
- `AiConnectionController.configureOpenUncensored` : trois profils de tâche
  persistés sous des identifiants stables ; aucun profil historique supprimé.

## Historique des clés (par appareil)

Une entrée comprend l'empreinte locale, le secret complet dans le coffre,
le nom modifiable, la date d'ajout, le solde USD de dernière vérification et
l'heure de cette vérification. Plusieurs clés peuvent coexister. Le solde
appartient exclusivement à sa clé et n'est pas transféré. Un changement de
clé ne supprime jamais l'historique. Chaque carte permet d'actualiser, de
renommer, d'afficher volontairement, de réactiver et de recharger sa clé.

Les historiques ne sont pas synchronisés entre appareils et ne peuvent
être reconstitués depuis OpenUncensored si une clé est définitivement perdue.
Les exports JSON des Livres et Parties ne contiennent pas ce coffre.

## Paiement

1. Choisir 5, 10, 25 ou 50 USD, en centimes (montant permis 500–100000).
2. Demander un checkout OpenUncensored ; préciser la clé cible **uniquement**
   pour une recharge et identifier celle-ci indépendamment de la clé active.
3. Enregistrer en stockage sécurisé le session ID, claim token, URL Stripe
   et la clé cible **avant** d'ouvrir le navigateur externe.
4. Polling limité à l'écran actif, cinq secondes entre essais, jusqu'à
   clôture, expiration ou abandon explicite ; reprendre après redémarrage.
5. Nouveau paiement confirmé : récupérer la clé retournée une seule fois,
   la conserver durablement puis activer ses profils narratifs.
6. Recharge confirmée : actualiser uniquement le solde de la clé ciblée.

Une erreur d'écriture ne doit pas être présentée comme un succès. Si une
clé à usage unique vient d'être retournée mais que le coffre est
indisponible, une copie de secours, explicite et temporaire en mémoire
vive, doit permettre à l'utilisateur de la conserver avant fermeture.

Le prix définitif et les taxes sont déterminés par Stripe. Aucun formulaire
de carte bancaire n'est intégré à Domolia.

## Compatibilité et limites

- **Android** : stockage protégé par Keystore via flutter_secure_storage,
  ouverture de Stripe dans l'application de navigation par défaut.
- **Web** : le paiement intégré est explicitement désactivé tant que CORS
  et le retour sécurisé ne sont pas vérifiés ; la sécurité du stockage
  navigateur ne doit pas être assimilée à celle d'Android. La politique
  CORS du routeur est restreinte par défaut à localhost.
- **Anciennes installations** : importer les clés OpenUncensored des profils
  existants sans effacer ni renommer ces profils ; les Livres, Parties et
  leurs identifiants antérieurs restent en place. Une ancienne référence
  vers un fournisseur non pris en charge nécessite une sélection manuelle.
- **Tool calling** : un modèle sélectionné manuellement comme narrateur
  doit être déclaré capable ; une simple correspondance du nom ne suffit
  pas. La source définitive des capacités viendra du chantier tool calling.
- **Statut des modèles** : tarifs, disponibilités et métriques peuvent
  varier. L'optimiseur de Lore est optionnel dans le preset Économique.

## Validation / contraintes de fusion

- CI GitHub : `flutter analyze`, `flutter test`, build Android.
- Aucun secret réel et aucun paiement réel dans les tests.
- Tester reprise après fermeture, recharge de clé non active, migration des
  profils anciens, noms/masquage/soldes des clés historiques.
- Cette PR est à fusionner **avant** la branche tool calling ; relancer
  l'ensemble des tests **après** intégration de celle-ci.

## Simulation des paiements dans les préversions

Les APK `--debug` et les APK de prévisualisation de branche (non `main`) construits
par GitHub Actions activent `DOMOLIA_PAYMENT_SANDBOX=true`. Le canal `dev-latest`
et les tags de production ne l'activent jamais. Dans « Crédits IA », ouvrir
« Tester les paiements sans payer » : la page de simulation offre les états
réussi, refusé et expiré, la création de clés `ou-demo-`, la recharge et
l'historique. **Aucun appel HTTP ni ouverture Stripe n'a lieu dans le
simulateur** ; les modèles et les connexions IA y sont fictifs. L'historique
simulé est stocké dans une entrée chiffrée distincte des vraies clés
(`domolia.openuncensored.sandbox.v1`). Les clés de simulation ne peuvent
pas générer de texte et ne fonctionnent pas chez OpenUncensored.

L'absence de vraie transaction ne prouve pas que Stripe et OpenUncensored
fonctionnent en production. Les tests automatisés vérifient les transitions
et la persistance fictives, jamais un prélèvement réel.

## Espacements UI

Les formulaires actifs utilisent les constantes `DomoliaSpacing` :
`compact=12`, `field=16`, `section=24` points logiques. Les champs des
budgets, des livres, du lore et des réglages ont des séparations cohérentes.

L'harmonisation est étendue aux pages actives : paramètres généraux,
éditeur de Livre, bibliothèque, Lore, conversation, gestion des crédits,
configuration IA historique, journal et mises à jour. Les espaces sont
appliqués entre les groupes et les champs sans agrandir la zone de saisie
du chat ni les contrôles de navigation compacte.
