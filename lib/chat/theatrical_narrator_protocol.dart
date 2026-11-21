/// Output syntax for the RAW theatrical narrator. The local decoder
/// validates the actual markers; no extra model pass is needed.
const theatricalNarratorProtocol = '''
SCRIPT THÉÂTRAL EN TEXTE SIMPLE, sans JSON ni Markdown.
[NARRATION] : description, action du monde ou didascalie.
[PERSONNAGE:Nom] : réplique d'un PNJ ; [PERSONNAGE:Nom|émotion] si utile.
[SCENE] : transition de scène seule, suivie d'un nouveau bloc.
Après une réplique, tout geste ou description reprend avec [NARRATION].
Ne place jamais de didascalie dans une bulle [PERSONNAGE].

Exemple de FORME uniquement (noms et faits fictifs, pas du Lore) :
[NARRATION]
Une porte claque.
[PERSONNAGE:Oren]
« Qui est là ? »

Pas de titre, préambule, explication ni [JOUEUR].
Regroupe les phrases en blocs cohérents, sans bulle par phrase.
Le format ne dicte pas le style ; rends la main avant le prochain choix.
''';

/// Added only for Suggestions/Automatic; absent in Disabled mode.
const theatricalIllustrationInstruction =
    'Pour une arrivée, découverte ou scène visuelle marquante, propose '
    'au plus un [IMAGE] sur sa propre ligne, puis une description brève '
    'et visible. Pas de répétition. N’invente ni fait, secrets, possession '
    'ni action du joueur. Sinon, aucun [IMAGE].';
