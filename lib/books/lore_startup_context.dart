import 'book_lore.dart';

/// A bounded, local briefing for a new Party, not an LLM-generated summary.
///
/// The complete author-owned Book remains available through the read-only
/// reference tools. In particular, scenario details, conditional events and
/// unpublished secrets are NOT preloaded into every narrator request.
class LoreStartupContextBuilder {
  const LoreStartupContextBuilder({this.maxCharacters = 3600});

  final int maxCharacters;

  static const guidance =
      'CONTEXTE DE DÉPART (canon du Livre, pas historique de la Partie).\n'
      'Ne joue jamais les actions, paroles ou décisions du joueur. '
      'Une proposition ne vaut pas acquisition, une promesse conditionnelle '
      'ne vaut pas accomplissement. Ne transforme pas une rumeur en fait. '
      'Ne considère jamais un événement prévu ou conditionnel comme accompli. '
      'Les secrets et les dossiers fermés ne sont pas connus du joueur tant '
      'qu’il ne les découvre pas dans la Partie. '
      'Pour les détails non fournis, consulte search_lore/get_lore_entry, '
      'ou get_lore_global pour le canon mondial, si ces outils sont disponibles. '
      'N’invente pas les détails absents.';

  String build(BookLore lore) {
    if (lore.isEmpty) return '';
    final sections = <String>[guidance];
    var used = guidance.length;
    void add(String label, String value, {int maximum = 400}) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return;
      final left = maxCharacters - used - label.length - 4;
      if (left < 50) return;
      final clipped = _clip(trimmed, left < maximum ? left : maximum);
      final block = '$label : $clipped';
      sections.add(block);
      used += block.length + 2;
    }

    final g = lore.global;
    add('Univers', g.universe, maximum: 160);
    add('Situation', g.overview, maximum: 480);
    add('Genre', g.genre, maximum: 110);
    add('Époque', g.era, maximum: 110);
    add('Règles du monde (complément consultable)', g.rules, maximum: 1000);
    add('Départ du joueur', g.initialContext, maximum: 750);
    add('Conflits connus au départ', g.conflicts, maximum: 340);
    add('Cadre narratif', g.directions, maximum: 260);

    for (final scenario in lore.scenarios
        .where((item) => item.importance == LoreScenarioImportance.main)
        .take(2)) {
      add('Intrigue principale possible — ${scenario.name}',
          scenario.summary.isNotEmpty ? scenario.summary : scenario.description,
          maximum: 240);
    }

    // Only cast explicitly named in the initial setting belongs here.
    final initial = '${g.initialContext}\n${g.overview}';
    for (final character in lore.characters
        .where((entry) => _mentioned(entry, initial)).take(5)) {
      add('Personnage de départ — ${character.name}',
          character.description, maximum: 175);
    }
    for (final place in lore.places
        .where((entry) => _mentioned(entry, initial)).take(3)) {
      add('Lieu de départ — ${place.name}',
          place.description, maximum: 170);
    }
    return sections.join('\n\n');
  }

  /// Very small local rescue for providers with no tool calling. Even then
  /// the whole scenario tree must never be inserted into a prompt.
  String relevant(BookLore lore, Iterable<String> recentText,
      {int maxCharacters = 1800}) {
    final recent = recentText.join('\n');
    if (recent.trim().isEmpty || lore.isEmpty) return '';
    final entries = <String>[];
    var used = 0;
    void add(String title, String details, {int maximum = 260}) {
      if (details.trim().isEmpty) return;
      final left = maxCharacters - used - title.length - 4;
      if (left < 70) return;
      final block = '$title : ${_clip(details.trim(),
          left < maximum ? left : maximum)}';
      entries.add(block);
      used += block.length + 2;
    }

    final activePlaces = lore.places
        .where((entry) => _mentioned(entry, recent)).take(3).toList();
    final linkedCharacters = {
      for (final place in activePlaces) ...place.characterIds.take(3),
    };
    for (final character in lore.characters.where((entry) =>
        _mentioned(entry, recent) || linkedCharacters.contains(entry.id))
        .take(5)) {
      add('PERSONNAGE CANONIQUE — ${character.name}', [
        character.description,
        if (character.role.isNotEmpty) 'Rôle : ${character.role}',
        if (character.personality.isNotEmpty)
          'Caractère : ${character.personality}',
      ].join(' '));
    }
    for (final place in activePlaces) {
      add('LIEU CANONIQUE — ${place.name}', [
        place.description,
        if (place.features.isNotEmpty) place.features,
      ].join(' '));
    }
    for (final scenario in lore.scenarios
        .where((entry) => _mentioned(entry, recent)).take(2)) {
      add('INTRIGUE POSSIBLE — ${scenario.name}', scenario.summary);
    }
    for (final event in lore.events
        .where((entry) => _mentioned(entry, recent)).take(2)) {
      add('ÉVÉNEMENT NON VÉRIFIÉ — ${event.name}', [
        event.description,
        if (event.condition.isNotEmpty) 'Condition : ${event.condition}',
      ].join(' '));
    }
    return entries.join('\n\n');
  }

  static String _clip(String value, int max) {
    if (value.length <= max) return value;
    const notice = '… [suite dans le Lore]';
    if (max <= notice.length) return notice.substring(0, max);
    return '${value.substring(0, max - notice.length).trimRight()}$notice';
  }

  static bool _mentioned(LoreRecord entry, String text) {
    final haystack = _fold(text);
    for (final name in [entry.name, ...entry.aliases]) {
      final needle = _fold(name.trim());
      if (needle.length < 3) continue;
      final re = RegExp(
        r'(^|[^a-z0-9])' + RegExp.escape(needle) +
            r'($|[^a-z0-9])',
      );
      if (re.hasMatch(haystack)) return true;
    }
    return false;
  }

  static String _fold(String value) {
    const accented = 'àáâäãåçèéêëìíîïñòóôöõùúûüýÿœæ';
    const plain = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final lower = value.toLowerCase();
    final result = StringBuffer();
    for (final rune in lower.runes) {
      final c = String.fromCharCode(rune);
      final index = accented.indexOf(c);
      result.write(index < 0 ? c : plain[index]);
    }
    return result.toString();
  }
}
