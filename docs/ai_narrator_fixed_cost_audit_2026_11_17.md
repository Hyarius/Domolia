# Domolia — Audit du coût fixe du narrateur (PR suivante à #31)

## Périmètre et méthode

Base : `main` après #31. Les mesures fournisseur fournies par le benchmark
« Le Registre de Sel » concernent **un seul premier tour** :

| Tâche | Entrée fournisseur | Sortie fournisseur | Total |
|---|---:|---:|---:|
| Narrateur | 2 432 | 229 | 2 661 |
| Live Memory (hors périmètre de cette PR) | 530 | 635 | 1 165 |
| Ensemble | 2 962 | 864 | 3 826 |

Répartition d'entrée **approximative, non vérifiée sur le corps HTTP** :
instructions et contexte ~1 786, outils ~515, autres messages ~131.
Pas d'appel d'outil constaté ni de cache fournisseur déclaré sur ce tour.

La présente PR ne dispose pas d'un nouveau replay facturé du même modèle.
Elle mesure donc **exactement les caractères des constantes**, et non les
tokens finaux consommés : tokenisation, encodage JSON, wrappers d'API et
sélection dynamique du Lore rendent une extrapolation trompeuse.

## Parcours réel audité

- `NarrativeChatController.buildNarratorContext` : prompt du
  `Narrator`, briefing local `LoreStartupContextBuilder`, fiches utiles,
  `LiveMemoryCoordinator.context`, historique récent.
- `_generateStructured` et `_requestHybrid` : protocole théâtral ajouté
  pour le RAW structuré, définitions `NarrativeReferenceTools`, jusqu'à
  deux cycles de consultations et trois résultats par cycle. Résultats
  bornés à 10 000 caractères cumulés.
- `AiToolCallingChatProvider` : requêtes stateless pour les fournisseurs
  Chat Completions et Responses. La requête réémet système et outils pour
  chaque cycle ; aucune remise/capacité de cache n'est présumée.
- Les outils lisent le Lore canonique, la mémoire de la Partie et les RAW
  SQLite séparément ; la conversion théâtrale reste locale.

## Taille avant / après — mesures reproductibles du dépôt

Les données suivantes résultent du comptage des caractères UTF-16 des
chaînes constantes (ou, si indiqué, du code source Dart) de `main` et de
`perf/narrator-fixed-token-budget`. Elles **ne sont pas des tokens**.

| Poste | Avant | Après | Variation | Nature |
|---|---:|---:|---:|---|
| Règles de rôle par défaut | 391 | 148 | −243 | Chaîne réelle |
| Style narratif par défaut | 531 | 168 | −363 | Chaîne réelle |
| Invariants de jeu (appliqués même aux Livres personnalisés) | 0 | 567 | +567 | Nouvelle chaîne réelle |
| **Sous-total règles permanentes (hors espaces)** | **922** | **883** | **−39** | Chaînes constantes réellement injectées |
| Protocole théâtral | 1 502 | 511 | −991 | Chaîne réelle |
| Réglages longueur/rythme | 1 653 | 924 | −729 | Taille du getter Dart, **proxy**, pas texte construit |
| Guide de départ | 736 | 214 | −522 | Code source Dart, **proxy**, pas texte construit |
| Huit déclarations d'outils | 3 217 | 2 945 | −272 | Code source Dart ; schémas inchangés, descriptions raccourcies |
| Assemblage du système narrateur | 801 | 479 | −322 | Code source Dart, **proxy**, pas texte construit |

Les règles fondamentales sont désormais injectées dans un bloc non
personnalisable : même si un Livre remplace le rôle ou le style, il reçoit
les invariants (joueur, Lore/Partie, secrets, rumeurs, engagements).
Le sous-total ci-dessus confirme que les économies proviennent surtout
du protocole et de la réduction des répétitions, pas d'une suppression
des garde-fous.

**Attention :** le briefing reste plafonné à **3 600 caractères**, et
l'espace libéré dans son guide peut être rempli par plus de canon. Le gain
du guide ne se traduit donc pas toujours en réduction de la requête.
De même, réduire le code source du getter n'économise pas exactement
le même nombre de caractères dans son résultat.

| Source de coût requête | Tokens avant | Tokens après | Interprétation |
|---|---:|---:|---|
| Narrateur : instructions et rythme | Inclus dans ~1 786 | Inconnu | Chaînes raccourcies, tokens non relevés |
| Protocole théâtral | Inclus dans ~1 786 | Inconnu | −991 caractères constants |
| Contexte initial et fiches | Inclus dans ~1 786 | Inconnu | Budget 3 600 maintenu |
| Live Memory insérée | Inclus dans ~1 786 | Inconnu | Sélection intacte |
| Historique | Inclus dans ~131 | Inconnu | Budgets de #31 intacts |
| Déclarations d'outils | ~515 | Inconnu | −272 caractères de descriptions |
| Résultats d'outils | 0 au tour observé | Non applicable | Rien à comparer pour ce tour |
| **Total narrateur** | **2 432** | **À mesurer** | **Ne pas annoncer de % de tokens** |

## Décisions et trade-offs

1. **Retenu** : conserver un seul jeu de règles narratives dans les
   consignes du `Narrator`, y placer explicitement la liberté du joueur,
   la distinction canon/mémoire, la certitude des événements et la confidentialité
   des secrets. Réduire les trois exemples du protocole à un seul exemple de
   syntaxe (mêmes marqueurs pour le décodeur).
2. **Retenu** : alléger les consignes de style, la duplication du guide de
   démarrage et celle de la Live Memory. Bumper la version de cache
   `startup-v2` vers `startup-v3` : un ancien briefing ne doit pas
   réinjecter les règles obsolètes.
3. **Retenu** : réduire les descriptions des huit outils et fusionner les
   deux messages système du chemin hybride en un seul ; contrats JSON,
   noms, catégories et budgets de consultation inchangés.
4. **Écarté pour l'instant** : fusionner les huit fonctions en une recherche
   générique ou choisir les outils par mots-clés. Risque de perdre le
   rappel de recherches anciennes, d'ajouter un second aller-retour ou
   de sélectionner le mauvais type de source.
5. **Écarté** : diminuer arbitrairement les 3 600 caractères de démarrage,
   les 3 600 de mémoire, les 5 200/16 000 d'historique, utiliser un résumé
   LLM supplémentaire ou supposer un cache Responses / Chat Completions.
   La continuité et la compatibilité fournisseur priment sur une réduction
   non étayée.

## Vérification automatique, sans appel IA

`test/narrator_prompt_compaction_test.dart` vérifie les invariants du
joueur, du canon et des rumeurs ; la déterminisme et l'absence de secrets
du briefing ; la conservation des huit signatures ; la construction de
contexte sans connexion ; puis deux cycles simulés de recherche avec un
message système unique et aucune déclaration d'outil au troisième appel.

Les tests existants vérifient notamment la lecture du RAW ancien,
l'identité des noms proches, le décodage théâtral, le plafonnement du Lore
et la compatibilité fournisseur. Une réponse littéraire réaliste produite
par un modèle n'est **pas** prouvée par ces tests.

## Validation manuelle A/B requise

Sur `main` puis sur cette branche, avec **le même Livre, le même
modèle, les mêmes réglages et une Partie neuve** :

1. « Je demande à Léa Monel, la messagère, de m'indiquer où se trouve
   Léa Monnel, l'archiviste. »
2. « Je demande à voir le jeton n° 62, mais je ne le prends pas. »
3. « Je promets de consulter le dossier si une autorisation écrite m'est
   délivrée ; pour l'instant, je ne l'ai pas. »
4. « Je rapporte qu'on raconte que la gardienne du fanal connaît le
   contenu du dossier ; je n'ai aucune preuve. »
5. « Je reviens bien plus tard et demande ce qu'on sait réellement du
   jeton, de la promesse et du dossier. »

Exporter **Paramètres de la conversation → Diagnostic IA** (et la
conversation si nécessaire), en préservant le modèle et les paramètres.
Comparer par requête : taille envoyée, tokens entrée/sortie **déclarés**,
cache déclaré le cas échéant, nombre d'appels, recherches, latence,
erreurs, et respect des cinq invariants. Écarter tout gain qui confond
proposition et possession, rumeur et fait, promesse et réalisation,
ou révèle un secret.

Aucune baisse chiffrée de tokens/facturation n'est revendiquée avant
cette comparaison fournisseur.
