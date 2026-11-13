# Domolia — Plan d'implémentation du jeu de rôle

## Vision du produit

**Domolia** est une application Android locale, en **français**, pour vivre des aventures narratives libres : explorer des mondes, rencontrer et créer des personnages, construire des relations, traverser la vie quotidienne et vivre des histoires romantiques ou adultes selon les préférences choisies.

L'utilisateur contrôle **son personnage**. Le narrateur contrôle l'environnement et les autres protagonistes, pas les décisions ni les actions du personnage joueur. Les événements, relations, objets, lieux et souvenirs validés persistent entre les sessions. Les illustrations sont **optionnelles** et dérivées de faits de scène fidèles.

L'application est exécutée sur le téléphone avec des données locales (SQLite et fichiers). L'inférence IA est distante, via **OpenUncensored** dans un premier temps. L'architecture doit toutefois permettre de remplacer le fournisseur sans réécrire le moteur RP.

## Organisation

- **Un fichier par PR logique :** `PR01.md` à `PR17.md`. Le numéro indique l'ordre d'implémentation souhaité, **pas** le numéro GitHub de la PR.
- Chaque fichier définit une amélioration réellement visible sur le téléphone, son périmètre, ses invariants, ses critères d'acceptation et ses exclusions.
- Commencer une PR à partir de la version validée de `main`, créer une branche distincte et publier son APK de préversion via GitHub Actions.
- Garder **une seule livraison produit** par PR autant que possible ; toute nouvelle capacité modifiant le modèle de données doit être accompagnée de migrations et tests.
- **Ne pas fusionner automatiquement** : le propriétaire valide les PR.

## Jalons

| Jalon | Livrable utilisateur | PR |
| --- | --- | --- |
| Infrastructure existante | APK signé, interface Domolia, CI et releases | [PR01](PR01.md) — **fusionnée** |
| Installation et premier jeu | Mise à jour dans l'app, connexion IA, chat et aventures sauvegardées | [PR02](PR02.md) à [PR05](PR05.md) |
| Narration et monde vivant | Narrateur libre, mondes, contexte, PNJ et mémoires durables | [PR06](PR06.md) à [PR10](PR10.md) |
| Continuité et maîtrise | Scènes, déplacements, journal, relations, alternatives narratives | [PR11](PR11.md) à [PR13](PR13.md) |
| Illustrations fidèles | Extraction de scène, génération sur demande, canon visuel | [PR14](PR14.md) à [PR16](PR16.md) |
| Premier jalon complet | Export/restauration et validation de bout en bout | [PR17](PR17.md) |

## Liste complète des évolutions

- **[PR01 — Socle Android, identité et distribution](PR01.md)** — fusionnée : Domolia s'installe sur Android avec son thème vert/or et un canal GitHub de préversions utilisables.
- **[PR02 — Mise à jour Android depuis l'application](PR02.md)** : L'utilisateur découvre une nouvelle préversion, la télécharge dans Domolia et peut lancer son installation sans visiter GitHub manuellement.
- **[PR03 — Connexion sécurisée à OpenUncensored](PR03.md)** : Depuis les paramètres, l'utilisateur configure sa clé OpenUncensored, sélectionne un modèle et vérifie que la connexion fonctionne.
- **[PR04 — Premier chat narratif utilisable](PR04.md)** : L'utilisateur peut écrire des actions et recevoir une narration en français, progressivement, depuis son téléphone.
- **[PR05 — Aventures et conversations persistantes](PR05.md)** : Les aventures peuvent être créées, nommées, rouvertes et poursuivies après fermeture de Domolia.
- **[PR06 — Narrateur RP, liberté du joueur et préférences](PR06.md)** : Le chat devient un véritable jeu de rôle narratif en français : aventures, exploration, quotidien et relations, sans voler les décisions du personnage joueur.
- **[PR07 — Création de monde, aventure et personnage joueur](PR07.md)** : L'utilisateur façonne le cadre de son aventure et définit son personnage avant de commencer à jouer.
- **[PR08 — Constructeur de contexte et continuité narrative](PR08.md)** : Le narrateur reçoit automatiquement les informations pertinentes sur l'aventure, sans devoir relire tout l'historique à chaque tour.
- **[PR09 — Répertoire de PNJ et de lieux, éditable](PR09.md)** : Créer soi-même des PNJ, des lieux et des relations simples depuis un carnet du monde, puis les retrouver dans l'histoire.
- **[PR10 — Mémoire automatique, événements et nouveaux PNJ](PR10.md)** : Domolia suggère de mémoriser les événements importants, et détecte les nouveaux PNJ/lieux sans casser la continuité.
- **[PR11 — État de scène, déplacements et chronologie](PR11.md)** : Le monde suit où sont les gens, quand se déroulent les événements et ce qui a changé physiquement dans la scène.
- **[PR12 — Journal de vie, relations et possessions](PR12.md)** : Les liens affectifs, engagements, possessions et décisions passées deviennent consultables et réutilisables dans le RP.
- **[PR13 — Régénération, corrections et chemins alternatifs](PR13.md)** : L'utilisateur peut corriger une narration, régénérer une réponse ou explorer une autre branche de son aventure sans mélanger leurs souvenirs.
- **[PR14 — Extraction visuelle fidèle des scènes RP](PR14.md)** : Un bouton « Illustrer cette scène » prépare une description factuelle de l'instant final de la narration, avant toute génération d'image.
- **[PR15 — Premières illustrations avec OpenUncensored](PR15.md)** : L'utilisateur génère une illustration à la demande directement depuis sa scène RP et peut la conserver dans l'aventure.
- **[PR16 — Canon visuel, références et galerie d'aventures](PR16.md)** : Les personnages conservent leur apparence d'une illustration à l'autre, et l'utilisateur peut gérer leurs références visuelles.
- **[PR17 — Sauvegardes, fiabilité et premier jalon produit](PR17.md)** : Domolia devient une application personnelle utilisable durablement : ses aventures, mondes, mémoires et illustrations peuvent être sauvegardés et restaurés.

## Invariants communs

1. **Souveraineté du joueur :** jamais de paroles, pensées, décisions ou actions inventées pour son personnage.
2. **Sources de vérité :** fiches et faits validés par l'utilisateur > propositions de mémoire > prose générée ; une proposition non validée ne remplace pas une donnée validée.
3. **Temporalité et présence :** les participants, déplacements, habits et interactions doivent décrire le même instant ; un personnage absent ne devient pas présent par simple proximité.
4. **Vie privée :** clé API dans le stockage sécurisé Android ; aucune clé ni conversation exportée dans les logs ; pas de service central Domolia.
5. **Contenu choisi :** niveau de maturité paramétrable par aventure ; les scènes intimes n'impliquent que des adultes et suivent les préférences de l'utilisateur et les conditions du fournisseur.
6. **Explicabilité :** chaque extraction de faits persistants a une provenance, une validation et une possibilité de correction/annulation.
7. **IA interchangeable :** commencer avec OpenUncensored, ne pas mêler les contrats réseau à la logique du jeu ou aux Widgets.
8. **Robustesse :** toutes les étapes réseau peuvent échouer sans corrompre les aventures ; la génération d'images ne doit pas modifier la mémoire.
9. **Validation :** analyse Flutter, tests automatisés, APK signé de branche et scénario manuel réaliste sur téléphone pour chaque PR.

## Définition de « prêt à fusionner »

Une PR est prête à être revue quand elle propose une fonctionnalité immédiatement testable, documente ses éventuelles migrations, inclut les tests nécessaires, passe GitHub Actions et rend un APK de branche disponible. La fusion demeure une **action explicitement autorisée par le propriétaire**.

## Points à vérifier pendant le développement

- Les identifiants des modèles et leurs paramètres API OpenUncensored peuvent évoluer : vérifier la compatibilité au moment de chaque intégration.
- Les appels IA et images ont un coût distant ; les fonctions de génération restent explicites et leur consommation visible quand la donnée existe.
- Le vocabulaire *mémoire*, *fait*, *événement*, *état de scène*, *canon* et *historique narratif* doit rester distinct dans le code et les écrans.
