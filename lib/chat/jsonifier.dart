import 'dart:convert';

import 'chat_protocol.dart';

/// The formatter returns source ranges, never rewritten narrative text.
/// Offsets use Dart String UTF-16 code units [start,end), not UTF-8 bytes,
/// Unicode code points or grapheme cluster indices.
const jsonifierSystemPrompt = '''
Tu es le JSONificateur de Domolia. Tu ne rédiges AUCUNE histoire.
Réponds uniquement avec un objet JSON : {"events":[...]}.
Événements autorisés :
{"type":"message","start":0,"end":12,"speaker":"narrator","name":"Narrateur"}
{"type":"message","start":12,"end":38,"speaker":"character","name":"Brann"}
{"type":"scene_change","at":12}
Chaque message référence un intervalle [start,end) de positions UTF-16 dans
le texte RAW donné. Les intervalles des messages doivent couvrir exactement
tout le texte RAW, dans l'ordre, sans trou ni chevauchement. Ils doivent être
non vides, et contenir chacun au moins un caractère non blanc.
N'ajoute aucun champ text : Domolia extrait elle-même le texte source.
Préserve absolument chaque mot, signe, espace, saut de ligne, dialogue,
répétition et toute ponctuation d'origine. Ne réécris ni ne résume rien.
Découpe en narration et en dialogues, attribue seulement des personnages
identifiables dans le RAW ou le contexte antérieur. Jamais de parole du joueur.
Les changements de scène sont des événements de longueur nulle placés
EXACTEMENT au début d'un intervalle de message. Ils peuvent être au début
du texte si une vraie transition se produit depuis la scène précédente.
Place-les seulement pour une rupture importante de lieu, de temps ou
de séquence, jamais pour un changement de locuteur ou chaque nouveau tour.
Plusieurs changements de scène sont possibles dans une réponse.
Aucun Markdown ni commentaire, aucune donnée en dehors de l'objet JSON.
''';

class Jsonifier {
  const Jsonifier();

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
      r'^\\s*([A-Za-zÀ-ÿ][A-Za-zÀ-ÿ0-9_\\-]{0,49})\\s*[:：]',
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
