# Matrice des connexions IA — audit préalable

La version Android ne prouve ni l'accessibilité CORS ni la sécurité d'une connexion dans un navigateur. Ce tableau exprime **ce qui reste à valider**, pas des fonctionnalités Web prêtes.

| Fournisseur / service | Implémentation actuelle | Web : évaluation initiale | Condition d'activation |
| --- | --- | --- | --- |
| Fournisseur OpenAI-compatible personnalisé / OpenUncensored | `OpenAiCompatibleChatProvider`, `package:http`, HTTPS obligatoire, modèle + `/chat/completions`, streaming SSE | Techniquement envisageable mais inconnu : CORS peut bloquer OPTIONS, Authorization, content-type, SSE ; dépend du fournisseur et de son endpoint | Tester catalogue, requête, streaming, annulation et échec CORS **dans un vrai navigateur** avec un compte de test ; aucune clé de test dans GitHub |
| Connexion ChatGPT | `ChatGptAuthService` et `ChatGptResponsesProvider`, OAuth/OIDC PKCE avec callback `HttpServer.bind(127.0.0.1,0)` dans `dart:io` | Le callback loopback ne peut pas être hébergé par Flutter Web statique. Le flux et le droit d'utiliser un abonnement ChatGPT ne doivent pas être extrapolés à partir du code Android | Isoler le client OAuth Android ; désactiver proprement sur Web sauf flux officiellement supporté et vérifié, y compris redirection, échange de code et CORS |
| Paramètres des profils | `AiProfileStore` et `SecureAiProfileStore`, clé mélangée aux métadonnées dans un JSON chiffré Android | Adaptateur nécessaire et avertissement visible sur le risque du stockage navigateur | Pas de secret dans l'archive, les logs, l'URL, le bundle JS ou GitHub |

## Politique de sécurité Web

Une clé API saisie volontairement dans une application Web s'exécute côté client : elle peut être exposée par XSS, extensions malveillantes ou DevTools. `flutter_secure_storage` propose une implémentation WebCrypto/LocalStorage expérimentale, mais **ne fournit pas les mêmes garanties que le Keystore Android**. Définir explicitement si les secrets sont stockés localement avec avertissement et effacement possible, ou gardés en mémoire pour la session. Ne jamais prétendre protéger une clé contre le code exécuté sur le même origin.

Les recommandations officielles d'OpenAI déconseillent l'emploi de clés API dans des environnements clients tels que les navigateurs. Dans une application statique sans backend, cela limite les fournisseurs utilisables en sécurité ; cette contrainte doit être affichée et non contournée par un proxy public non sécurisé.

L'intégration « Sign in with ChatGPT » est distincte d'une simple API key et peut impliquer des exigences de partenaire/enregistrement et de flux approuvé. Le support Web de Domolia reste **indéterminé** jusqu'à une validation technique et des conditions applicables, sans réutiliser un jeton ou une identité obtenus par des moyens non supportés.

## Tests à exécuter en PR04

- Navigateur réel Firefox, Chrome, Edge : préflight, récupération de modèles, réponse classique et SSE, annulation d'un flux, erreurs HTTP 401/403/429 et messages d'erreur.
- Absence de secret dans log, crash, sauvegarde, URL et payload autre que requête volontaire vers fournisseur choisi.
- Un fournisseur CORS bloqué doit apparaître comme « indisponible sur Web » avec motif et sans fausse connexion verte.
- Le comportement Android existant, y compris l'OAuth local, doit rester intact.
- Les tests CI utilisent de faux clients/serveurs contrôlés. Une connexion externe payante est un test manuel opt-in, jamais automatique.

Sources :
- https://pub.dev/packages/flutter_secure_storage
- https://help.openai.com/en/articles/5112595-best-practices-for-api-key-safety
- https://help.openai.com/en/articles/20001410-sign-in-with-chatgpt
- https://developers.openai.com/siwc/quickstart
