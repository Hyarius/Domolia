# PR11 — Contexte narratif hybride et Tool Calling

## Architecture

La consultation est réservée au narrateur RAW. Les étapes JSONificateur et Optimiseur conservent leurs contrats textuels, et le Live Lore structuré n'est pas créé.

- Le profil déclare sa capacité supported / unsupported / unknown, indépendamment du fournisseur. Changer modèle, endpoint ou fournisseur rétablit unknown.
- Une Partie possède un interrupteur indépendant, activé par défaut lors de la migration SQLite v8. Le profil et la Partie conditionnent effectivement les appels.
- Les dernières interactions restent automatiquement dans le contexte, avec un budget de 7 000 caractères en mode hybride et de 16 000 en mode classique. Les anciennes limites de 24 messages ne s'appliquent plus. La sélection canonique reste déterministe.
- Le transport Chat Completions compatible reçoit les fonctions natives, reconstruit les deltas SSE et préserve les identifiants. Un appel partiel n'est jamais exécuté. Le refus explicite des paramètres d'outils entraîne un repli classique ; les erreurs d'authentification, réseau ou paiement ne sont pas masquées.
- Les quatre outils lisent uniquement le Livre et les snapshots des RAW/événements de la Partie active, déjà persistés en SQLite. Aucune recherche IA, base d'embeddings ou nouveau Live Lore. Le statut potentiel du canon n'est jamais un état réalisé.
- Limites : deux cycles de consultation, trois appels locaux par cycle, cinq résultats par recherche, 6 000 caractères par résultat et 10 000 caractères supplémentaires par tour. Un résultat technique de budget épuisé est renvoyé et le modèle doit conclure son RAW.

## Persistance, reprise et confidentialité

Les outils ne font aucune écriture et ne possèdent pas de cache durable. Le retour à un ancien événement supprime les sources de la chronologie active consultable. L'annulation arrête le flux de l'IA et une réponse devenue obsolète ne doit pas être publiée. Le RAW final est sauvegardé avant JSONification ; une erreur de JSONificateur ne relance pas le narrateur. Les résultats des recherches sont des données, pas des instructions. Les clés API ne sont jamais incluses dans les résultats.

## Mesurer les coûts

Comparer la somme des prompt_tokens et completion_tokens de TOUS les appels : narrateur initial, reprises éventuelles, JSONificateur, optimiseurs éventuels. Les définitions d'outils sont incluses dans le prompt transmis ; les résultats d'outils dans les prompts de reprise ; les demandes de fonctions dans les completions. Ne pas les recompter séparément. L'export fournit le nombre d'appels, les totaux connus et les usages manquants par tour. Si une réponse ne fournit pas de comptage, le total reste partiel et aucune économie ne peut être affirmée.

## Scénarios reproductibles

1. Partie courte : réponse directe, comparer mode hybride et classique.
2. Partie longue sans besoin de mémoire ancienne : aucune consultation nécessaire.
3. Partie de plus de 100 tours : souvenir ancien via recherche puis RAW historique.
4. Livre avec beaucoup de Lore : fiche consultée uniquement à la demande.
5. Plusieurs personnages et lieux : recherches indépendantes en un seul cycle.
6. Trois demandes successives : arrêt des consultations au budget fixé, génération finale.
7. Profil inconnu ou incompatible : aucun champ technique, RAW et JSONificateur normaux.

Les tests automatisés fonctionnent avec des fournisseurs simulés, sans crédits IA. Les économies en tokens réels ne sont calculables que lorsque les fournisseurs renvoient leurs usages comparables sur des récits équivalents.

## Limites acceptées

Recherche locale textuelle, sans index FTS5 pour cette première version. Les formulations sémantiquement proches mais sans mots communs peuvent échapper au classement. Le budget de caractères est une approximation de taille, pas un calcul de tokens. Aucun événement Live Lore structuré n'est déduit du Livre.
