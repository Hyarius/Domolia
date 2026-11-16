# Narration Ministral hors connexion — prototype Android

Branche de travail : `feat/android-ministral-local`, démarrée depuis `main`.
Elle ne reprend pas les commits expérimentaux de la PR #23, fermée sans fusion.

## Utilisation

1. Paramètres > IA locale — Mistral (ou Crédits IA > IA locale).
2. Choisir **Ministral 3 3B Q4_K_M** (2,15 Go) ou Q5_K_M (2,47 Go).
3. Appuyer sur « Valider et télécharger » et accepter la confirmation : les anciens poids sont supprimés avant le téléchargement pour limiter l'espace occupé.
4. L'installation active le narrateur local ; un interrupteur permet de revenir à l'IA distante. La connexion internet n'est requise que pour télécharger le modèle, pas pour l'inférence.
5. Utiliser « Tester la narration sur ce téléphone », puis lancer le Livre de benchmark. Mesurer les temps, les crashs, la qualité et la cohérence.

Dans le **pipeline narratif local**, le seul téléchargement nécessaire est le GGUF officiel sur `huggingface.co/mistralai`. Les autres fonctions de l'application (mises à jour, crédits) peuvent encore utiliser le réseau indépendamment. Ni le narrateur, ni le JSONificateur, ni l'extracteur de mémoire n'appellent une API payante tant que le mode local est actif. **Un échec ne déclenche pas de fallback distant.**

## Limites et points de validation

- Prototype CPU Android, 4 threads, contexte 4096 tokens ; vitesse et gestion de la RAM non mesurées sur S20 FE 6/8 Go.
- Les modules auxiliaires réutilisent le même modèle en série ; cela peut allonger nettement la latence globale du tour.
- Le plugin Android intègre llama.cpp : il faut confirmer que le GGUF d'architecture `mistral3` se charge avec les bibliothèques natales de sa version 0.2.6.
- Le prompt reprend les marqueurs officiels `[SYSTEM_PROMPT]` et `[INST]` pour éviter le ChatML du plugin. Les tests Android doivent confirmer que le rendu correspond au template réellement embarqué.
- HTTPS + taille exacte + magic GGUF à l'installation, puis hachage SHA-256 conservé localement (TOFU) : le SHA n'est pas encore épinglé sur une source externe et ne remplace pas une empreinte de distribution officielle.
- Modèle standard **non garanti sans refus** ; le réglage NSFW des Livres reste inchangé, sans ajouter de filtre dans le fournisseur local.
- En mode local, réduction du contexte (Lore, mémoire, historique). Le Livre et SQLite continuent d'être les sources canoniques.
- Le JSONificateur local doit être confronté aux véritables RAW de tests et aux dialogues ambigus ; son exactitude n'est pas présumée.

Sources de la distribution et du format :
- https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF
- https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512/blob/main/chat_template.jinja
- https://pub.dev/packages/llama_flutter_android

Aucun merge sans autorisation.
