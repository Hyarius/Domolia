# Domolia — narrateur entièrement local sur Samsung S20 FE

Étude technique du 16/11/2026. **Ce document n'atteste pas que l'inférence narrative locale fonctionne déjà.** Les modèles et le plugin Android doivent être validés sur un appareil réel avant activation.

## Matériel cible

- Samsung Galaxy S20 FE 5G (SM-G781B), Snapdragon 865 (SM8250) et variantes de **6 ou 8 Go de RAM**. Il faut lire la RAM effective sur le téléphone et mesurer la mémoire réellement disponible.
- Le stockage interne ou la microSD (plusieurs Go acceptables) n'augmente pas la RAM disponible à l'inférence.
- Le fichier GGUF ne représente qu'une partie de la RAM requise : contexte KV, runtime, Flutter/Android et buffers consomment aussi de la mémoire.

Source Samsung : https://news.samsung.com/fr/galaxy-s20-fan-edition

## Modèles candidats pour la narration (GGUF)

| Modèle | Fichier quantifié | Taille approximative (selon distribution) | Usage envisagé |
|---|---|---:|---|
| Qwen3.5 2B | Q4_K_M | 1,3 Go | Référence légère, premières générations complètes, particulièrement S20 FE 6 Go |
| Ministral 3 3B Instruct 2512 | Q4_K_M | 2,0–2,2 Go | Candidat de prose en français, comparaison de style |
| Qwen3.5 4B | Q4_K_M | 2,8–3,0 Go | Candidat de qualité narrative maximale raisonnable, à tenter sur 6 Go seulement si la RAM disponible le permet |
| Qwen3 1.7B | Q4_K_M | 1,28 Go | Référence technique/rapidité et contrôle des tâches auxiliaires |
| Modèle 7–8B | Q4 | 4–5 Go, plus overhead | Ne pas proposer par défaut sur 6 Go ; risques d'OOM, swap, latence et échauffement |

Sources :
- https://huggingface.co/SoAIHQ/Qwen3.5-2B-GGUF
- https://huggingface.co/SoAIHQ/Qwen3.5-4B-GGUF
- https://huggingface.co/bartowski/mistralai_Ministral-3-3B-Instruct-2512-GGUF
- https://huggingface.co/tensorblock/Qwen_Qwen3-1.7B-GGUF

**Attention** : la même quantification peut varier en octets selon l'exportateur ; fixer pour chaque modèle une URL, une taille maximale, un checksum complet et une licence vérifiée.

## État de la branche

`feat/on-device-auxiliary-ai` contient `LocalModelManager` (téléchargement GGUF opt-in, vérification SHA-256, stockage privé) et `LocalAuxiliaryProvider` (inférence via `llama_flutter_android 0.2.6`).

**Manque encore** : sélection UI/routage effectif des tâches, moteur de narration local, streaming/annulation pendant narration, gestion multi-modèles, vérification de l'usage du template de chat propre à chaque GGUF, tests sur Android. Le fournisseur actuel suppose `chatml`, `4096` tokens de contexte, CPU et 4 threads : ces réglages ne démontrent pas la compatibilité ni une vitesse acceptable pour Qwen3.5.

Le plugin annonce des templates prédéfinis et l'accélération Vulkan sur certains GPU, mais il faut tester l'application du template GGUF de Qwen3.5 et la stabilité de son implémentation native :
https://pub.dev/documentation/llama_flutter_android/latest/

## Architecture ciblée

1. **Installateur multi-modèles explicite** : catalogue de candidats, installation/désinstallation, espace libre, contrôle SHA-256 et licence ; jamais de téléchargement silencieux. Vérifier mémoire disponible et compatibilité avant chargement.
2. **Moteur local réutilisable** : une seule instance de modèle chargée, requêtes auxiliaires et narrateur sérialisés ; libération propre, annulation, timeout et informations mémoire. API `AiChatProvider` + `AiStreamingChatProvider` si possible.
3. **Sélection par Partie** : « Narrateur local », modèle sélectionné, réglage de longueur et contexte (commencer à 2048–4096 tokens). La Live Memory, le Lore et la JSONification restent sur l'appareil ; aucun appel API dans ce mode.
4. **Optimisation de contexte** : canon et mémoire en SQLite, petites fiches de scène sourcées et dernier historique pertinent ; ne pas charger la totalité du Livre dans le prompt local.
5. **Aucune facturation surprise** : si le modèle local échoue, conserver le RAW et expliquer l'échec ; **ne jamais** appeler une API distante sans choix explicite de l'utilisateur.

## Validation exigée

- Sur le S20 FE **6 Go**, mesurer pour 2B/3B/4B : lancement, RAM max, tokens/seconde, temps du premier token, temps d'une réponse de 100–170 mots, batterie et chauffe, sur au moins 10 tours.
- Mêmes tests sur une variante 8 Go si disponible. Ne publier **aucun** chiffre de vitesse avant mesure.
- Sur le Livre de test *Les Archives de Verre* : stabilité d'Oren Martel, distinction Liora Valen/Liora Vallen, secrets masqués, événements conditionnels non déclenchés prématurément, interdiction de jouer le personnage joueur, cohérence après 20+ tours.
- NSFW : ne pas ajouter de filtrage applicatif pour les Livres autorisant ces scènes, mais une variante marquée « uncensored » reste une revendication à tester (qualité française, tendance au refus, contraintes de licence). Aucun modèle n'est garanti « sans refus » par son nom.
- Mesurer aussi les réponses hors ligne (mode avion), sauvegardes RAW et absence de trafic API, ainsi que les crashs/OOM.
- Vérifier la compatibilité réelle de Qwen3.5 avec le moteur embarqué avant d'ajouter ces GGUF au catalogue de production.

## Décision provisoire

Sur un S20 FE avec 6 Go : tester **Qwen3.5 2B Q4_K_M** d'abord, puis **Ministral 3 3B** et **Qwen3.5 4B Q4_K_M** si la RAM le permet. Sur 8 Go : Qwen3.5 4B Q4_K_M peut devenir le choix par défaut si les tests qualité/latence réussissent. Le narrateur distant doit rester un mode optionnel, pas un secours automatique. Aucune fusion sans validation explicite.
