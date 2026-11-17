import 'book_lore.dart';

/// Deterministic selection for the literary RAW pass, never the JSONifier.
/// A mention is only a relevance signal, NOT proof that an event occurred.
class LoreContextBuilder {
  const LoreContextBuilder({this.maxCharacters = 8000});
  final int maxCharacters;

  String build(BookLore lore, Iterable<String> recentText) {
    if (lore.isEmpty) return '';
    final g = lore.global;
    final recent = _fold(recentText.join('\n'));
    final output = <String>[];
    // Keep indispensable canon protected when reclaiming space for notices.
    final essentialBlocks = <bool>[];
    var used = 0;
    var omitted = 0;
    void include(String section, String value, {bool essential = false}) {
      if (value.trim().isEmpty) return;
      final block = '$section\n$value';
      if (used + block.length + 2 > maxCharacters) {
        if (essential) {
          throw const FormatException(
            'Lore essentiel trop volumineux pour le budget du narrateur. '
            'Réduisez le contexte global ou augmentez le budget.',
          );
        }
        omitted++;
        return;
      }
      output.add(block);
      essentialBlocks.add(essential);
      used += block.length + 2;
    }

    include('DIRECTIVES DE LORE (réservées au narrateur)',
      'Les faits canoniques priment sur l’improvisation. '
      'Les secrets sont connus du narrateur, jamais révélés avant '
      'une découverte narrative appropriée. Les conditions et événements '
      'envisagés ne sont pas des faits déjà accomplis. '
      'Ne décide aucune action, pensée ou parole du personnage joueur.',
      essential: true);

    include('CANON DU MONDE — toujours disponible', [
      if (g.universe.isNotEmpty) 'Univers : ${g.universe}',
      if (g.overview.isNotEmpty) 'Présentation : ${g.overview}',
      if (g.genre.isNotEmpty) 'Genre et ambiance : ${g.genre}',
      if (g.era.isNotEmpty) 'Époque : ${g.era}',
      if (g.initialContext.isNotEmpty) 'Contexte initial : ${g.initialContext}',
      if (g.history.isNotEmpty) 'Histoire : ${g.history}',
      if (g.rules.isNotEmpty) 'Règles du monde : ${g.rules}',
      if (g.conflicts.isNotEmpty) 'Conflits : ${g.conflicts}',
      if (g.directions.isNotEmpty) 'Intentions de l’auteur (non canoniques) : ${g.directions}',
      if (g.secrets.isNotEmpty) 'SECRETS DU NARRATEUR (ne pas divulguer) : ${g.secrets}',
    ].join('\n'), essential: true);

    bool mentioned(LoreRecord entry) => [
      entry.name, ...entry.aliases,
    ].any((word) {
      final needle = _fold(word).trim();
      return needle.length >= 3 && recent.contains(needle);
    });

    // A place mentioned in the scene can identify its associated cast even
    // when the NPC's name has not been spoken yet. This is reference data,
    // never proof that any of these characters is physically present.
    // Bound the indirect expansion to avoid injecting the full Book roster.
    final nearbyCharacterIds = <String>{
      for (final p in lore.places)
        if (mentioned(p)) ...p.characterIds.take(3),
    };
    final characters = [
      for (final c in lore.characters)
        if (mentioned(c) || nearbyCharacterIds.contains(c.id)) c,
    ]..sort((a,b) => a.id.compareTo(b.id));
    final directCharacterIds = characters.map((e) => e.id).toSet();
    final homePlaceIds = characters.map((e) => e.homePlaceId).toSet();
    final places = [
      for (final p in lore.places)
        if (mentioned(p) || homePlaceIds.contains(p.id) ||
            p.characterIds.any(directCharacterIds.contains)) p,
    ]..sort((a,b) => a.id.compareTo(b.id));

    // Explicit canonical links enrich the selection; none describes session state.
    final activeCharacterIds = characters.map((e) => e.id).toSet();
    final activePlaceIds = places.map((e) => e.id).toSet();
    final scenarios = [
      for (final s in lore.scenarios)
        if (mentioned(s) || s.importance == LoreScenarioImportance.main ||
            s.characterIds.any(activeCharacterIds.contains) ||
            s.placeIds.any(activePlaceIds.contains)) s,
    ]..sort((a,b) {
      final aMain = a.importance == LoreScenarioImportance.main ? 0 : 1;
      final bMain = b.importance == LoreScenarioImportance.main ? 0 : 1;
      return aMain != bMain ? aMain.compareTo(bMain) : a.id.compareTo(b.id);
    });
    final activeScenarioIds = scenarios.map((s) => s.id).toSet();

    for (final c in characters) {
      include('PERSONNAGE CANONIQUE — ${c.name}', [
        c.description, 'Apparence : ${c.appearance}',
        'Personnalité : ${c.personality}', 'Passé : ${c.background}',
        'Rôle : ${c.role}', 'Motivations : ${c.motivations}',
        'Valeurs : ${c.values}',
        if (c.secrets.isNotEmpty) 'SECRET DU NARRATEUR : ${c.secrets}',
      ].where((s) => s.trim().isNotEmpty).join('\n'),
        essential: mentioned(c));
    }
    for (final p in places) {
      include('LIEU CANONIQUE — ${p.name}', [
        p.description, 'Type : ${p.type}', 'Atmosphère : ${p.atmosphere}',
        'Histoire : ${p.history}', 'Particularités : ${p.features}',
        if (p.secrets.isNotEmpty) 'SECRET DU NARRATEUR : ${p.secrets}',
      ].where((s) => s.trim().isNotEmpty).join('\n'), essential: true);
    }
    for (final s in scenarios) {
      include('INTRIGUE ${s.importance.name} — ${s.title}', [
        if (s.summary.isNotEmpty) 'Résumé : ${s.summary}',
        if (s.initialContext.isNotEmpty) 'Contexte : ${s.initialContext}',
        if (s.introduction.isNotEmpty)
          'Introduction possible, sous conditions : ${s.introduction}',
        if (s.objectives.isNotEmpty) 'Intentions narratives : ${s.objectives}',
        if (s.secrets.isNotEmpty) 'SECRET DU NARRATEUR : ${s.secrets}',
      ].join('\n'), essential: mentioned(s));
    }
    final events = [
      for (final e in lore.events)
        if (mentioned(e) ||
            (e.trigger == LoreEventTrigger.planned && e.mandatory) ||
            e.characterIds.any(activeCharacterIds.contains) ||
            e.placeIds.any(activePlaceIds.contains) ||
            e.scenarioIds.any(activeScenarioIds.contains) ||
            scenarios.any((scenario) => scenario.eventIds.contains(e.id))) e,
    ]..sort((a,b) {
      final byPriority = b.priority.compareTo(a.priority);
      return byPriority != 0 ? byPriority : a.id.compareTo(b.id);
    });
    for (final e in events) {
      include('ÉVÉNEMENT POTENTIEL — ${e.title}', [
        'Type : ${e.trigger.name}. Comportement souhaité : '
            '${e.mandatory ? "obligatoire dans le monde" : "facultatif"}.',
        if (e.condition.isNotEmpty) 'Condition NON vérifiée : ${e.condition}',
        if (e.timing.isNotEmpty) 'Moment envisagé : ${e.timing}',
        'Description (pas une réalisation constatée) : ${e.description}',
        if (e.consequences.isNotEmpty)
          'Conséquences possibles : ${e.consequences}',
        if (e.secrets.isNotEmpty) 'SECRET DU NARRATEUR : ${e.secrets}',
        'Ne jamais imposer une action du joueur.',
      ].join('\n'), essential: mentioned(e));
    }
    if (omitted > 0) {
      // A notice is useful, but must never invalidate an otherwise valid
      // selection of essential canon. Make room by removing only optional
      // entries; the author-provided world and direct references remain.
      String warning = '$omitted fiche(s) secondaires écartées du contexte. '
          'Ne les invente pas.';
      if (used + warning.length + 2 > maxCharacters) {
        warning = 'LORE PARTIEL : $omitted fiche(s) omise(s).';
      }
      while (used + warning.length + 2 > maxCharacters) {
        final index = essentialBlocks.lastIndexOf(false);
        if (index < 0) break;
        used -= output[index].length + 2;
        output.removeAt(index);
        essentialBlocks.removeAt(index);
        omitted++;
        warning = 'LORE PARTIEL : $omitted fiche(s) omise(s).';
      }
      if (used + warning.length + 2 <= maxCharacters) {
        output.add(warning);
      } else {
        // Only mandatory canon remains, and even the short notice won't
        // fit. Never turn a purely optional omission into a failed turn.
        // The next input still receives all essential selected facts.
      }
    }
    return output.join('\n\n');
  }

  static String _fold(String value) {
    const accented = 'àáâäãåçèéêëìíîïñòóôöõùúûüýÿœæ';
    const plain = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final lower = value.toLowerCase();
    final buffer = StringBuffer();
    for (final rune in lower.runes) {
      final ch = String.fromCharCode(rune);
      final i = accented.indexOf(ch);
      buffer.write(i >= 0 ? plain[i] : ch);
    }
    return buffer.toString();
  }
}
