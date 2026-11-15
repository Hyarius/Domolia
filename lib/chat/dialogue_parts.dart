import 'dart:convert';

import 'chat_protocol.dart';

/// A source-owned piece. Every code unit of the RAW belongs to exactly one
/// piece, including quotes, punctuation and whitespace.
class RawDialoguePart {
  const RawDialoguePart(this.text, {required this.quoted});
  final String text;
  final bool quoted;
}

/// The model classifies source-owned pieces; it never computes character
/// offsets or provides replacement dialogue. RAW remains stored separately.
class DialogueParts {
  const DialogueParts();

  static final RegExp _quotes = RegExp(r'«[^»]*»', dotAll: true);
  static final RegExp _label = RegExp(
    r'^([A-Za-zÀ-ÿ][A-Za-zÀ-ÿ0-9_ -]{0,49})\s*[:：]\s*',
  );

  List<RawDialoguePart> split(List<String> blocks) {
    final result = <RawDialoguePart>[];
    for (final block in blocks) {
      var cursor = 0;
      for (final match in _quotes.allMatches(block)) {
        if (match.start > cursor) {
          result.add(RawDialoguePart(block.substring(cursor, match.start),
              quoted: false));
        }
        result.add(RawDialoguePart(block.substring(match.start, match.end),
            quoted: true));
        cursor = match.end;
      }
      if (cursor < block.length) {
        result.add(RawDialoguePart(block.substring(cursor), quoted: false));
      }
    }
    // In extremely fragmented prose, use full paragraphs rather than
    // sending an unbounded number of model classifications.
    if (result.length > 105) {
      return List.unmodifiable([
        for (final block in blocks) RawDialoguePart(block, quoted: false),
      ]);
    }
    return List.unmodifiable(result);
  }

  String forPrompt(List<RawDialoguePart> parts) => [
    for (final (index, part) in parts.indexed)
      'Partie $index (${part.quoted ? 'citation' : 'prose'}) : '
          '${jsonEncode(part.text)}',
  ].join('\n');

  /// All parts are accounted for in order; "aside" pieces are intentionally
  /// not rendered, but are never erased from the original saved RAW.
  List<ChatOutputEvent> decode(
    String raw,
    List<dynamic> events, {
    required List<RawDialoguePart> parts,
    required Iterable<String> knownCharacters,
    required bool hasPreviousScene,
  }) {
    if (parts.isEmpty || parts.map((e) => e.text).join() != raw) {
      throw const FormatException('JSONification : partition RAW invalide.');
    }
    final names = knownCharacters.map((e) => e.toLowerCase()).toSet();
    final types = <String>[];
    final seen = <int>{};
    final result = <ChatOutputEvent>[];
    final hidden = <int>[];
    var nextPart = 0;
    var hasMessage = false;
    var lastScene = false;
    for (final event in events) {
      if (event is! Map<String, dynamic>) {
        throw const FormatException('JSONification : partie non objet.');
      }
      if (event['type'] == 'scene_change') {
        if (event.length != 2 || event['before'] is! int ||
            event['before'] != nextPart || lastScene ||
            (!hasPreviousScene && nextPart == 0) ||
            nextPart >= parts.length) {
          throw const FormatException('JSONification : scène mal placée.');
        }
        result.add(const ChatSceneChangeOutput());
        lastScene = true;
        continue;
      }
      if (event['type'] != 'part' || event['part'] is! int ||
          event['part'] != nextPart || !seen.add(nextPart) ||
          event['kind'] is! String) {
        throw const FormatException(
            'JSONification : partie manquante ou désordonnée.');
      }
      final kind = event['kind'] as String;
      final source = parts[nextPart];
      switch (kind) {
        case 'narration':
          if (event.length != 3) {
            throw const FormatException('JSONification : narration invalide.');
          }
          if (source.text.trim().isNotEmpty) {
            result.add(ChatLine(speaker: ChatSpeaker.narrator,
                name: 'Narrateur', text: source.text.trim()));
            hasMessage = true;
          }
        case 'dialogue':
          if (event.length != 4 && event.length != 5 ||
              event['name'] is! String ||
              (event.length == 5 && event['status'] is! String)) {
            throw const FormatException('JSONification : dialogue invalide.');
          }
          final name = (event['name'] as String).trim();
          if (name.isEmpty || name.length > 50 ||
              RegExp(r'[\r\n]').hasMatch(name) ||
              {'joueur', 'vous', 'player', 'narrateur'}
                  .contains(name.toLowerCase()) ||
              !(raw.toLowerCase().contains(name.toLowerCase()) ||
                  names.contains(name.toLowerCase()))) {
            throw const FormatException('JSONification : locuteur non vérifié.');
          }
          var text = source.text.trim();
          if (source.quoted) {
            text = text.substring(1, text.length - 1).trim();
          } else {
            final match = _label.firstMatch(text);
            if (match == null ||
                match.group(1)!.trim().toLowerCase() != name.toLowerCase()) {
              throw const FormatException(
                  'JSONification : dialogue non cité sans attribution.');
            }
            text = text.substring(match.end).trim();
          }
          if (text.isEmpty || text.length > 6000) {
            throw const FormatException('JSONification : réplique invalide.');
          }
          final status = (event['status'] as String? ?? '').trim();
          if (status.length > 65 ||
              RegExp(r'[\r\n«»<>]').hasMatch(status)) {
            throw const FormatException('JSONification : statut invalide.');
          }
          result.add(ChatLine(
              speaker: ChatSpeaker.character, name: name, text: text,
              status: status.isEmpty ? null : status));
          hasMessage = true;
        case 'aside':
          if (event.length != 3 || source.quoted ||
              source.text.length > 1000) {
            throw const FormatException('JSONification : incise invalide.');
          }
          hidden.add(nextPart);
        default:
          throw const FormatException('JSONification : nature inconnue.');
      }
      types.add(kind);
      nextPart++;
      lastScene = false;
    }
    if (nextPart != parts.length || !hasMessage || lastScene) {
      throw const FormatException(
          'JSONification : parties incomplètes ou résultat vide.');
    }
    // An aside must be linked to a spoken utterance; entire unrelated
    // narrative paragraphs cannot silently disappear.
    for (final index in hidden) {
      if (!((index > 0 && types[index - 1] == 'dialogue') ||
          (index + 1 < types.length && types[index + 1] == 'dialogue'))) {
        throw const FormatException('JSONification : incise isolée.');
      }
    }
    return List.unmodifiable(result);
  }
}
