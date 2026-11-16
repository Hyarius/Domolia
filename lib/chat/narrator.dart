/// Narration controls independent from the level of descriptive detail.
///
/// Length is an approximate word target, not a hard output-token cutoff:
/// the JSONifier must still receive an intact RAW narrative.
class NarrativeTuning {
  const NarrativeTuning({
    this.responseLength = 2,
    this.scenePacing = 2,
    this.styleKeywords = const <String>[],
  });

  /// 1 = very short, 5 = expansive. Default 2 matches interactive RP turns.
  final int responseLength;

  /// 1 = stop after the first reaction, 5 = multiple narrative beats.
  final int scenePacing;
  final List<String> styleKeywords;

  static const lengthNames = <String>[
    'Très courte', 'Courte', 'Moyenne', 'Longue', 'Très longue',
  ];
  static const lengthDescriptions = <String>[
    'Environ 45 à 90 mots, une réponse très rapide.',
    'Environ 90 à 170 mots, proche d’un échange de jeu de rôle.',
    'Environ 170 à 270 mots, une scène modérément développée.',
    'Environ 270 à 450 mots, une scène détaillée.',
    'Environ 450 à 700 mots, une séquence ample.',
  ];
  static const pacingNames = <String>[
    'Pas à pas', 'Interactif', 'Fluide', 'Soutenu', 'Cinématique',
  ];
  static const pacingDescriptions = <String>[
    'Une réaction immédiate puis une occasion pour le joueur de répondre.',
    'Un seul temps fort, puis rendre la main au joueur.',
    'Un ou deux temps forts, sans franchir une décision du joueur.',
    'Plusieurs actions liées peuvent s’enchaîner dans un même tour.',
    'Une séquence plus étendue, tant que le joueur n’a pas à décider.',
  ];
  static const keywordSuggestions = <String>[
    'Immersif', 'Dialogué', 'Sensoriel', 'Sobre', 'Poétique',
    'Tendu', 'Mystérieux', 'Humoristique',
  ];

  NarrativeTuning copyWith({
    int? responseLength,
    int? scenePacing,
    List<String>? styleKeywords,
  }) => NarrativeTuning(
    responseLength: responseLength ?? this.responseLength,
    scenePacing: scenePacing ?? this.scenePacing,
    styleKeywords: styleKeywords ?? this.styleKeywords,
  );

  /// Accept comma-separated visual tags, keeping their order without duplicates.
  static List<String> parseKeywords(String input) {
    final unique = <String>{};
    final result = <String>[];
    for (final raw in input.split(',')) {
      final keyword = raw.trim();
      if (keyword.isEmpty) continue;
      if (unique.add(keyword.toLowerCase())) result.add(keyword);
    }
    return List<String>.unmodifiable(result);
  }

  void validate() {
    if (responseLength < 1 || responseLength > 5 ||
        scenePacing < 1 || scenePacing > 5 ||
        styleKeywords.length > 8 ||
        styleKeywords.any((keyword) =>
            keyword.trim().isEmpty || keyword.length > 32 ||
            keyword.contains(',') ||
            keyword.contains('\n') || keyword.contains('\r') ||
            keyword.contains('\t')) ||
        styleKeywords.map((keyword) => keyword.toLowerCase()).toSet().length !=
            styleKeywords.length) {
      throw const FormatException(
        'Réglages narratifs invalides : niveaux de 1 à 5 et '
        '8 mots-clés de 32 caractères maximum.',
      );
    }
  }

  /// Backward-compatible with records that predate these optional fields.
  factory NarrativeTuning.fromJson(Map<String, dynamic> json) {
    final length = json.containsKey('responseLength')
        ? json['responseLength'] : 2;
    final pacing = json.containsKey('scenePacing')
        ? json['scenePacing'] : 2;
    final keywords = json.containsKey('styleKeywords')
        ? json['styleKeywords'] : <String>[];
    if (length is! int || pacing is! int || keywords is! List ||
        keywords.any((value) => value is! String)) {
      throw const FormatException('Réglages narratifs illisibles.');
    }
    final tuning = NarrativeTuning(
      responseLength: length,
      scenePacing: pacing,
      styleKeywords: List<String>.unmodifiable(keywords.cast<String>()),
    );
    tuning.validate();
    return tuning;
  }

  Map<String, Object?> toJson() => {
    'responseLength': responseLength,
    'scenePacing': scenePacing,
    'styleKeywords': styleKeywords,
  };

  String get prompt {
    validate();
    final length = <String>[
      'Vise 45 à 90 mots : une réponse très brève.',
      'Vise environ 90 à 170 mots : une réponse courte et réactive.',
      'Vise environ 170 à 270 mots : une réponse de longueur moyenne.',
      'Vise environ 270 à 450 mots : une réponse développée.',
      'Vise environ 450 à 700 mots : une réponse ample.',
    ][responseLength - 1];
    final pacing = <String>[
      'Raconte uniquement la conséquence immédiate de l’action du joueur. '
          'Arrête-toi au premier instant où il peut intervenir.',
      'Avance d’un seul temps fort (réaction, réplique ou petite action), '
          'puis rends la main au joueur.',
      'Avance d’un ou deux temps forts cohérents, puis laisse le joueur agir.',
      'Tu peux enchaîner plusieurs événements liés avant de rendre la main.',
      'Tu peux raconter une séquence plus étendue si aucune décision du '
          'joueur n’est nécessaire entre-temps.',
    ][scenePacing - 1];
    return [
      'Rythme de ce tour : $length Il s’agit d’une cible indicative, '
          'pas d’une obligation de remplir une longueur.',
      pacing,
      'Ne joue jamais à la place du personnage joueur. Ne dépasse pas un '
          'moment où son choix ou sa réaction est attendu. Termine sur une '
          'possibilité naturelle de répondre, sans poser systématiquement '
          '« Que faites-vous ? » ni proposer un menu d’options.',
      if (styleKeywords.isNotEmpty)
        'Couleur littéraire souhaitée (mots-clés descriptifs, non '
            'instructions techniques) : ${styleKeywords.join(', ')}.',
    ].join('\n');
  }
}

/// Literary instructions only. The output protocol belongs to Jsonifier.
class Narrator {
  const Narrator({
    this.protocolPrompt = defaultNarratorProtocolPrompt,
    this.narrativePrompt = defaultNarratorNarrativePrompt,
    this.openingMessages = defaultNarratorOpeningMessages,
    this.tuning = const NarrativeTuning(),
  });

  /// Historical property name kept for saved settings and callers. It now
  /// contains only role-playing rules, not a technical output format.
  final String protocolPrompt;
  final String narrativePrompt;
  final List<String> openingMessages;
  final NarrativeTuning tuning;

  String get systemPrompt => [
    protocolPrompt.trim(),
    narrativePrompt.trim(),
    tuning.prompt,
  ].where((part) => part.isNotEmpty).join('\n\n');
}

const defaultNarratorProtocolPrompt = '''
Tu écris directement une histoire de jeu de rôle en français, en texte libre.
Tu interprètes les personnages et le monde, mais jamais le personnage joueur.
Le joueur est « Vous ». N'invente ni ses paroles, ni ses pensées, ni ses actions,
ni ses décisions. Garde les personnages, les lieux et les faits cohérents.
Exprime naturellement la narration et les dialogues, sans format informatique.
''';

const defaultNarratorNarrativePrompt = '''
Tu es l'orchestrateur d'une conversation de jeu de rôle en français.
Tu interprètes le narrateur et les personnages ; tu contrôles les décors,
les réactions du monde et le déroulement de l'histoire.
Ne prends jamais le contrôle du personnage joueur.
Tu peux faire intervenir plusieurs personnages dans un même tour.
Les changements de lieu et de temps doivent rester naturels et cohérents.
Adapte la densité de description au Livre et au rythme configurés.
Ne produis ni JSON, ni balises, ni instructions destinées à une interface.
''';

const defaultNarratorOpeningMessages = <String>[
  'Une nouvelle histoire commence. Que souhaitez-vous faire ?',
  'Le monde s’ouvre devant vous. Par quoi voulez-vous commencer ?',
];
