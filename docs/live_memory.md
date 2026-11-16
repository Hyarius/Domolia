# Domolia — Live Memory (v1)

## Séparation Livre / Partie

Le Lore statique reste dans `BookDefinition.lore` et son export partageable.
La Live Memory est strictement identifiée par `sessions.id` et stockée dans
SQLite, avec suppression en cascade. Aucune mémoire de Partie n'est ajoutée
aux exports de Livres.

La mémoire ne représente jamais un nouveau canon : une assertion peut être
`confirmed`, `reported` ou `uncertain`. La visibilité `narrator` permet
de conserver des éléments qui ne doivent pas être révélés automatiquement.
Le texte mémorisé est toujours une donnée, jamais une instruction système.

## Tables (SQLite v10)

- `live_memory_turns` : une ligne par `session_id + player_event_id`, avec
  empreinte SHA-256 du RAW validé et liste d'opérations JSON strictes.
- `live_memory_overrides` : correction, protection et suppression (tombstone)
  manuelles, séparées des opérations générées.

Une opération `upsert` ou `retract` porte un identifiant stable,
catégorie, sujet, champ, état de certitude, visibilité, importance, état stable
ou temporaire, ID du tour et citation source exacte.

L'état visible est obtenu en rejouant les opérations dans l'ordre chronologique
puis en superposant les corrections de l'utilisateur. L'historique des opérations
est conservé : un changement de lieu ou l'accomplissement d'une promesse ne
détruit pas l'ancienne information.

## Cycle d'extraction

1. Le contrôleur enregistre le RAW puis la JSONification validée dans une
   transaction.
2. Un service par Partie parcourt les RAW structurés non analysés.
3. Une IA configurée pour la tâche `memory` produit uniquement un tableau
   JSON de modifications. Sans profil dédié, elle réutilise le narrateur.
4. Dart refuse les champs inconnus, les IDs malformés, les citations non
   présentes dans le RAW/message joueur, les types invalides, les doublons et
   les réponses de taille excessive. Ceci ne remplace pas un contrôle
   sémantique parfait : un modèle peut mal interpréter un dialogue. D'où la
   conservation de la certitude et la correction utilisateur.
5. SQLite vérifie une nouvelle fois, **dans la transaction**, l'existence de
   la Partie et l'empreinte du RAW source, avant d'accepter l'opération.
6. Les tours sans extraction aboutie restent candidats au prochain passage.

En cas de réécriture de la chronologie, la transaction du snapshot supprime les
opérations rattachées à un RAW disparu ou modifié, avant toute nouvelle
génération. Les appels IA terminés trop tard ne peuvent pas restaurer le tour.

Les corrections et suppressions manuelles survivent aux reconstructions.
L'utilisateur peut les consulter et les supprimer/corriger ; une correction
restant attachée à un ancien tour conserve sa mention de source afin de pouvoir
être réévaluée après une bifurcation.

## Contexte et outils

La sélection déterministe donne un score aux noms, textes, objets et objectifs
présents dans la scène, aux informations actives et à l'importance. L'ancienneté
seule n'élimine pas un souvenir. Le budget par défaut est d'environ 3 600
caractères, plus le contexte de Lore et l'historique récent existants.

Les modes classique et hybride injectent le même contexte sélectionné. Les
modèles compatibles Tool Calling peuvent en plus lire :
`search_memory`, `get_memory_entry` et `get_event_history`.
Aucune écriture de mémoire n'est exposée au narrateur.

## Utilisation et coûts

Dans les paramètres de la conversation, activez/désactivez **Mémoire
automatique**, choisissez le profil de l'extracteur (ou gardez celui du
narrateur), puis ouvrez **Consulter et corriger la mémoire**.

L'extraction peut entraîner **un appel IA supplémentaire par tour validé**.
L'écran Mémoire permet de relancer les tours non analysés ou de reconstruire
l'ensemble de la Partie — cette dernière action peut coûter plusieurs appels.
La désactivation conserve les souvenirs déjà enregistrés. Les mêmes clés API
et profils IA que le reste de l'application sont réutilisés.

Dans la page OpenUncensored, les modèles sans capacité déclarée ne sont plus
cachés. Les réglages du profil permettent de déclarer la compatibilité ou
d'effectuer un test natif, explicitement confirmé et potentiellement payant.

## Limites identifiées

- Pas de moteur vectoriel ni de fusion sémantique générale des alias. Les
  identifiants doivent rester cohérents d'un tour à l'autre ; une déduplication
  simple par sujet/catégorie/champ existe.
- La vérification des citations prouve la traçabilité textuelle, pas la vérité
  sémantique : les rumeurs et les faits contradictoires doivent garder une
  qualification explicite.
- Le budget est exprimé en caractères plutôt qu'en tokens exacts, afin
  d'éviter un nouveau service de tokenisation.
- La reconstruction complète relance les appels IA ; le coût est confirmé
  dans l'interface avant l'action.
- Les secrets restent accessibles au narrateur, mais ne doivent pas être
  révélés au joueur avant leur découverte.

## Vérification

La CI de la branche exécute `flutter analyze`, `flutter test` et une
compilation APK. Le projet n'intègre pas de dépendance supplémentaire pour
la mémoire. Les tests couvrent le rappel après trente tours, les citations,
les mises à jour, le rejeu, les corrections manuelles, l'isolation SQLite,
les RAW obsolètes, l'extraction interrompue et l'interface.
