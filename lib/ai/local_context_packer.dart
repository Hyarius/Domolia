import '../ai/ai_provider.dart';
import '../books/book_lore.dart';
import '../books/lore_context_builder.dart';
import '../chat/chat_protocol.dart';
import '../chat/jsonifier.dart';
import '../chat/narrator.dart';
import '../memory/live_memory_coordinator.dart';
import 'local_context_budget.dart';

/// Packs only relevant content while keeping the latest player action and
/// all indispensable canonical Lore. Never truncates JSONifier RAW parts.
class LocalContextPacker {
  const LocalContextPacker(this.budget);
  final LocalContextBudget budget;

  List<AiMessage> narrator({
    required Narrator narrator,
    required List<AiMessage> history,
    BookLore? lore,
    LiveMemoryCoordinator? memory,
  }) {
    if (history.isEmpty || history.last.role != 'user') {
      throw const FormatException('Dernière action du joueur introuvable.');
    }
    final player = history.last;
    final older = history.take(history.length - 1).toList();
    final recent = history.reversed.take(10).map((m) => m.content);
    final instructions = narrator.systemPrompt;

    List<AiMessage> assemble(String canon, String facts,
        List<AiMessage> past) => [
      AiMessage(role: 'system', content: [
        instructions,
        if (canon.isNotEmpty) canon,
        if (facts.isNotEmpty)
          'LIVE MEMORY — faits de cette Partie, distincts du canon. '
          'N’expose pas de secret ni d’action inventée du joueur.\n$facts',
      ].join('\n\n')),
      ...past,
      player,
    ];

    budget.requireFit(assemble('', '', const []));
    var selectedLore = '';
    if (lore != null && !lore.isEmpty) {
      final remaining = budget.capacity -
          budget.estimate(assemble('', '', const []));
      final maxChars = (remaining / budget.estimator.rate(budget.model)).floor();
      FormatException? lastError;
      var found = false;
      for (final share in [60, 70, 80, 90, 100]) {
        final allowance = (maxChars * share / 100).floor();
        if (allowance < 1) continue;
        try {
          final candidate = LoreContextBuilder(maxCharacters: allowance)
              .build(lore, recent);
          if (budget.fits(assemble(candidate, '', const []))) {
            selectedLore = candidate;
            found = true;
            break;
          }
        } on FormatException catch (error) {
          lastError = error;
        }
      }
      if (!found) {
        throw FormatException(
          'Le canon essentiel est trop long pour la fenêtre locale. '
          'Réduisez le Lore global ou augmentez la fenêtre du modèle. '
          '${lastError?.message ?? ""}',
        );
      }
    }

    var selectedMemory = '';
    if (memory != null) {
      final remaining = budget.capacity -
          budget.estimate(assemble(selectedLore, '', const []));
      var allowed = (remaining * 0.7 / budget.estimator.rate(budget.model))
          .floor().clamp(0, 16000).toInt();
      while (allowed >= 256) {
        final candidate = memory.context(recent, budget: allowed);
        if (budget.fits(assemble(selectedLore, candidate, const []))) {
          selectedMemory = candidate;
          break;
        }
        allowed = (allowed * 0.7).floor();
      }
    }

    final selectedHistory = <AiMessage>[];
    for (final item in older.reversed) {
      final attempt = [item, ...selectedHistory];
      if (!budget.fits(assemble(selectedLore, selectedMemory, attempt))) {
        break;
      }
      selectedHistory.insert(0, item);
    }
    final result = assemble(selectedLore, selectedMemory, selectedHistory);
    budget.requireFit(result);
    return result;
  }

  List<AiMessage> jsonifier({
    required String raw,
    required Iterable<ChatEntry> previous,
  }) {
    final parts = const Jsonifier().partsForPrompt(raw);
    List<AiMessage> assemble(List<String> prior) {
      final earlier = prior.isEmpty ? '' :
          'Contexte précédent (ne pas convertir) :\n${prior.join("\n")}\n\n';
      return [
        const AiMessage(role: 'system', content: jsonifierSystemPrompt),
        AiMessage(role: 'user', content:
            '$earlier'
            'Parties RAW à classifier (texte JSON échappé, '
            'numéros fournis par Dart) :\n$parts'),
      ];
    }
    // Never truncate source parts: numbering/offsets must match original RAW.
    budget.requireFit(assemble(const []));
    final relevant = <String>[];
    for (final event in previous.toList().reversed) {
      final line = '${event.name}${event.status == null ? "" : " (${event.status})"} : ${event.text}';
      final next = [line, ...relevant];
      if (!budget.fits(assemble(next))) break;
      relevant.insert(0, line);
    }
    return assemble(relevant);
  }
}
