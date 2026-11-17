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
  });
  final int intentId, playerEventId;
  final String sourceHash, description;
  final List<String> excerpts, memoryFacts, restrictions;
  final List<LoreCharacter> characters;
  final List<LorePlace> places;

  String get evidence => [
    'Intention : ' + description,
    ...excerpts.map((e) => 'Scène : ' + e),
    ...characters.map((e) => 'Personnage ' + e.id + ': ' + e.appearance),
    ...places.map((e) => 'Lieu ' + e.id + ': ' + e.features),
    ...memoryFacts.map((e) => 'Fait confirmé : ' + e),
    ...restrictions.map((e) => 'Interdiction : ' + e),
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
    final messages = previous.skip(boundary + 1)
        .whereType<ChatEntry>().toList()
        .reversed.take(6).toList().reversed.toList();
    final excerpts = <String>[];
    final restrictions = <String>[];
    for (final message in messages) {
      final value = _short(message.text.trim());
      if (value.isEmpty) continue;
      if (_uncertain(value)) {
        restrictions.add(value);
      } else {
        excerpts.add(value);
      }
    }
    if (_uncertain(found.description)) restrictions.add(found.description);
    final description = _uncertain(found.description)
        ? '' : found.description;
    final visible = [description, ...excerpts].join('\n');
    final characters = <LoreCharacter>[
      for (final c in lore.characters)
        if (_mentioned(visible, [c.name, ...c.aliases])) c,
    ];
    final places = <LorePlace>[
      for (final p in lore.places)
        if (_mentioned(visible, [p.name, ...p.aliases])) p,
    ];
    final facts = <String>[
      for (final m in memory)
        if (m.sourceTurnId <= intent.playerEventId &&
            m.certainty == 'confirmed' && m.visibility == 'player' &&
            _mentioned(visible, [m.label]) && !_uncertain(m.text))
          _short(m.text),
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
    );
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

  static String _short(String value) =>
      value.length <= 600 ? value : value.substring(0, 600);
}

/// Only camera and artistic choices can be supplied by the LLM.
/// Free-form narrative additions are not accepted in the schema.
class VisualDirection {
  const VisualDirection({
    required this.shot, required this.angle, required this.focusIds,
    required this.composition, required this.lighting,
    required this.palette, required this.mood,
  });
  final String shot, angle, composition, lighting, palette, mood;
  final List<String> focusIds;

  static const shots = ['wide', 'medium', 'closeup'];
  static const angles = ['eye_level', 'high', 'low', 'over_shoulder'];
  static const compositions = ['rule_of_thirds', 'centered', 'leading_lines'];
  static const lightings = ['natural', 'soft', 'dramatic'];
  static const palettes = ['warm', 'cool', 'neutral', 'muted'];
  static const moods = ['calm', 'tense', 'mysterious', 'joyful', 'melancholic'];

  factory VisualDirection.parse(String raw, VisualScene scene) {
    Map<String, dynamic> data;
    try {
      data = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('Réponse de direction artistique non JSON.');
    }
    if (data.keys.toSet().difference(const {
      'shot','angle','focusIds','composition','lighting','palette','mood',
    }).isNotEmpty ||
        !shots.contains(data['shot']) || !angles.contains(data['angle']) ||
        !compositions.contains(data['composition']) ||
        !lightings.contains(data['lighting']) ||
        !palettes.contains(data['palette']) ||
        !moods.contains(data['mood']) ||
        data['focusIds'] is! List ||
        (data['focusIds'] as List).length > 5 ||
        (data['focusIds'] as List).any((e) => e is! String)) {
      throw const FormatException('Structure de mise en scène invalide.');
    }
    final allowed = scene.characters.map((c) => c.id).toSet();
    final focused = (data['focusIds'] as List).cast<String>();
    if (focused.toSet().length != focused.length ||
        focused.any((id) => !allowed.contains(id))) {
      throw const FormatException('Personnage inventé par le metteur en scène.');
    }
    return VisualDirection(
      shot: data['shot'] as String,
      angle: data['angle'] as String,
      focusIds: List.unmodifiable(focused),
      composition: data['composition'] as String,
      lighting: data['lighting'] as String,
      palette: data['palette'] as String,
      mood: data['mood'] as String,
    );
  }
}

class VisualDirector {
  const VisualDirector();
  Future<VisualDirection> direct({
    required VisualScene scene,
    required AiChatProvider provider,
    required AiConfiguration connection,
  }) async {
    final raw = await provider.complete(connection, maxTokens: 300,
      messages: [
        const AiMessage(role: 'system', content:
          'Tu es directeur photo. Réponds uniquement en JSON avec EXACTEMENT '
          'shot, angle, focusIds, composition, lighting, palette, mood. '
          'shot: wide/medium/closeup; angle: eye_level/high/low/over_shoulder; '
          'composition: rule_of_thirds/centered/leading_lines; '
          'lighting: natural/soft/dramatic; palette: warm/cool/neutral/muted; '
          'mood: calm/tense/mysterious/joyful/melancholic. '
          'focusIds: seulement les IDs de personnages autorisés. '
          'Ne crée aucune action, propriété, possession ou secret.'),
        AiMessage(role: 'user',
          content: scene.evidence + '\nIDs autorisés : ' +
              scene.characters.map((c) => c.id).join(', ')),
      ]);
    return VisualDirection.parse(raw, scene);
  }
}

String validatedImagePrompt(VisualScene scene, VisualDirection direction,
    {String style = 'illustration cinématographique'}) {
  if (scene.description.trim().isEmpty && scene.excerpts.isEmpty) {
    throw const FormatException('Aucun fait visuel confirmé.');
  }
  if (style.trim().isEmpty || style.length > 160) {
    throw const FormatException('Style invalide.');
  }
  return [
    'Illustration de fiction fidèle à une scène existante.',
    'Style graphique : ' + style + '.',
    'Plan : ' + direction.shot + ', angle : ' + direction.angle +
        ', composition : ' + direction.composition +
        ', éclairage : ' + direction.lighting +
        ', palette : ' + direction.palette + ', humeur : ' + direction.mood + '.',
    if (scene.description.isNotEmpty)
      'Instant à montrer : ' + scene.description,
    ...scene.excerpts.map((e) => 'Texte établi : ' + e),
    ...scene.characters.map((c) =>
        'Apparence attestée de ' + c.name + ' : ' + c.appearance),
    ...scene.places.map((p) =>
        'Lieu attesté ' + p.name + ' : ' + p.features + ' ' + p.atmosphere),
    ...scene.memoryFacts.map((e) => 'Mémoire confirmée : ' + e),
    ...scene.restrictions.map((e) =>
        'Ne pas représenter comme vrai : ' + e),
    'N’invente aucun personnage, possession, action, événement ou secret.',
  ].join('\n');
}
