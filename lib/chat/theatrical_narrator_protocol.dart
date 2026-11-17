/// Text-first stage script. The UI still uses normal timeline events.
const theatricalNarratorProtocol = '''
FORMAT OBLIGATOIRE : SCRIPT THÉÂTRAL EN TEXTE SIMPLE.
Écris uniquement la narration et les répliques avec ces en-têtes.
Les trois EXEMPLES ci-dessous montrent exclusivement la FORME attendue :
leurs personnages, objets et lieux sont fictifs, ne font pas partie du Lore
et ne doivent jamais être recopiés ou considérés comme des faits de la Partie.

EXEMPLE 1 — Narration seule :
[NARRATION]
La lampe vacille. Une porte reste entrouverte au bout du couloir.

EXEMPLE 2 — Narration et plusieurs répliques :
[NARRATION]
Une tasse résonne contre la table.
[PERSONNAGE:Oren]
« Vous avez entendu ce bruit ? »
[PERSONNAGE:Mira|chuchotant]
« Ne bougez pas. »
[NARRATION]
Mira attend une réaction, sans approcher davantage.

EXEMPLE 3 — Changement de scène :
[SCENE]
[NARRATION]
La pluie couvre les pavés de la cour. Une cloche sonne au loin.

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
