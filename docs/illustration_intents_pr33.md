# PR33 — Intentions d'illustration (sans génération)

## Situation et base

PR32 est en brouillon au démarrage de PR33. PR33 est empilée sur
`perf/narrator-fixed-token-budget`, pas sur le `main` plus ancien.
Lors de la fusion de PR32, rebaser PR33 sur le nouveau `main` et changer
sa base GitHub. Ne fusionner aucune PR sans autorisation.

## Contrat

Une seule extension de la sortie théâtrale :

```text
[NARRATION]
Léa apparaît sur le quai.
[IMAGE]
Léa Monel sous le fanal, sa sacoche orange visible.
[NARRATION]
Elle attend.
```

Le décodeur incrémental émet `ChatIllustrationOutput`, puis le contrôleur
commite `ChatIllustrationIntent` au bon index dans `timeline_json` et
conserve le RAW original dans `raw_generations`.
Une intention a un ID d'événement stable, un `playerEventId` de source,
une description courte et un état `proposed/ignored/cancelled/queued`.
Sa position est celle de l'événement dans la timeline.
Les générations d'image futures seront enregistrées séparément et pourront
référencer cet ID (relation un-à-plusieurs).

Les intentions vides ou redondantes au sein d'une réponse sont ignorées ;
la première seule est retenue. Une réponse sans image reste valide.
Les previews du streaming ne révèlent pas les blocs IMAGE comme narration.
Une description de plus de 500 caractères est rejetée. Le décodage ne
transforme pas une intention en fait ni en événement narratif supplémentaire.

## Modes

- `disabled` : aucun ajout au prompt, pas d'intention affichée même si
  un modèle désobéissant en renvoie une.
- `suggestions` : autorise au plus une intention affichée, jamais d'appel
  au générateur d'images.
- `automatic` : **même comportement que Suggestions dans cette PR**.
  Aucun processus, coût, file d'attente ni bouton de génération simulé.

Un appui long sur une bulle IA ouvre « Copier » et « Illustrer ».
Le message est surligné pendant l'ouverture du menu. « Illustrer »
insère un `ChatIllustrationIntent` immédiatement après la bulle, avec
son texte (500 caractères max) comme description initiale. Cette intention
est sauvegardée avec la timeline, sans appel IA, sans modifier le RAW
original et sans doublons si une intention suit déjà directement le texte.
La réplique d'ouverture sans tour joueur ne peut pas être illustrée par
cette action car elle n'a pas de `playerEventId` d'origine.

Un nouveau Livre choisit Suggestions ; les anciens JSON de Livre sans
ce réglage sont importés en Disabled pour éviter un changement silencieux.
Les Parties héritent du Livre ou définissent un override nullable.
Migration SQLite v12 : une unique colonne `sessions.illustration_mode`.
La timeline elle-même reste un seul JSON, atomique avec les RAW dans
`saveNarrativeSnapshot`. Suppression, régénération et rewind retirent les
intentions par la même suppression de séquence que les messages.

## Séparation narrative / coût

Le RAW original est conservé pour le diagnostic. Le contexte théâtral
est reconstruit uniquement depuis les messages/SCENE validés.
Le contexte compact, la Live Memory et les outils de recherche locale
n'incluent pas les descriptions d'images. `stripIllustrationBlocks`
exclut aussi les blocs d'image du RAW récupéré à défaut d'un résumé compact.
L'export de conversation inclut les événements d'intention en tant que
type indépendant ; la trace IA contient toujours le RAW original.

Pas de nouvel appel IA ou nouvel outil. Le protocole théâtral ajoute
une règle concise pour séparer les descriptions des bulles de PNJ, y compris
lorsque le modèle omet le marqueur. Le supplément [IMAGE] n'est envoyé que
lorsque les suggestions sont activées. Mesurer en CI les constantes
`theatricalNarratorProtocol.length` et
`theatricalIllustrationInstruction.length`. Le coût réel fournisseur
doit être mesuré par diagnostic A/B, pas estimé à partir des caractères.

## Validation « Le Registre de Sel »

Configurer un Livre de test et comparer deux Parties (Disabled et
Suggestions), à modèle et paramètres identiques :

1. « Je regarde le quai où Léa Monel apparaît pour la première fois. »
2. « Léa Monnel entre à son tour. Décris seulement ce que je peux voir. »
3. « On me propose le jeton n° 62, mais je ne le prends pas. »
4. « Je demande une promesse conditionnelle, sans déclencher sa condition. »
5. « J'écoute une rumeur sur la gardienne du fanal. »
6. « Je regarde le dossier scellé sans être autorisé à l'ouvrir. »
7. « J'attends quelques secondes dans un couloir ordinaire. »

Contrôler : au plus une image par réponse ; pas d'image systématique ;
les gestes après une réplique reviennent dans une bulle Narrateur ;
noms distincts ; aucune possession, condition réalisée, rumeur confirmée
ou secret divulgué dans les intentions. Reprendre une Partie sauvegardée,
régénérer et revenir avant une intention, puis inspecter l'export narratif
et la trace RAW. En Tool Calling, la trace de la dernière passe
est enrichie avec les bulles et les intentions validées, sans doubler
l'enregistrement de la consommation. Les diagnostics du narrateur sont
finalisés avant le déclenchement asynchrone de la Live Memory.

**Limite de PR33 :** les règles de fidélité visuelle sont des instructions
du narrateur, non une validation sémantique locale des descriptions.
La PR34 devra confronter chaque demande à des faits attestés du récit,
du Livre et de la Live Memory avant de préparer une image.

## Étapes futures (numéros à revérifier)

- PR34 : extracteur factuel borné aux faits visibles, classification
  certain/incertain/inconnu, metteur en scène responsable des choix de
  composition, garde-fou anti-ajout de faits et audit du prompt.
- PR35 : connecteur de génération d'images, profils et consentement,
  budgets explicites, files de jobs, erreurs/reprises, rendus persistés
  séparément de l'intention, mise à jour du placeholder.
- PR36 : références visuelles canoniques et états temporaires (tenues,
  accessoires, âge apparent), liaison par identifiant de personnage,
  conservation et réutilisation de références cohérentes.

Pas d'implémentation anticipée de ces étapes dans PR33.
