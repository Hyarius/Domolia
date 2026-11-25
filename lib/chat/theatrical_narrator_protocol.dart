/// Output syntax for the RAW theatrical narrator. The local decoder
/// validates the actual markers; no extra model pass is needed.
const theatricalNarratorProtocol = '''
SCRIPT THÉÂTRAL. L'intervention du joueur a déjà eu lieu. Donne la réponse du monde, puis arrête-toi.
Pour faire parler un personnage, écris @ suivi de son nom, reviens à la ligne et écris sa réplique. Pour un geste, écris * seul puis le geste à la ligne. --- seul marque une ellipse.''';

/// Added only for Suggestions/Automatic; absent in Disabled mode.
const theatricalIllustrationInstruction =
    'Pour une arrivée, découverte ou scène visuelle marquante, propose '
    'au plus un [IMAGE] sur sa propre ligne, puis une description brève '
    'et visible. Pas de répétition. N’invente ni fait, secrets, possession '
    'ni action du joueur. Sinon, aucun [IMAGE].';
