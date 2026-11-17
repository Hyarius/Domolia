# Audit IA — Valbrume, 17 novembre 2026

## Source de référence

Branche de départ : `main`, fusion de la PR #30 (`9d4ca2029326a606c1314fd7a73365ea6745c225`).
Les chiffres ci-dessous ont été recalculés à partir de l'export local
`domolia-diagnostic-ia (13).json` de *L'Horloge des Marées — Banc d'essai IA*.
Les scènes et secrets de l'export ne sont pas ajoutés au dépôt.

La trace contient **19 tours**, mais les diagnostics HTTP ne sont conservés
que pour **4 tours récents**. Il serait erroné de présenter ce total comme
la consommation des 19 tours ou de toute la Partie.

| Tour (playerEventId) | Appels narrateur | Appels mémoire | Entrée narrateur | Sortie narrateur | Entrée mémoire | Sortie mémoire | Total |
|---|---:|---:|---:|---:|---:|---:|---:|
| 101 | 1 | 1 | 5 519 | 292 | 1 280 | 820 | 7 911 |
| 110 | 1 | 1 | 5 221 | 254 | 1 254 | 689 | 7 418 |
| 117 | 1 | 1 | 5 208 | 309 | 1 250 | 8 | 6 775 |
| 122 | 3 | 1 | 17 581 | 468 | 1 291 | 849 | 20 189 |
| **Total** | **6** | **4** | **33 529** | **1 323** | **5 075** | **2 366** | **42 293** |

Les usages mémoire proviennent de l'événement SSE
`response.completed.response.usage`, non des champs `interpretation` de
l'ancien export (vides pour l'extraction non-streaming). Le narrateur
représente 34 852 tokens (82,4 %), la mémoire 7 441 (17,6 %).
Les six appels narrateur totalisent 147 904 caractères de corps JSON de
requête, les quatre appels mémoire 21 561 caractères. Ces nombres
décrivent le JSON transporté, **pas** les tokens facturés.
Les durées d'appel connues sont respectivement 37 264 ms et 49 973 ms
(somme des latences par requête, pas temps utilisateur par tour).

## Audit du code préexistant

- `NarrativeChatController.buildNarratorContext` : historique glissant
  (16 000 caractères sans outil, 7 000 avec outil, avant cette PR),
  canon via `LoreContextBuilder` ou un lore optimisé, et mémoire via
  `LiveMemorySelector` (3 600 caractères). Les contraintes de base du
  narrateur restent intégralement fournies.
- `NarrativeReferenceTools` : recherche locale par Partie dans les
  souvenirs, le canon et les RAW originaux, sans requête distante.
  Les secrets ne figurent pas dans les résultats de recherche abrégés;
  un accès canonique complet reste réservé au narrateur.
- `_requestHybrid` : deux cycles maximum de consultation, au plus trois
  outils exécutés par cycle, plafonds sur la taille de résultat et
  instruction de terminaison. Les nouveaux appels Responses utilisent
  `store:false` ; ils ne réutilisent pas un état serveur présumé.
- `LiveMemoryCoordinator` : extraction d'un RAW déjà validé par tour
  en attente, sérialisation, citations littérales exigées, replay
  déterministe et projections SQLite. Aucun filtre local fondé sur la
  longueur ne peut garantir l'absence de révélations ou de promesses.
- `AiUsageRecord` : journal SQLite persistant déjà existant, distinct
  des diagnostics bruts. L'ancien parser ne prenait pas en compte les
  enveloppes Responses et les noms `input_tokens/output_tokens`.
- `Jsonifier` : contexte déjà limité et absent pour les RAW autonomes.
  Aucune modification de ce pipeline dans cette PR.

## Modifications livrées dans cette PR

1. Décodage commun du bloc `usage` Chat Completions ou Responses SSE,
   y compris cached/reasoning, pour les appels narrateur **et mémoire**.
   Provenance `provider`, `diagnostic` ou `unknown` dans le journal ;
   valeurs indisponibles maintenues `null`.
2. Journalisation des seuls volumes et identifiants de tours
   (`requestCharacters`, `requestBytes`, `playerEventId`) pour chaque
   requête. Aucun texte du prompt ni secret supplémentaire n'est stocké.
3. Totaux de l'export IA calculés à partir des réponses réelles plutôt
   que des seuls champs interprétés : nombre d'appels mémoire, appels
   d'outils, octets, latences, cache et raisonnement.
4. Réduction du plafond historique *en mode Tool Calling* de
   **7 000 à 5 200 caractères**. Les anciens tours demeurent dans SQLite
   et consultables via `search_history` / `get_history_excerpt`.
5. **Préparation locale et déterministe d'un contexte de départ**, une
   fois par Partie au premier tour narratif. Maximum **3 600 caractères**
   pour l'univers, les règles de base, la situation de départ, la seule
   intrigue principale et le casting initial. Aucun appel à un modèle de
   compression, aucun envoi de l'arbre des scénarios complet.
6. La préparation et son empreinte (`startup-v2-` + hash du Lore) sont
   conservées dans les champs de cache SQLite préexistants : sans
   migration. Les anciennes optimisations LLM sont invalidées ; une
   modification du Livre invalide son contexte dérivé, pas le canon.
7. Ajout d'un outil local paginé `get_lore_global` pour récupérer
   exactement les champs mondiaux absents ou abrégés. Les outils
   `search_lore` et `get_lore_entry` restent la voie normale pour
   les personnages, lieux, scénarios, événements et conditions.
   Les secrets non découverts restent réservés au narrateur.
8. Références locales limitées à **850 caractères avec outils** et
   **1 600 sans outils**, choisies parmi les quatre messages récents.
   Aucun débordement du sélecteur historique ne peut bloquer le tour.
9. Les contrôles d'optimisation par IA devenue inactive sont masqués
   dans l'interface ; les anciennes valeurs enregistrées restent
   compatibles, sans déclencher de facturation.

## Reproduction : blocage sur Le Registre de Sel

L'export `domolia-diagnostic-ia (14).json` et la capture du
17 novembre 2026 montrent une erreur à la deuxième action : le cache
de compression distant du Lore a échoué au premier tour, puis
`LoreContextBuilder` a bloqué le second tour sur son contrôle de
« lore essentiel trop volumineux ». Une même Partie ne doit jamais
se retrouver dans cet état alors que les fiches non essentielles restent
consultables localement.

Le nouveau parcours élimine ces **deux** causes :
- plus de requête `context_optimizer` (même si un ancien profil est
  enregistré) ;
- aucun appel à `LoreContextBuilder.build` pour assembler le contexte
  narrateur : l'introduction reste bornée, les détails sont récupérés
  sur demande, sans lire tous les événements et secrets d'avance.

Un livre dont les règles globales dépassent la part initiale disponible
reste conservé intact. La partie visible est explicitement marquée
« suite dans le Lore » et la suite s'obtient via
`get_lore_global(section, offset)`, par morceaux de 2 600 caractères.
Les fournisseurs sans Tool Calling disposent seulement des extraits
locaux de la scène : pour des règles très longues, les outils sont
fortement recommandés.

Les gains réels de tokens sur ce nouveau Livre restent à mesurer sur
une nouvelle trace, avec la même IA et les mêmes actions.

## Estimation hors-ligne, reproductible et limitée

Pour les **quatre premières requêtes narrateur des quatre tours** ci-dessus,
en réappliquant l'algorithme de sélection de messages aux `input`
conservés dans le diagnostic : 26 553 caractères historiques retenus
avec un budget de 7 000, contre 18 208 avec 5 200.
Soit **8 345 caractères évités (31,4 % de la partie historique)**.

Il s'agit d'une simulation déterministe *sur les anciens corps de requête*,
pas de tokens mesurés après changement. Elle ne simule ni les nouvelles
sélections de lore, ni la dynamique des appels d'outils ni le prompt caching.
En particulier elle ne permet **pas** d'affirmer 31,4 % de gain sur la facture,
la latence, le total du tour ou la qualité littéraire.

## Risques, choix non retenus et vérifications

- **Extraction mémoire à chaque tour conservée**, faute de détecteur local
  prouvé sans faux négatifs. Le tour 117 a produit seulement 8 tokens
  de sortie, mais une courte réponse n'est pas une preuve de tour
  dispensable. Prochaine piste : corpus annoté « aucun fait nouveau »
  et mesures de rappel avant tout saut d'appel.
- **Aucun raccourci pour les secrets** et aucun résumé agressif des
  inventaires/engagements. Le ticket proposé mais non acquis reste
  testable via recherche RAW originale.
- **Pas de cache serveur implicite** : la voie OAuth OSS ne garantit
  pas les réglages d'API classiques, et les requêtes actuelles sont
  `store:false`.
- **Pas de LLM Android embarqué**, de migration SQLite, d'IA payante
  dans les tests ou de changements du JSONificateur.

### Reproduction manuelle

Avec le même Livre, modèle, compte et configuration sur `main` et cette
branche : créer deux Parties neuves, jouer le script de Valbrume,
puis exporter la trace IA. Comparer **les tokens déclarés** par tâche,
la quantité de JSON envoyée, les tours avec outil, la latence et les
incohérences (Éline Vare/Varre, ticket bleu 47 non acquis, promesses,
secrets et conditions). Les tests Flutter mockés vérifient la
comptabilisation et la recherche du RAW sans coût externe.

À évaluer ensuite dans des PR indépendantes : sélection plus intelligente
du canon/mémoire selon l'état de scène, idempotence sémantique des souvenirs,
déclenchement différé de l'extracteur uniquement après validation sur corpus,
outils plus ciblés, plafonds configurables et éventuel cache officiellement
documenté par fournisseur.
