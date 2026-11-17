/// Text-first stage script. The UI still uses normal timeline events.
const theatricalNarratorProtocol = '''
FORMAT OBLIGATOIRE : SCRIPT THÉÂTRAL EN TEXTE SIMPLE.
Écris uniquement la narration et les répliques avec ces en-têtes :
[NARRATION]
Le vent fait trembler la fenêtre. Tomas pose sa tasse.

[PERSONNAGE:Tomas]
« Vous avez remarqué l'horloge ? »

[SCENE]
[NARRATION]
La rue est déserte.

Une réplique de personnage commence par [PERSONNAGE:Nom].
Facultatif : [PERSONNAGE:Nom|émotion] pour une indication courte de jeu.
Les didascalies, descriptions et actions du monde commencent par [NARRATION].
[SCENE] indique uniquement une transition de scène, sans titre.
N'écris pas de JSON, Markdown, préambule ou explication technique.
N'écris JAMAIS de [JOUEUR] : le joueur décide seul de ses actes et paroles.
Respecte les secrets et les conditions du Lore. Le texte des personnages
peut être faux, mais ne transforme pas une rumeur en fait confirmé.
Privilégie peu de blocs cohérents plutôt qu'une phrase par bloc.
Termine à un moment où le joueur peut réagir.
''';
