/// Output syntax for the RAW theatrical narrator. The local decoder
/// validates the actual markers; no extra model pass is needed.
const theatricalNarratorProtocol = '''
SCRIPT THÉÂTRAL. Marqueur seul sur une ligne, texte dessous.
@Nom pour les paroles du PNJ, * pour un geste ou le décor, --- pour une ellipse. Après une réplique, repasse à * avant tout geste.
N’écris jamais @Joueur.''';

/// Added only for Suggestions/Automatic; absent in Disabled mode.
const theatricalIllustrationInstruction =
    'Pour une arrivée, découverte ou scène visuelle marquante, propose '
    'au plus un [IMAGE] sur sa propre ligne, puis une description brève '
    'et visible. Pas de répétition. N’invente ni fait, secrets, possession '
    'ni action du joueur. Sinon, aucun [IMAGE].';
