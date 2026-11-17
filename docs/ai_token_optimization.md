# Domolia — Audit et optimisation du coût IA

## Périmètre et référence

Base : main au commit 677e861 (PR #21 Live Memory fusionnée). Branche :
perf/ai-token-optimization. Les changements concernent le transport des
références canoniques, le contexte du JSONificateur, la persistance de
l'usage et la coordination de la Live Memory. Aucun agent supplémentaire et
aucun service payant n'ont été ajoutés.

Mesure utilisateur de départ, antérieure à la Live Memory :

| Appel | Input déclaré | Output déclaré | Total |
|---|---:|---:|---:|
| search_lore | 2405 | 79 | 2484 |
| get_lore_entry | 2592 | 62 | 2654 |
| Narration finale | 2292 | 176 | 2468 |
| JSONificateur | 2091 | 525 | 2616 |
| **Total observé** | **9380** | **842** | **10222** |

Coût fournisseur annoncé par l'utilisateur : environ 0,004 USD.
Le JSONificateur représentait 25,6 % des tokens observés.
Ce scénario ne couvre ni l'extraction Live Memory ni les Parties longues.
Il ne sert pas d'échantillon statistiquement représentatif.

Un simple produit de 10 222 par 10/100/1000 ne constitue **pas** une
simulation fiable de Partie longue : l'historique, le Lore et la mémoire
varient. Les tests à fournisseur simulé vérifient séparément les budgets
et la conservation des faits.

## Audit et changements

| Poste | Avant | Après | Type de preuve |
|---|---|---|---|
| Recherche canonique | Recherche sur nom/tags/description, retour d'un extrait de description | Recherche dans les champs pertinents non secrets, extrait du champ correspondant (260 caractères max) | Test d'inscriptions avec noms similaires |
| JSONificateur | Six anciens messages complets transmis à chaque réponse | Aucun historique quand le RAW est autonome ; deux messages tronqués à 160 caractères quand une citation peut nécessiter le contexte | Test de contexte local |
| Instructions du JSONificateur | 2 828 caractères | 1 853 caractères (−34,5 % en **caractères**, pas en tokens facturés) | Comparaison déterministe des chaînes |
| Live Memory | Relecture des projections SQLite après commit et à la sortie | Relecture intermédiaire seulement lorsqu'un autre RAW en attente doit être extrait ; relecture finale conservée | Tests de projection et retours arrière existants |
| Coûts | Diagnostics narratifs limités en rétention et incomplets pour la mémoire | Journal local de métadonnées par Partie, indépendant des diagnostics, avec tokens, coût déclaré, provenance de l'estimation et catégories | Tests de parsing et de persistance |
| Comptage Tool Calling | Risque de confondre les fonctions exécutées et les appels de modèle | Un enregistrement par échange HTTP de modèle, nombre de consultations dans un compteur **distinct** | Tests d'agrégation |

### Statistiques persistantes

SQLite v11 ajoute ai_usage, une table locale avec identifiant unique, Partie
et métadonnées **sans aucun prompt, RAW ou clé**. Les enregistrements sont
conservés malgré la purge des diagnostics et supprimés en cascade avec la
Partie. Un même identifiant de requête réenregistré est ignoré.

Le journal enregistre par appel : input/output, cached/reasoning si disponibles,
coût annoncé, durée, échec, et nombre d'invocations locales. La synthèse par
tâche apparaît dans les paramètres de conversation et distingue :

- tokens déclarés/estimés par le fournisseur ;
- tokens ou coûts manquants (jamais transformés en zéro) ;
- coût connu complet ou borne inférieure du coût incomplet ;
- nombre de requêtes IA et nombre de consultations d'outils.

Pour OpenUncensored, la documentation indique que le coût USD se trouve dans
ou.cost_usd et que ou.usage_estimated marque un comptage estimé :
https://openuncensored.com/docs

Les flux interrompus peuvent ne pas retourner de bloc final usage.
Le prix ne peut pas être inféré du max_tokens ni du nombre de caractères.
Le prix d'une tentative fournisseur interne et le coût final routé sont
traités selon **le coût déclaré** par la réponse, sans surcharge locale.

### Choix volontairement écartés

- **Filtre local d'extraction des souvenirs** : pas de saut d'extraction
  automatisé par heuristique de longueur. Un tour très court peut contenir
  une promesse ou une révélation ; faux négatifs inacceptables sans corpus
  de validation.
- **Extraction groupée** : apporte une latence de mémoire et complexifie
  l'idempotence, les réécritures et la provenance. Pas introduite sans mesure.
- **Cache de réponse côté client** : risque de ressortir un RAW ancien ou
  de masquer des corrections de mémoire. Pas introduit.
- **Prompt cache** : dépend du fournisseur et du modèle. L'API demeure sans
  état et aucun crédit de cache n'est supposé sans champ provider.
- **Substitution automatique de modèles** : interdite ; le choix reste
  utilisateur, par tâche et par Partie.
- **Remplacer la JSONification** : conserver strictement RAW → JSONificateur.

## Tests et mesures disponibles

- Test d'exactitude canonique, de séparation de personnages homonymes,
  de non-divulgation de secrets et de recherche sur attribut.
- JSONificateur autonome ou dialogue cité avec précédent contexte borné.
- Contexte de 10, 100 et 1 000 tours simulés sans réseau ni crédit ;
  conservation de RAW et mémoires de référence via les outils existants.
- 1 000 souvenirs synthétiques : sélection bornée, source et certitude.
- Parsing de réponses SSE et JSON, coût routé OpenUncensored, cache,
  reasoning, coût absent et usage estimé.
- Journal durable et idempotent SQLite, suppression des diagnostics,
  reprise et cascade Partie.

Ces tests **ne prouvent pas** la fidélité littéraire des modèles en production.
Un test factuel avec IA réelle (hors CI) est recommandé avant d'annoncer un
gain en USD ou de figer les instructions du JSONificateur.

## Vérification manuelle reproductible

1. Importer le Livre « Les Archives de Verre — Benchmark IA ».
2. Créer une Partie, activer Tool Calling et Live Memory.
3. Envoyer les 10 messages du parcours, attendre la fin de l'extraction
   puis exporter la trace IA et la conversation.
4. Vérifier AUBE-731 versus NACRE-204, l'état de la promesse, le ticket bleu
   n°47 et le caractère incertain des rumeurs.
5. Dans une Partie séparée, régénérer/éditer des tours et vérifier les faits
   supprimés et la provenance.
6. Répéter avec les mêmes modèles/réglages sur une version de référence
   et une version optimisée. Comparer l'USD et les tokens *déclarés* par
   tâche ainsi que le nombre d'erreurs, les latences et la qualité.
7. Ne jamais lancer 100/1000 appels payants pour un benchmark automatisé.

## Limites de la livraison

Le budget d'historique du narrateur et les extractions Live Memory restent
conservateurs pour garantir la cohérence. L'économie de 20–30 % demeure un
**objectif non vérifié** tant que des traces comparables avant/après
(avec extraction mémoire sur les deux versions) ne sont pas disponibles.

Les chiffres synthétiques de contexte ne sont pas des tokens facturés.
La durée par échange agrégée ne rend pas compte de tous les temps hors LLM.
Les erreurs avant l'émission d'une requête HTTP ne sont pas des coûts facturés.
