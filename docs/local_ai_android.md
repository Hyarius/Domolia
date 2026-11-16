# IA locale Android — sélection de modèles GGUF

Branche : `feat/android-ministral-local` (PR #24, non fusionnée).

## Modèles disponibles

1. **Qwen2.5 1.5B Instruct Q4_K_M** (conseillé en premier sur S20 FE) : 1 117 320 736 octets, officiel Qwen, Apache 2.0, format de prompt ChatML. URL : https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/blob/main/qwen2.5-1.5b-instruct-q4_k_m.gguf. SHA-256 officiel épinglé : `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e`.
2. **Ministral 3 3B Q4_K_M** (2,15 Go) ou **Q5_K_M** (2,47 Go) : Mistral AI, Apache 2.0, format `[SYSTEM_PROMPT]/[INST]`.

Les modèles sont sélectionnables dans **Paramètres > IA locale — Modèles**. Le téléchargement est explicitement confirmé. Le modèle précédent reste sur le téléphone jusqu’à validation du fichier téléchargé, puis est supprimé. Il faut donc disposer d’espace supplémentaire pendant le remplacement. En cas d’échec, l’ancien fichier reste utilisable, mais le mode local doit être réactivé manuellement.

Les installations Ministral existantes sont retrouvées dans `models/ministral` avec leurs anciens identifiants et préférences ; aucune nouvelle copie n’est nécessaire.

## Pipeline

Le narrateur RAW, le JSONificateur et la Live Memory partagent le même modèle chargé localement, avec accès sérialisé ; aucun secours distant payant n’est effectué en cas d’erreur d’inférence locale. Le moteur utilise actuellement **2 threads CPU, un contexte de 2 048 tokens, sans offload GPU** ; Vulkan n’est pas encore validé sur le binaire Android effectivement embarqué.

Le mode NSFW appartient toujours à la configuration du Livre. Aucun filtre applicatif n’est ajouté au fournisseur local ; les instructions sont conservées dans le prompt. Cela **ne garantit pas** l’absence de refus du modèle standard. Un test éditorial NSFW doit être mené sur un appareil réel avant toute promesse de compatibilité.

## Validation Android

1. Installer Qwen Q4 (environ 1,12 Go) après confirmation.
2. Tester « Diagnostic rapide (24 tokens) », puis « Tester la narration sur ce téléphone ».
3. Mesurer le délai avant le premier fragment, la durée totale et la qualité du français.
4. Lancer un Livre avec narration RAW, JSONification et Live Memory puis contrôler que les actions du joueur et les limites du Livre sont respectées.
5. Refaire les essais avec Ministral si nécessaire. Comparer les coûts CPU et vérifier les éventuels refus NSFW.

Une CI verte ne remplace pas une validation native sur S20 FE. Le plugin `llama_flutter_android: 0.2.6` doit également être évalué pour une future accélération Vulkan. Ne pas fusionner sans autorisation expresse.

Sources :
- https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF
- https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF
- https://pub.dev/packages/llama_flutter_android
