import 'dart:convert';

import '../ai/ai_provider.dart';
import 'book_lore.dart';

/// An optional one-time, per-Party, read-only summary of immutable Book Lore.
/// Never replaces author-owned records. The original deterministic selector
/// remains the fallback if this output is missing or cannot be validated.
class LoreContextOptimizer {
  const LoreContextOptimizer();

  static const maxInputCharacters = 24000;
  static const maxSummaryCharacters = 6500;
  static const minInputCharacters = 6000;

  String sourceHash(BookLore lore) {
    final input = jsonEncode(lore.toJson());
    // Keep intermediate values JS-integer safe for Flutter Web.
    var hash = 7;
    for (final code in input.codeUnits) {
      hash = (hash * 31 + code) % 2147483647;
    }
    return 'lore-v1-${input.length}-${hash.toRadixString(16)}';
  }

  bool canOptimize(BookLore lore) {
    if (lore.isEmpty) return false;
    final length = jsonEncode(lore.toJson()).length;
    return length >= minInputCharacters && length <= maxInputCharacters;
  }

  List<AiMessage> request(BookLore lore) => [
    const AiMessage(
      role: 'system',
      content: 'Tu es un compresseur de contexte narratif. '
        'Résume fidèlement le canon statique fourni, en français, sans '
        'inventer, omettre un personnage ou changer une condition. '
        'Préserve les noms exacts de tous les personnages, lieux, scénarios '
        'et événements. Un événement prévu, optionnel ou conditionnel '
        'NE DOIT PAS être décrit comme déjà survenu. '
        'Préserve les règles, liens importants, motivations et '
        'informations secrètes étiquetées SECRET (réservées au narrateur). '
        'Ne produis ni JSON ni Markdown complexe. '
        'Retourne seulement une fiche compacte lisible par un narrateur, '
        'avec des sections et moins de 6 500 caractères. '
        'Le Livre source fait autorité sur le résumé.',
    ),
    AiMessage(
      role: 'user',
      content: 'Compresse ce Lore canonique, sans modifier les faits :\n'
          '${jsonEncode(lore.toJson())}',
    ),
  ];

  /// Structural validation only: no LLM summary is guaranteed fact-perfect.
  /// Reject obvious truncation, incomplete entity lists, or non-savings.
  String? validate(BookLore lore, String output) {
    final compact = output.trim();
    final sourceLength = jsonEncode(lore.toJson()).length;
    if (compact.length < 150 ||
        compact.length > maxSummaryCharacters ||
        compact.length >= sourceLength * 0.8) {
      return null;
    }
    final names = <String>[
      for (final c in lore.characters) c.name,
      for (final p in lore.places) p.name,
      for (final s in lore.scenarios) s.name,
      for (final e in lore.events) e.name,
    ];
    final lower = compact.toLowerCase();
    if (names.any((name) => !lower.contains(name.toLowerCase()))) return null;
    final world = lore.global.universe.trim();
    if (world.isNotEmpty && !lower.contains(world.toLowerCase())) return null;
    return compact;
  }
}
