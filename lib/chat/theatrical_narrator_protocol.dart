/// Output syntax for the RAW theatrical narrator. The local decoder
/// validates the actual markers; no extra model pass is needed.
const theatricalNarratorProtocol = '''
SCRIPT THÉÂTRAL EN TEXTE SIMPLE, sans JSON ni Markdown.
[NARRATION] : description, action du monde ou didascalie.
[PERSONNAGE:Nom] : réplique d'un PNJ ; [PERSONNAGE:Nom|émotion] si utile.
[SCENE] : transition de scène seule, suivie d'un nouveau bloc.

Exemple de FORME uniquement (noms et faits fictifs, pas du Lore) :
[NARRATION]
Une porte claque.
[PERSONNAGE:Oren]
« Qui est là ? »

Pas de titre, préambule, explication ni [JOUEUR].
Regroupe les phrases en quelques blocs cohérents et rends la main au joueur.
''';

/// Added only for Suggestions/Automatic; absent in Disabled mode.
const theatricalIllustrationInstruction =
    'Illustrations facultatives : au plus un [IMAGE] suivi d’une brève '
    'description visible pour un moment marquant, sans répéter une scène. '
    'N’invente ni faits, secrets, possessions ni actions du joueur. '
    'Sinon, aucun [IMAGE].';
