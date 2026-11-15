import 'dart:convert';

import 'chat_protocol.dart';
import 'dialogue_parts.dart';

/// The formatter labels stable, Dart-numbered RAW blocks, never positions.
/// Dart owns the original text and reconstructs every character unchanged.
const jsonifierSystemPrompt = '''
Tu es le JSONificateur de Domolia. Tu ne rédiges AUCUNE histoire.
Renvoie uniquement un objet JSON : {"events":[...]}.
Domolia découpe le RAW en PARTIES numérotées exactes, certaines étant des
citations entre « » ; tu n'as ni texte ni indices de caractères à inventer.
Renvoie EXACTEMENT un événement "part" par partie, dans l'ordre, sans omission.
Formats stricts :
{"type":"part","part":0,"kind":"narration"}
{"type":"part","part":1,"kind":"dialogue","name":"Liv","status":"étonnée"}
{"type":"part","part":2,"kind":"aside"}
{"type":"scene_change","before":3}
Le "kind" vaut "narration", "dialogue" ou "aside".
- Dialogue : seules les paroles PRONONCÉES doivent apparaître dans la bulle
  du personnage. Domolia retire mécaniquement les « » des citations.
  Un passage de prose sans guillemets peut être un dialogue UNIQUEMENT
  sous la forme explicite "Nom : paroles".
- Narration : tout texte racontant un fait indépendant ou faisant avancer
  la scène, sans inventer ou réécrire la source.
- Aside : indication de locuteur, ponctuation autour des citations, incise
  purement rédactionnelle ("dit-elle", "ajouta-t-elle") ou courte réaction
  expressive transférée dans le statut de la réplique voisine.
  Ne masque JAMAIS un événement important, une action indépendante, une
  information narrative, ni un paragraphe dépourvu de dialogue adjacent.
- "status" est facultatif et UNIQUEMENT pour "dialogue". Il décrit brièvement
  une émotion, une expression, une attitude ou une manière de parler que
  le RAW permet de déduire : "étonnée", "attristée", "murmurant",
  "les yeux baissés". Ne mets jamais "ajouta-t-elle"/"répondit-elle".
  Ne déduis aucun état absent de la scène ; omets-le si non justifié.
- "name" : personnage réel identifié dans le RAW ou contexte antérieur,
  jamais le joueur. Une citation non attribuable peut rester en narration.
- "scene_change" se place juste AVANT une partie en cas de rupture majeure
  de lieu, temps ou séquence, pas au simple changement de locuteur.
N'ajoute jamais "text", start/end, commentaire, Markdown, ni autres champs.
''';

class Jsonifier {
  const Jsonifier();

  /// Split RAW into exact, immutable narrative paragraphs. Trailing separators
  /// belong to the preceding paragraph, including CRLF and blank-line spaces.
  /// Never reflow, normalize, trim or retype the author's original text.
  List<String> blocks(String raw) {
    if (raw.isEmpty) return const [];
    final paragraphs = <String>[];
    var start = 0;
    final separator = RegExp(r'\r?\n(?:[ \t]*\r?\n)+');
    for (final match in separator.allMatches(raw)) {
      if (raw.substring(start, match.start).trim().isEmpty) continue;
      paragraphs.add(raw.substring(start, match.end));
      start = match.end;
    }
    if (start < raw.length) {
      final tail = raw.substring(start);
      if (tail.trim().isNotEmpty || paragraphs.isEmpty) {
        paragraphs.add(tail);
      } else {
        paragraphs[paragraphs.length - 1] += tail;
      }
    }
    // Keep generated JSON bounded even for extremely short paragraphs.
    if (paragraphs.length <= 80) return List.unmodifiable(paragraphs);
    final grouped = <String>[];
    final stride = (paragraphs.length + 79) ~/ 80;
    for (var i = 0; i < paragraphs.length; i += stride) {
      final end = i + stride < paragraphs.length
          ? i + stride : paragraphs.length;
      grouped.add(paragraphs.sublist(i, end).join());
    }
    return List.unmodifiable(grouped);
  }

  /// Source-owned subdivisions allow several separate character messages
  /// inside one literary paragraph, without model-computed offsets.
  List<RawDialoguePart> parts(String raw) =>
      const DialogueParts().split(blocks(raw));

  String partsForPrompt(String raw) =>
      const DialogueParts().forPrompt(parts(raw));

  String blocksForPrompt(String raw) => [
    for (final (index, block) in blocks(raw).indexed)
      'Bloc $index : ${jsonEncode(block)}',
  ].join('\n');

  /// [knownCharacters] includes only names seen in the session history.
  /// Unknown character names must appear in the source itself.
  List<ChatOutputEvent> decode(
    String raw,
    String response, {
    Iterable<String> knownCharacters = const [],
    bool hasPreviousScene = true,
  }) {
    if (raw.trim().isEmpty || raw.length > 131072 ||
        response.length > 131072) {
      throw const FormatException('Texte RAW ou conversion vide ou excessif.');
    }
    dynamic parsed;
    try {
      parsed = jsonDecode(response.trim());
    } catch (_) {
      throw const FormatException('JSONification : réponse JSON malformée.');
    }
    if (parsed is! Map<String, dynamic> ||
        parsed.length != 1 || parsed['events'] is! List) {
      throw const FormatException('JSONification : enveloppe invalide.');
    }
    final items = parsed['events'] as List;
    if (items.isEmpty || items.length > 120) {
      throw const FormatException('JSONification : nombre d’événements invalide.');
    }
    if (items.any((item) => item is Map && item['type'] == 'part')) {
      return const DialogueParts().decode(
        raw, items, parts: parts(raw), knownCharacters: knownCharacters,
        hasPreviousScene: hasPreviousScene,
      );
    }
    if (items.any((item) => item is Map && (
        item.containsKey('block') || item.containsKey('before')))) {
      final sourceBlocks = blocks(raw);
      final ends = <int>[0];
      for (final block in sourceBlocks) {
        ends.add(ends.last + block.length);
      }
      final translated = <Map<String, dynamic>>[];
      for (final item in items) {
        if (item is! Map<String, dynamic>) {
          throw const FormatException('JSONification : événement non objet.');
        }
        if (item['type'] == 'message' &&
            item.length == 4 && item['block'] is int) {
          final id = item['block'] as int;
          if (id < 0 || id >= sourceBlocks.length) {
            throw const FormatException(
                'JSONification : indice de bloc invalide.');
          }
          translated.add({
            'type': 'message',
            'start': ends[id], 'end': ends[id + 1],
            'speaker': item['speaker'], 'name': item['name'],
          });
        } else if (item['type'] == 'scene_change' &&
            item.length == 2 && item['before'] is int) {
          final id = item['before'] as int;
          if (id < 0 || id >= sourceBlocks.length) {
            throw const FormatException(
                'JSONification : séparateur hors des blocs.');
          }
          translated.add({'type': 'scene_change', 'at': ends[id]});
        } else {
          throw const FormatException(
              'JSONification : événement de bloc invalide.');
        }
      }
      // Reuse the strict legacy range validator: source reconstruction,
      // attribution, scene boundaries and complete ordering remain mandatory.
      return decode(raw, jsonEncode({'events': translated}),
          knownCharacters: knownCharacters,
          hasPreviousScene: hasPreviousScene);
    }
    final known = knownCharacters.map((name) => name.toLowerCase()).toSet();
    final result = <ChatOutputEvent>[];
    var cursor = 0;
    var previousWasScene = false;
    var messageCount = 0;

    for (final item in items) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('JSONification : événement non objet.');
      }
      if (item['type'] == 'scene_change') {
        if (item.length != 2 || item['at'] is! int ||
            item['at'] != cursor || previousWasScene ||
            (!hasPreviousScene && cursor == 0)) {
          throw const FormatException('JSONification : séparateur mal placé.');
        }
        result.add(const ChatSceneChangeOutput());
        previousWasScene = true;
        continue;
      }
      if (item['type'] != 'message' ||
          item.length != 5 ||
          item['start'] is! int || item['end'] is! int ||
          item['speaker'] is! String || item['name'] is! String) {
        throw const FormatException('JSONification : message invalide.');
      }
      final start = item['start'] as int;
      final end = item['end'] as int;
      if (start != cursor || start < 0 || end <= start || end > raw.length ||
          !_isUtf16Boundary(raw, start) || !_isUtf16Boundary(raw, end)) {
        throw const FormatException(
          'JSONification : texte perdu, réordonné ou dupliqué.',
        );
      }
      final text = raw.substring(start, end);
      if (text.trim().isEmpty || text.length > 6000) {
        throw const FormatException('JSONification : segment invalide.');
      }
      final role = item['speaker'] as String;
      final proposed = (item['name'] as String).trim();
      if (role == 'narrator' && proposed == 'Narrateur') {
        result.add(ChatLine(speaker: ChatSpeaker.narrator,
            name: 'Narrateur', text: text));
      } else if (role == 'character' &&
          proposed.isNotEmpty && proposed.length <= 50 &&
          !RegExp(r'[\r\n]').hasMatch(proposed) &&
          !{'vous', 'joueur', 'player', 'narrateur'}
              .contains(proposed.toLowerCase()) &&
          (raw.toLowerCase().contains(proposed.toLowerCase()) ||
              known.contains(proposed.toLowerCase())) &&
          _matchesExplicitAttribution(text, proposed)) {
        result.add(ChatLine(speaker: ChatSpeaker.character,
            name: proposed, text: text));
      } else {
        throw const FormatException(
          'JSONification : personnage ou locuteur non vérifiable.',
        );
      }
      cursor = end;
      previousWasScene = false;
      messageCount++;
    }
    if (messageCount == 0 || cursor != raw.length || previousWasScene) {
      throw const FormatException(
        'JSONification : couverture incomplète ou séparateur final.',
      );
    }
    return List.unmodifiable(result);
  }

  /// Reject a clear conflicting "Name: dialogue" attribution; less explicit
  /// pronoun-based speakers are left to the formatter and known cast.
  bool _matchesExplicitAttribution(String text, String proposed) {
    final label = RegExp(
      r'^\s*([A-Za-zÀ-ÿ][A-Za-zÀ-ÿ0-9_\-]{0,49})\s*[:：]',
    ).firstMatch(text);
    return label == null ||
        label.group(1)!.toLowerCase() == proposed.toLowerCase();
  }

  bool _isUtf16Boundary(String raw, int index) {
    if (index <= 0 || index >= raw.length) return true;
    final left = raw.codeUnitAt(index - 1);
    final right = raw.codeUnitAt(index);
    return !(left >= 0xD800 && left <= 0xDBFF &&
        right >= 0xDC00 && right <= 0xDFFF);
  }
}
