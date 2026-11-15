import 'package:domolia/books/book_lore.dart';
import 'package:domolia/books/lore_context_optimizer.dart';
import 'package:flutter_test/flutter_test.dart';

BookLore sampleLore({bool changed = false}) => BookLore(
  global: LoreGlobal(
    universe: 'Skogheim',
    overview: List.filled(850, 'Abbaye, fjord, bois et froid').join(' '),
    rules: changed ? 'La neige est tombée' : 'La neige approche',
  ),
  characters: const [
    LoreCharacter(id: 'astrid', name: 'Astrid Haldorsdatter',
      description: 'Prêtresse principale.'),
    LoreCharacter(id: 'liv', name: 'Liv Eiriksdatter',
      description: 'Apprentie prêtresse.'),
  ],
  events: const [
    LoreEvent(id: 'winter', name: 'Premier gel',
      trigger: LoreEventTrigger.conditional,
      condition: 'Quand la température descend', mandatory: false),
  ],
);

void main() {
  const optimizer = LoreContextOptimizer();

  test('Optimization occurs only for sufficiently detailed Lore', () {
    expect(optimizer.canOptimize(const BookLore()), false);
    expect(optimizer.canOptimize(const BookLore(
      global: LoreGlobal(universe: 'Court'),
    )), false);
    expect(optimizer.canOptimize(sampleLore()), true);
    final request = optimizer.request(sampleLore());
    expect(request, hasLength(2));
    expect(request[0].content, contains('sans'));
    expect(request[1].content, contains('Astrid Haldorsdatter'));
    expect(request[1].content, contains('conditional'));
    expect(request[1].content, contains('Quand la température descend'));
  });

  test('Cache identity is deterministic and invalidates on canonical edits', () {
    final original = sampleLore();
    expect(optimizer.sourceHash(original), optimizer.sourceHash(sampleLore()));
    expect(optimizer.sourceHash(original),
      isNot(optimizer.sourceHash(sampleLore(changed: true))));
  });

  test('Invalid summary falls back rather than deleting characters', () {
    final lore = sampleLore();
    expect(optimizer.validate(lore, 'Trop bref.'), isNull);
    final missingLiv = 'Skogheim Astrid Haldorsdatter. '
        '${List.filled(65, "Résumé").join(" ")} Premier gel';
    expect(optimizer.validate(lore, missingLiv), isNull);
    final valid = 'Skogheim : Astrid Haldorsdatter, Liv Eiriksdatter. '
        'Le Premier gel reste une éventualité conditionnelle. '
        '${List.filled(65, "Vie quotidienne").join(" ")}';
    expect(optimizer.validate(lore, valid), valid);
  });

  test('Oversize or non-economical LLM output is rejected', () {
    final lore = sampleLore();
    final oversized = 'Skogheim Astrid Haldorsdatter '
        'Liv Eiriksdatter Premier gel '
        '${List.filled(750, "présence").join(" ")}';
    expect(oversized.length, greaterThan(
      LoreContextOptimizer.maxSummaryCharacters));
    expect(optimizer.validate(lore, oversized), isNull);
  });
}
