import 'dart:convert';

import 'package:domolia/books/book_lore.dart';
import 'package:domolia/books/lore_startup_context.dart';
import 'package:domolia/chat/narrative_reference_tools.dart';
import 'package:flutter_test/flutter_test.dart';

const _lore = BookLore(
  global: LoreGlobal(
    universe: 'Cendreval',
    overview: 'La cloche du port s’arrête à 04 h 12.',
    initialContext: 'Le joueur est chez Soren. Léa Monel est messagère '
      'et Léa Monnel est archiviste, deux personnes distinctes.',
    rules: 'Ne jamais agir à la place du joueur. '
      'Une offre ne signifie pas possession. '
      'Une promesse exige une réalisation réelle.',
    secrets: 'MICA-731 : clapet de dérivation grippé.',
  ),
  characters: [
    LoreCharacter(id: 'soren', name: 'Soren',
      description: 'Gardien des consignes, détenteur du jeton 62.',
      homePlaceId: 'bureau'),
    LoreCharacter(id: 'lea_monel', name: 'Léa Monel',
      description: 'Messagère à la sacoche orange.',
      homePlaceId: 'quai'),
    LoreCharacter(id: 'lea_monnel', name: 'Léa Monnel',
      description: 'Archiviste aux gants gris.',
      homePlaceId: 'salle'),
    LoreCharacter(id: 'alix', name: 'Alix',
      description: 'Gardienne du fanal.', homePlaceId: 'fanal'),
  ],
  places: [
    LorePlace(id: 'bureau', name: 'Bureau des Consignes',
      description: 'Le bureau de Soren.', characterIds: ['soren']),
    LorePlace(id: 'quai', name: 'Quai des Grues',
      description: 'Léa Monel y travaille.', characterIds: ['lea_monel']),
    LorePlace(id: 'salle', name: 'Salle des Marées',
      description: 'Léa Monnel y travaille.', characterIds: ['lea_monnel']),
    LorePlace(id: 'fanal', name: 'Fanal Nord',
      description: 'La tour de signalisation.', characterIds: ['alix']),
  ],
  scenarios: [
    LoreScenario(id: 'enquete', name: 'Cloche immobile',
      summary: 'Rechercher les faits sans conclure hâtivement.',
      importance: LoreScenarioImportance.main),
    LoreScenario(id: 'marche', name: 'Le marché de l’automne',
      description: 'Intrigue secondaire à ne pas charger initialement.'),
  ],
  events: [
    LoreEvent(id: 'remise', name: 'Remise du jeton',
      trigger: LoreEventTrigger.conditional,
      condition: 'Soren remet explicitement le jeton et le joueur le prend.',
      description: 'Transfert possible seulement sous condition.'),
    LoreEvent(id: 'dossier', name: 'Dossier secret',
      trigger: LoreEventTrigger.conditional,
      condition: 'Autorisation écrite et ouverture volontaire.',
      secrets: 'MICA-731 : clapet de dérivation grippé.'),
  ],
);

void main() {
  test('Starter preserves essential rules, not the entire scenario', () {
    final startup = const LoreStartupContextBuilder().build(_lore);
    expect(startup.length, lessThanOrEqualTo(3600));
    expect(startup, contains('Cendreval'));
    expect(startup, contains('Une offre ne signifie pas possession'));
    expect(startup, contains('Léa Monel'));
    expect(startup, contains('Léa Monnel'));
    expect(startup, contains('Cloche immobile'));
    expect(startup, isNot(contains('MICA-731')));
    expect(startup, isNot(contains('Dossier secret')));
    expect(startup, isNot(contains('Le marché de l’automne')));
  });

  test('Large canon cannot overflow startup budget or expose secrets', () {
    final large = BookLore(
      global: LoreGlobal(
        universe: 'Cendreval',
        overview: 'Brouillard et port. ' * 350,
        initialContext: 'Soren attend le joueur. ' * 120,
        rules: 'Ne pas inventer une possession. ' * 150,
        secrets: 'MICA-731 : clapet de dérivation grippé.',
      ),
      characters: _lore.characters,
      places: _lore.places,
      scenarios: _lore.scenarios,
      events: _lore.events,
    );
    final startup = const LoreStartupContextBuilder().build(large);
    expect(startup.length, lessThanOrEqualTo(3600));
    expect(startup, contains('Ne pas inventer une possession'));
    expect(startup, contains('suite dans le Lore'));
    expect(startup, isNot(contains('MICA-731')));
  });

  test('Current scene picks only relevant similarly named character', () {
    const builder = LoreStartupContextBuilder();
    final local = builder.relevant(_lore, ['Je parle à Léa Monel au Quai des Grues.']);
    expect(local, contains('Léa Monel'));
    expect(local, contains('sacoche orange'));
    expect(local, isNot(contains('PERSONNAGE CANONIQUE — Léa Monnel')));
    expect(local, isNot(contains('Dossier secret')));
  });

  test('Complete global canon remains fetchable in bounded chunks', () {
    final tools = NarrativeReferenceTools(
      lore: () => _lore,
      timeline: () => [],
      rawGenerations: () => [],
    );
    final result = jsonDecode(tools.execute('get_lore_global',
        '{"section":"secrets"}')) as Map<String, dynamic>;
    expect(result['source'], 'book_canon');
    expect(result['text'], contains('MICA-731'));
    expect(result['notice'], contains('Never present as discovered'));
    final rules = jsonDecode(tools.execute('get_lore_global',
        '{"section":"rules"}')) as Map<String, dynamic>;
    expect(rules['text'], contains('Une offre ne signifie pas possession'));
    final invalid = jsonDecode(tools.execute('get_lore_global',
        '{"section":"missing"}')) as Map<String, dynamic>;
    expect(invalid['error'], 'invalid_arguments');
  });
}
