# Fournisseurs IA unifiés — Domolia

## Objectif

Domolia ne spécialise pas son moteur narratif par fournisseur. Les tâches
Narrateur, JSONificateur, Optimiseur de lore et Extraction mémoire choisissent
un **profil nommé** (avec possibilité de surcharge par Partie) et invoquent :

- `AiChatProvider` : génération de texte ;
- `AiStreamingChatProvider` : flux de texte et consommation déclarée ;
- `AiToolCallingChatProvider` : outils de consultation du lore et de la mémoire,
  avec un contrat unique `AiToolMessage` / `AiToolStreamChunk`.

Les implémentations traduisent ces mêmes contrats vers **Chat Completions**
(OpenUncensored et fournisseurs compatibles) ou **Responses API** (ChatGPT).

## Configurations et connexion

La page **Paramètres → Fournisseurs IA** rétablit la gestion des profils,
notamment `ChatGPT` via OAuth OpenAI et `CustomAI`. La page
**Paramètres → Crédits IA** reste dédiée aux clés et achats OpenUncensored.
Les profils et les jetons de connexion restent stockés sur l'appareil ; aucun
secret ne doit être présent dans les exports.

L'accès à ChatGPT utilise `Sign in with ChatGPT for OSS`. Une éventuelle
connexion sociale GitHub au navigateur ne représente ni une clé API GitHub
ni une autorisation OpenAI. Le forfait ChatGPT n'est utilisable que si les
scopes et les modèles du compte le permettent. Le modèle et sa compatibilité
Tool Calling sont sélectionnés par profil (test réel facultatif, explicitement
confirmé par l'utilisateur).

## Compatibilité du parcours OSS actuel

- `POST https://api.openai.com/v1/responses` avec `store:false`,
  `stream:true` et un historique explicite.
- Les consignes `system` Domolia sont envoyées en `instructions`, et non
  comme éléments `input` de rôle `system`.
- `max_output_tokens` n'est pas pris en charge par le partage du forfait
  ChatGPT OSS : le réglage local est validé mais n'est pas envoyé. **Le budget
  de sortie défini dans l'interface n'est donc pas une limite garantie pour
  ChatGPT sous cet accès.** Les limites réelles sont celles de la connexion.
- Les outils personnalisés passent par un `namespace` Responses ; les
  appels et résultats sont convertis vers les mêmes objets que pour
  OpenUncensored. Les outils intégrés hébergés non disponibles ne sont pas
  invoqués.
- L'application n'utilise pas les API internes de ChatGPT.

La documentation OpenAI détermine les capacités effectives : les modèles,
les scopes, les paramètres et les outils supportés peuvent évoluer.

## Tests

Les tests unitaires et Widget simulent les transports et les réponses.
**Aucun appel IA payant n'est permis dans la CI**. Les tests régressifs couvrent
la navigation vers la gestion des fournisseurs, les contraintes OSS, les
appels d'outils et leur second tour, la confidentialité des identifiants
ainsi que la conservation des choix ChatGPT après redémarrage d'OpenUncensored.

L'authentification dans le navigateur Android et une génération réelle
doivent être vérifiées manuellement par un compte éligible, avec
consentement explicite, avant toute affirmation de fonctionnement réel.

Références officielles :
- https://developers.openai.com/siwc/token-sharing-open-source/
- https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations
- https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
