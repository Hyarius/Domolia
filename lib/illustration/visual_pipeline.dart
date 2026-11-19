// ignore_for_file: prefer_interpolation_to_compose_strings
import 'dart:convert';

import 'package:crypto/crypto.dart';
import '../ai/ai_provider.dart';
import '../books/book_lore.dart';
import '../chat/chat_protocol.dart';
import '../memory/live_memory.dart';

/// A historical snapshot. Never use events following the selected intent.
class VisualScene {
  const VisualScene({
    required this.intentId, required this.playerEventId,
    required this.sourceHash, required this.description,
    required this.excerpts, required this.characters,
    required this.places, required this.memoryFacts,
    required this.restrictions,
    this.partyCharacters = const {},
    this.chronology = const [],
    this.worldContext = '',
  });
  final int intentId, playerEventId;
  final String sourceHash, description;
  final List<String> excerpts, memoryFacts, restrictions;
  final List<LoreCharacter> characters;
  final List<LorePlace> places;
  /// Characters discovered during a Party without a canonical Lore entry.
  final Map<String, String> partyCharacters;
  /// Speaker-labelled, bounded recent turns ending immediately before the
  /// selected [IMAGE] marker. Keep these separate from timeless Lore.
  final List<String> chronology;
  /// Public world basics only. Never include author secrets or future turns.
  final String worldContext;

  String get evidence => [
    'INSTANT À ILLUSTRER (prioritaire) : ' + description,
    'La pose et le mouvement doivent correspondre à cet instant exact.',
    if (chronology.isNotEmpty)
      'CONTINUITÉ AVANT CET INSTANT (chronologique, pas des actions à cumuler) :',
    ...chronology.map((e) => 'Tour : ' + e),
    if (chronology.isEmpty) ...excerpts.map((e) => 'Scène : ' + e),
    if (worldContext.isNotEmpty) 'Univers (contexte, pas une action) : ' + worldContext,
    ...characters.map((e) => 'Personnage canonique ' + e.id + ' (' + e.name +
        ') — apparence : ' + VisualSceneSelector._short(e.appearance) +
        (e.description.trim().isEmpty ? '' :
          ' ; description : ' + VisualSceneSelector._short(e.description)) +
        ' ; rôle : ' + e.role),
    ...partyCharacters.entries.map((e) => 'Personnage de Partie ' + e.key + ' (' + e.value + ')'),
    ...places.map((e) => 'Lieu canonique ' + e.id + ' (' + e.name + ') : ' +
        VisualSceneSelector._short(e.description) + ' ; éléments : ' +
        VisualSceneSelector._short(e.features)),
    ...memoryFacts.map((e) => 'Mémoire visuelle confirmée : ' + e),
    ...restrictions.map((e) => 'Élément non établi / incertain : ' + e),
  ].join('\n');
}

class VisualSceneSelector {
  const VisualSceneSelector();

  VisualScene select({
    required ChatIllustrationIntent intent,
    required List<ChatTimelineEvent> timeline,
    required BookLore lore,
    Iterable<LiveMemoryFact> memory = const [],
  }) {
    final position = timeline.indexWhere(
        (e) => e is ChatIllustrationIntent && e.id == intent.id);
    if (position < 0) throw StateError('Intention disparue.');
    final found = timeline[position] as ChatIllustrationIntent;
    if (found.playerEventId != intent.playerEventId ||
        found.description != intent.description) {
      throw StateError('Intention modifiée.');
    }
    final previous = timeline.take(position).toList();
    final boundary = previous.lastIndexWhere((e) => e is ChatSceneChange);
    final sceneMessages = previous.skip(boundary + 1)
        .whereType<ChatEntry>().toList();
    // Ten turns preserve a short physical action spanning several messages,
    // while staying bounded for inexpensive director calls.
    final messages = sceneMessages.reversed.take(10).toList().reversed.toList();
    final excerpts = <String>[];
    final chronology = <String>[];
    final restrictions = <String>[];
    for (final message in messages) {
      final value = _recentExcerpt(message.text.trim());
      if (value.isEmpty) continue;
      if (_uncertain(value)) {
        restrictions.add(value);
      } else {
        excerpts.add(value);
        final speaker = message.speaker == ChatSpeaker.player
            ? 'Joueur' : message.speaker == ChatSpeaker.narrator
                ? 'Narrateur' : message.name;
        chronology.add(speaker + ' : ' + value);
      }
    }
    // The [IMAGE] intent is a committed player-facing request. Keep it
    // unchanged even when it mentions uncertainty or a conditional event.
    // Historical context may be qualified, but must never veto the slot.
    final description = found.description;
    final visible = [description, ...excerpts].join('\n');
    // A named actor may have been introduced earlier in the same continuous
    // scene, even if the final short instruction only uses a pronoun.
    final sceneNames = sceneMessages.reversed.take(24)
        .map((e) => e.text).join('\n');
    final relevantText = visible + '\n' + sceneNames;
    final characters = <LoreCharacter>[
      for (final c in lore.characters)
        if (_mentioned(relevantText, [c.name, ...c.aliases])) c,
    ].take(5).toList();
    final partyCharacters = <String, String>{};
    final speakers = sceneMessages
        .where((e) => e.speaker == ChatSpeaker.character)
        .toList().reversed;
    for (final entry in speakers) {
      final name = entry.name.trim();
      if (name.isEmpty || name.length > 90) continue;
      final id = 'party:' + _slug(name);
      if (id == 'party:') continue;
      partyCharacters.putIfAbsent(id, () => name);
      if (partyCharacters.length >= 5) break;
    }
    // Names from confirmed Party memory also identify visually described
    // characters who have not spoken in this scene.
    for (final fact in memory) {
      if (partyCharacters.length >= 5) {
        break;
      }
      if (fact.category != 'character' ||
          !fact.entityId.startsWith('party:') ||
          fact.sourceTurnId > intent.playerEventId ||
          fact.certainty != 'confirmed' ||
          fact.visibility != 'player' ||
          !_mentioned(relevantText, [fact.label])) {
        continue;
      }
      partyCharacters.putIfAbsent(fact.entityId, () => fact.label);
    }
    final places = <LorePlace>[
      for (final p in lore.places)
        if (_mentioned(relevantText, [p.name, ...p.aliases])) p,
    ].take(4).toList();
    final eligibleMemory = memory.where((m) =>
        m.sourceTurnId <= intent.playerEventId &&
        m.certainty == 'confirmed' && m.visibility == 'player' &&
        !_uncertain(m.text) &&
        (_mentioned(relevantText, [m.label]) ||
         (m.category == 'character' &&
             (partyCharacters.containsKey(m.entityId) ||
              characters.any((c) => c.id == m.entityId))) ||
         (m.category == 'place' &&
             places.any((p) => p.id == m.entityId)))).toList()
      ..sort((a, b) {
        // Prefer recent clothing/pose/appearance, then other confirmed facts.
        final aVisual = a.field.startsWith('visual_') ? 1 : 0;
        final bVisual = b.field.startsWith('visual_') ? 1 : 0;
        if (aVisual != bVisual) return bVisual.compareTo(aVisual);
        return b.sourceTurnId.compareTo(a.sourceTurnId);
      });
    final facts = <String>[
      for (final m in eligibleMemory.take(10))
        m.label + ' (' + m.field + ') : ' + _short(m.text),
    ];
    final stableEvidence = jsonEncode({
      'intent': [found.id, found.playerEventId, found.description],
      'history': previous.map((e) {
        if (e is ChatEntry) return [e.id, e.speaker.name, e.text];
        return [e.id, e.runtimeType.toString()];
      }).toList(),
    });
    return VisualScene(
      intentId: found.id, playerEventId: found.playerEventId,
      sourceHash: sha256.convert(utf8.encode(stableEvidence)).toString(),
      description: description, excerpts: List.unmodifiable(excerpts),
      characters: List.unmodifiable(characters),
      places: List.unmodifiable(places),
      memoryFacts: List.unmodifiable(facts),
      restrictions: List.unmodifiable(restrictions),
      partyCharacters: Map.unmodifiable(partyCharacters),
      chronology: List.unmodifiable(chronology),
      worldContext: [
        lore.global.universe.trim(),
        lore.global.era.trim(),
      ].where((e) => e.isNotEmpty).join(' ; '),
    );
  }

  static String _slug(String value) {
    final ascii = value.toLowerCase()
        .replaceAll(RegExp(r'[àâä]'), 'a')
        .replaceAll(RegExp(r'[éèêë]'), 'e')
        .replaceAll(RegExp(r'[îï]'), 'i')
        .replaceAll(RegExp(r'[ôö]'), 'o')
        .replaceAll(RegExp(r'[ùûü]'), 'u')
        .replaceAll('ç', 'c');
    return ascii.replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  static bool _mentioned(String text, Iterable<String> names) =>
      names.any((name) => name.trim().length >= 2 &&
          RegExp(r'(^|[^A-Za-zÀ-ÿ0-9])' + RegExp.escape(name.trim()) +
              r'($|[^A-Za-zÀ-ÿ0-9])', caseSensitive: false)
              .hasMatch(text));

  /// A conservative quarantine; not a general semantic truth checker.
  static bool _uncertain(String value) => RegExp(
      r'(rumeur|on raconte|on prétend|non accepté|pas accepté|'
      r'propos[ée] mais|conditionnel|si jamais|pourrait|'
      r'dossier scellé|enveloppe scellée|secret|'
      r'n.a pas encore|ne possède pas)',
      caseSensitive: false).hasMatch(value);

  // Long narrative messages often establish a place at the beginning and
  // finish with the precise physical action that an image must capture.
  // Preserve both instead of chopping off the latest movement.
  static String _recentExcerpt(String value) =>
      value.length <= 600 ? value
          : value.substring(0, 160) + ' […] ' +
              value.substring(value.length - 420);

  static String _short(String value) =>
      value.length <= 600 ? value : value.substring(0, 600);
}

/// Bounded, visual-only shot description. Source evidence stays in the
/// director request; the image model receives no transcript or dialogue.
/// An IA proposal, not a committed detail until the player approves it.
class VisualCharacterAppearance {
  const VisualCharacterAppearance({
    required this.id, required this.identity, required this.current,
  });
  final String id, identity, current;

  static VisualCharacterAppearance parse(Object? value, VisualScene scene) {
    if (value is! Map<String, dynamic> ||
        value.keys.toSet().difference(const {'id','identity','current'})
            .isNotEmpty ||
        value['id'] is! String) {
      throw const FormatException('Apparence de personnage invalide.');
    }
    final id = value['id'] as String;
    final allowed = {
      ...scene.characters.map((c) => c.id),
      ...scene.partyCharacters.keys,
    };
    if (!allowed.contains(id)) {
      throw const FormatException('Personnage visuel inconnu.');
    }
    String field(Object? text) {
      if (text is! String || text.trim().isEmpty || text.length > 250) {
        throw const FormatException('Description d’apparence invalide.');
      }
      return VisualDirection._visualField(text, scene);
    }
    return VisualCharacterAppearance(id: id,
        identity: field(value['identity']), current: field(value['current']));
  }
}

class VisualDirection {
  const VisualDirection({
    required this.prompt,
    this.negativePrompt = '',
    this.appearances = const [],
  });

  /// Written directly by the director for the image model, not assembled from
  /// an intermediate shot checklist or the raw narrative transcript.
  final String prompt, negativePrompt;

  /// Optional visual proposals, explicitly approved before becoming Party
  /// memory. These metadata never appear as technical fields in the prompt.
  final List<VisualCharacterAppearance> appearances;

  factory VisualDirection.parse(String raw, VisualScene scene) {
    // Tolerate one Markdown JSON fence, not arbitrary surrounding prose.
    var source = raw.trim();
    if (source.startsWith('```')) {
      final fenced = RegExp(
        r'^```(?:json)?[ \t]*\r?\n([\s\S]*?)\r?\n```$',
        caseSensitive: false,
      ).firstMatch(source);
      if (fenced == null) {
        throw const FormatException('Réponse de direction artistique non JSON.');
      }
      source = fenced.group(1)!.trim();
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(source) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('Réponse de direction artistique non JSON.');
    }
    if (data.keys.toSet().difference(
          const {'prompt', 'negativePrompt', 'appearances'},
        ).isNotEmpty ||
        data['prompt'] is! String ||
        (data['negativePrompt'] != null &&
            data['negativePrompt'] is! String)) {
      throw const FormatException('Structure de mise en scène invalide.');
    }

    final prompt = _validateVisualText(
      data['prompt'] as String, scene, maxLength: 6000,
    );
    if (prompt.length < 30) {
      throw const FormatException('Description visuelle trop courte.');
    }
    final negative = data['negativePrompt'] as String? ?? '';
    if (negative.length > 1500 ||
        RegExp(r'[\r\n]').hasMatch(negative)) {
      throw const FormatException('Exclusions visuelles invalides.');
    }

    final rawAppearances = data['appearances'];
    if (rawAppearances != null &&
        (rawAppearances is! List || rawAppearances.length > 5)) {
      throw const FormatException('Trop de personnages dans la scène.');
    }
    final appearances = [
      for (final item in (rawAppearances as List? ?? const []))
        VisualCharacterAppearance.parse(item, scene),
    ];
    if (appearances.map((a) => a.id).toSet().length != appearances.length) {
      throw const FormatException('Apparence visuelle dupliquée.');
    }
    return VisualDirection(
      prompt: prompt,
      negativePrompt: negative.trim(),
      appearances: List.unmodifiable(appearances),
    );
  }

  static String _validateVisualText(String value, VisualScene scene,
      {required int maxLength}) {
    final text = value.trim();
    if (text.isEmpty || text.length > maxLength ||
        RegExp(
          r'(\[NARRATION\]|\[PERSONNAGE|\[IMAGE\]|'
          r'texte établi\s*:|mémoire confirmée\s*:)',
          caseSensitive: false,
        ).hasMatch(text) ||
        RegExp(r'[«»“”]').hasMatch(text)) {
      throw const FormatException('Description visuelle invalide.');
    }
    // A visual prompt must not reproduce character dialogue from the story.
    final normalized = text.toLowerCase();
    for (final excerpt in scene.excerpts) {
      for (final quote in RegExp(r'«([^»]+)»|“([^”]+)”|"([^"]+)"')
          .allMatches(excerpt)) {
        final spoken = (quote.group(1) ?? quote.group(2) ??
            quote.group(3) ?? '').trim().toLowerCase();
        if (spoken.length >= 12 && normalized.contains(spoken)) {
          throw const FormatException('Dialogue recopié dans la description.');
        }
      }
    }
    return text;
  }

  static String _visualField(Object? value, VisualScene scene) {
    if (value is! String || RegExp(r'[\r\n]').hasMatch(value)) {
      throw const FormatException('Description d’apparence invalide.');
    }
    return _validateVisualText(value, scene, maxLength: 250);
  }
}

class VisualDirector {
  const VisualDirector();
  Future<VisualDirection> direct({
    required VisualScene scene,
    required AiChatProvider provider,
    required AiConfiguration connection,
    String style = 'illustration cinématographique',
    String negativePrompt = '',
  }) async {
    final raw = await provider.complete(connection, maxTokens: 1500,
      messages: [
        const AiMessage(role: 'system', content: '''
RÔLE
Tu es le metteur en scène d'UNE image fixe, pas un narrateur.
Écris un prompt visuel COURT, directement lisible par un modèle d'image.

SOURCE DE VÉRITÉ
L'INSTANT À ILLUSTRER est prioritaire. La chronologie ne sert qu'à
reconstituer le lieu, les personnes et la continuité avant cet instant.
Le Lore fixe les identités et les faits. Une proposition ou un souvenir
incertain n'est pas un fait. N'illustre jamais plusieurs instants à la fois.
En cas de contradiction sur la pose, suis l'instant demandé plutôt qu'une
ancienne mémoire visual_current. Une pose ancienne n'est pas permanente.

COMPOSITION ET GÉOMÉTRIE (priorité absolue)
Décris d'abord, en UNE ou DEUX phrases simples, les positions et
orientations des personnages : qui est assis, debout, au sol, derrière,
devant, à côté ou ENTRE qui. Situe explicitement les mains et les jambes,
les appuis et contacts physiques : QUI touche QUOI et avec QUELLE main.
Les relations spatiales doivent être non ambiguës, sans enchaînement
de mouvements. Ne déduis pas d'autre contact que celui montré.
Choisis un cadrage et un angle réellement compatibles avec la visibilité
des acteurs ; une vue subjective ne montre pas le dos du spectateur.
Décris un seul instant figé, pas des actions successives.

PERSONNAGES ET DÉCOR
Ajoute ensuite les seuls détails d'apparence utiles : âge apparent,
silhouette, visage, yeux, cheveux, tenue et accessoires établis.
Les caractéristiques physiques nécessaires mais inconnues peuvent être
proposées sobrement, jamais présentées comme faits confirmés.
N'ajoute ni personnage ni meuble gratuit. Ne garde du décor que les
éléments narrativement importants. Un fond blanc est préférable si le
lieu est inconnu en style manga ; En style réaliste, fond neutre ou flou.
En style manga, le fond blanc et quelques traits suffisent.
Tu ne remplis JAMAIS le décor inconnu avec du mobilier inventé.
Une porte et son encadrement suffisent souvent à situer un seuil.
Un palier d’immeuble ne doit pas devenir un porche extérieur.

STYLE ET LONGUEUR
Termine par un éclairage, une palette et un style brefs.
Écris de courtes phrases descriptives, PAS une liste de tags isolés :
les relations entre éléments doivent rester explicites.
Vise 300 à 700 caractères pour la description positive habituelle,
avec au plus 1100 caractères si la scène l'exige. Place les détails
ESSENTIELS en premier ; supprime les détails décoratifs en dernier.
N'évoque pas des bulles de dialogue, planches de BD, signatures ou texte
dans la description POSITIVE : mets ces exclusions dans negativePrompt.
L'image ne contient aucun dialogue ni typographie superposée.

SORTIE
Réponds UNIQUEMENT en JSON :
{"prompt":"description visuelle compacte, spatiale et concrète",
 "negativePrompt":"liste dédoublonnée de quelques exclusions, ou chaîne vide",
 "appearances":[{"id":"ID autorisé","identity":"physique stable",
                 "current":"tenue et pose"}]}
"appearances" est facultatif. N'utilise que les IDs autorisés.
N'ajoute ni Markdown, ni dialogue, ni texte visible ni pensées.
Pas de titre, pas de longues listes, pas d'instructions techniques.
'''),
        AiMessage(role: 'user',
          content: scene.evidence +
              '\nSTYLE VISUEL : ' + style +
              (negativePrompt.trim().isEmpty ? '' :
                  '\nEXCLUSIONS DU LIVRE : ' + negativePrompt) +
              '\nIDs autorisés : ' +
              [...scene.characters.map((c) => c.id),
                ...scene.partyCharacters.keys].join(', ')),
      ]);
    return VisualDirection.parse(raw, scene);
  }
}

/// Preserve the director's positive description, adding the Book style
/// only when missing. Exclusions stay separate for provider-specific handling.
String validatedImagePrompt(VisualScene scene, VisualDirection direction,
    {String style = 'illustration cinématographique',
     String negativePrompt = ''}) {
  if (style.trim().isEmpty || style.length > 160 ||
      negativePrompt.length > 1500) {
    throw const FormatException('Style invalide.');
  }
  final description = VisualDirection._validateVisualText(
      direction.prompt, scene, maxLength: 6000);
  if (description.length < 30) {
    throw const FormatException('Description visuelle trop courte.');
  }
  // Exclusions are retained separately in StoredIllustration. Some image
  // backends (Civitai) support negative_prompt; others (Venice) ignore it.
  // Never repeat negative words in the positive prompt.
  // The Book's requested visual style remains effective even if the
  // director omits the exact expression in its natural-language prompt.
  final visualStyle = style.trim();
  final styled = description.toLowerCase().contains(visualStyle.toLowerCase())
      ? description : description + ' ' + visualStyle + '.';
  return styled;
}
