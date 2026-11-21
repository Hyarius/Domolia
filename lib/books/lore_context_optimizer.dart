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
  // Avoid paying an extra LLM call for medium Books: deterministic Lore
  // selection already provides a bounded narrator context without setup cost.
  static const minInputCharacters = 12000;

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
      content: '''
RÔLE
Tu condenses le Lore canonique du Livre en une fiche pour le narrateur.

FIDÉLITÉ
Préserve les noms exacts de tous les personnages, lieux, scénarios et
événements, ainsi que les règles, relations, motivations et secrets.
Les passages SECRET restent réservés au narrateur. Ne transforme jamais
un événement prévu, facultatif ou conditionnel en fait déjà accompli.
N'invente, ne supprime et ne change aucun fait du canon.

FORMAT
Écris en français une fiche compacte, structurée en sections lisibles,
sans JSON ni Markdown complexe, de moins de 6 500 caractères.
Le Livre source fait toujours autorité sur ce résumé.
''',
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
