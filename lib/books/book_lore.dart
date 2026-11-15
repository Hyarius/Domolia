import 'dart:convert';
import 'dart:math';

/// Portable, author-owned canonical material. Never stores per-session state.
class BookLore {
  const BookLore({
    this.global = const LoreGlobal(),
    this.characters = const [],
    this.places = const [],
    this.scenarios = const [],
    this.events = const [],
  });

  static const maxEntriesPerSection = 250;
  static const maxLoreBytes = 1536 * 1024;

  final LoreGlobal global;
  final List<LoreCharacter> characters;
  final List<LorePlace> places;
  final List<LoreScenario> scenarios;
  final List<LoreEvent> events;

  bool get isEmpty => global.isEmpty && characters.isEmpty &&
      places.isEmpty && scenarios.isEmpty && events.isEmpty;

  Map<String, Object?> toJson() => {
    'global': global.toJson(),
    'characters': characters.map((item) => item.toJson()).toList(),
    'places': places.map((item) => item.toJson()).toList(),
    'scenarios': scenarios.map((item) => item.toJson()).toList(),
    'events': events.map((item) => item.toJson()).toList(),
  };

  factory BookLore.fromJson(Object? value) {
    final map = loreObject(value, {
      'global', 'characters', 'places', 'scenarios', 'events',
    }, 'Lore');
    List<T> list<T>(String key, T Function(Object?) decode) {
      final raw = map[key];
      if (raw is! List || raw.length > maxEntriesPerSection) {
        throw FormatException('Liste de Lore invalide : $key.');
      }
      return List<T>.unmodifiable(raw.map(decode));
    }
    final lore = BookLore(
      global: LoreGlobal.fromJson(map['global']),
      characters: list('characters', LoreCharacter.fromJson),
      places: list('places', LorePlace.fromJson),
      scenarios: list('scenarios', LoreScenario.fromJson),
      events: list('events', LoreEvent.fromJson),
    );
    lore.validate();
    return lore;
  }

  BookLore copyWith({
    LoreGlobal? global,
    List<LoreCharacter>? characters,
    List<LorePlace>? places,
    List<LoreScenario>? scenarios,
    List<LoreEvent>? events,
  }) => BookLore(
    global: global ?? this.global,
    characters: characters ?? this.characters,
    places: places ?? this.places,
    scenarios: scenarios ?? this.scenarios,
    events: events ?? this.events,
  );

  BookLore putCharacter(LoreCharacter value) =>
      copyWith(characters: _upsert(characters, value, (e) => e.id));
  BookLore putPlace(LorePlace value) =>
      copyWith(places: _upsert(places, value, (e) => e.id));
  BookLore putScenario(LoreScenario value) =>
      copyWith(scenarios: _upsert(scenarios, value, (e) => e.id));
  BookLore putEvent(LoreEvent value) =>
      copyWith(events: _upsert(events, value, (e) => e.id));

  static List<T> _upsert<T>(List<T> previous, T value, String Function(T) id) {
    final next = [...previous];
    final index = next.indexWhere((e) => id(e) == id(value));
    if (index < 0) {
      next.add(value);
    } else {
      next[index] = value;
    }
    return List<T>.unmodifiable(next);
  }

  /// All incoming references are surfaced before a destructive operation.
  List<String> referencesTo(String id) => [
    for (final p in characters)
      if (p.relatedCharacterIds.contains(id) || p.homePlaceId == id)
        'Personnage : ${p.name}',
    for (final p in places)
      if (p.characterIds.contains(id) || p.placeIds.contains(id))
        'Lieu : ${p.name}',
    for (final p in scenarios)
      if (p.characterIds.contains(id) || p.placeIds.contains(id) ||
          p.eventIds.contains(id))
        'Scénario : ${p.title}',
    for (final e in events)
      if (e.characterIds.contains(id) || e.placeIds.contains(id) ||
          e.scenarioIds.contains(id))
        'Événement : ${e.title}',
  ];

  /// Explicit unlinking, never dangling IDs or deletion of referenced records.
  BookLore remove(String category, String id, {bool unlink = false}) {
    final incoming = referencesTo(id);
    if (incoming.isNotEmpty && !unlink) {
      throw FormatException('Fiche référencée par : ${incoming.join(", ")}.');
    }
    final next = copyWith(
      characters: [
        for (final p in characters)
          if (category != 'characters' || p.id != id)
            p.copyWith(
              relatedCharacterIds: p.relatedCharacterIds.where((r) => r != id).toList(),
              clearHomePlace: p.homePlaceId == id,
            ),
      ],
      places: [
        for (final p in places)
          if (category != 'places' || p.id != id)
            p.copyWith(
              characterIds: p.characterIds.where((r) => r != id).toList(),
              placeIds: p.placeIds.where((r) => r != id).toList(),
            ),
      ],
      scenarios: [
        for (final s in scenarios)
          if (category != 'scenarios' || s.id != id)
            s.copyWith(
              characterIds: s.characterIds.where((r) => r != id).toList(),
              placeIds: s.placeIds.where((r) => r != id).toList(),
              eventIds: s.eventIds.where((r) => r != id).toList(),
            ),
      ],
      events: [
        for (final e in events)
          if (category != 'events' || e.id != id)
            e.copyWith(
              characterIds: e.characterIds.where((r) => r != id).toList(),
              placeIds: e.placeIds.where((r) => r != id).toList(),
              scenarioIds: e.scenarioIds.where((r) => r != id).toList(),
            ),
      ],
    );
    next.validate();
    return next;
  }

  void validate() {
    global.validate();
    if ([characters.length, places.length, scenarios.length, events.length]
        .any((count) => count > maxEntriesPerSection)) {
      throw const FormatException('Trop de fiches de Lore.');
    }
    final allIds = <String>{};
    final characterIds = characters.map((e) => e.id).toSet();
    final placeIds = places.map((e) => e.id).toSet();
    final scenarioIds = scenarios.map((e) => e.id).toSet();
    final eventIds = events.map((e) => e.id).toSet();
    for (final record in <LoreRecord>[
      ...characters, ...places, ...scenarios, ...events,
    ]) {
      record.validate();
      if (!allIds.add(record.id)) {
        throw const FormatException('Identifiants de Lore dupliqués.');
      }
    }
    void check(Iterable<String> ids, Set<String> existing, String owner) {
      if (ids.any((id) => !existing.contains(id))) {
        throw FormatException('Référence de Lore invalide : $owner.');
      }
    }
    for (final c in characters) {
      check(c.relatedCharacterIds, characterIds, c.name);
      if (c.relatedCharacterIds.contains(c.id)) {
        throw const FormatException('Un personnage ne peut se référencer lui-même.');
      }
      if (c.homePlaceId != null) check([c.homePlaceId!], placeIds, c.name);
    }
    for (final p in places) {
      check(p.characterIds, characterIds, p.name);
      check(p.placeIds, placeIds, p.name);
      if (p.placeIds.contains(p.id)) {
        throw const FormatException('Un lieu ne peut se référencer lui-même.');
      }
    }
    for (final s in scenarios) {
      check(s.characterIds, characterIds, s.title);
      check(s.placeIds, placeIds, s.title);
      check(s.eventIds, eventIds, s.title);
    }
    for (final e in events) {
      check(e.characterIds, characterIds, e.title);
      check(e.placeIds, placeIds, e.title);
      check(e.scenarioIds, scenarioIds, e.title);
    }
    if (utf8.encode(jsonEncode(toJson())).length > maxLoreBytes) {
      throw const FormatException('Lore trop volumineux (1,5 Mio maximum).');
    }
  }
}

String newLoreId() {
  final random = Random.secure();
  return 'lore-${DateTime.now().microsecondsSinceEpoch}-'
      '${random.nextInt(0x7fffffff).toRadixString(16)}';
}

Map<String, dynamic> loreObject(
    Object? value, Set<String> allowed, String label) {
  if (value is! Map<String, dynamic> ||
      value.keys.any((key) => !allowed.contains(key)) ||
      allowed.any((key) => !value.containsKey(key))) {
    throw FormatException('Schéma de Lore invalide : $label.');
  }
  return value;
}

String loreString(Map<String, dynamic> map, String key, {int max = 12000}) {
  final value = map[key];
  if (value is! String || value.length > max) {
    throw FormatException('Champ de Lore invalide : $key.');
  }
  return value;
}

List<String> loreStrings(Map<String, dynamic> map, String key,
    {int max = 80}) {
  final value = map[key];
  if (value is! List || value.length > max ||
      value.any((e) => e is! String || e.trim().isEmpty || e.length > 120) ||
      value.toSet().length != value.length) {
    throw FormatException('Liste de Lore invalide : $key.');
  }
  return List<String>.unmodifiable(value.cast<String>());
}

class LoreGlobal {
  const LoreGlobal({
    this.universe = '',
    this.overview = '',
    this.genre = '',
    this.era = '',
    this.initialContext = '',
    this.history = '',
    this.rules = '',
    this.conflicts = '',
    this.directions = '',
    this.secrets = '',
  });
  final String universe, overview, genre, era, initialContext, history;
  final String rules, conflicts, directions, secrets;

  bool get isEmpty => [
    universe, overview, genre, era, initialContext, history,
    rules, conflicts, directions, secrets,
  ].every((s) => s.trim().isEmpty);

  Map<String, Object?> toJson() => {
    'universe': universe, 'overview': overview, 'genre': genre, 'era': era,
    'initialContext': initialContext, 'history': history, 'rules': rules,
    'conflicts': conflicts, 'directions': directions, 'secrets': secrets,
  };
  factory LoreGlobal.fromJson(Object? value) {
    final map = loreObject(value, const {
      'universe', 'overview', 'genre', 'era', 'initialContext', 'history',
      'rules', 'conflicts', 'directions', 'secrets',
    }, 'global');
    return LoreGlobal(
      universe: loreString(map, 'universe', max: 120),
      overview: loreString(map, 'overview'),
      genre: loreString(map, 'genre', max: 250),
      era: loreString(map, 'era', max: 250),
      initialContext: loreString(map, 'initialContext'),
      history: loreString(map, 'history'),
      rules: loreString(map, 'rules'),
      conflicts: loreString(map, 'conflicts'),
      directions: loreString(map, 'directions'),
      secrets: loreString(map, 'secrets'),
    );
  }
  void validate() => LoreGlobal.fromJson(toJson());
}

abstract class LoreRecord {
  const LoreRecord({
    required this.id,
    required this.name,
    this.description = '',
    this.aliases = const [],
    this.tags = const [],
    this.secrets = '',
  });
  final String id, name, description, secrets;
  final List<String> aliases, tags;
  Map<String, Object?> baseJson() => {
    'id': id, 'name': name, 'description': description,
    'aliases': aliases, 'tags': tags, 'secrets': secrets,
  };
  void validate() {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(id) ||
        name.trim().isEmpty || name.length > 150 ||
        description.length > 12000 || secrets.length > 12000 ||
        aliases.length > 80 || tags.length > 80 ||
        aliases.any((e) => e.trim().isEmpty || e.length > 120) ||
        tags.any((e) => e.trim().isEmpty || e.length > 120) ||
        aliases.toSet().length != aliases.length ||
        tags.toSet().length != tags.length) {
      throw FormatException('Fiche de Lore invalide : $name.');
    }
  }

  static List<String> ids(Map<String, dynamic> map, String key) =>
      loreStrings(map, key);
}

class LoreCharacter extends LoreRecord {
  const LoreCharacter({
    required super.id, required super.name,
    super.description, super.aliases, super.tags, super.secrets,
    this.appearance = '', this.personality = '', this.background = '',
    this.role = '', this.motivations = '', this.values = '',
    this.relatedCharacterIds = const [], this.homePlaceId,
  });
  final String appearance, personality, background, role, motivations, values;
  final List<String> relatedCharacterIds;
  final String? homePlaceId;

  Map<String, Object?> toJson() => {
    ...baseJson(), 'appearance': appearance, 'personality': personality,
    'background': background, 'role': role, 'motivations': motivations,
    'values': values, 'relatedCharacterIds': relatedCharacterIds,
    'homePlaceId': homePlaceId,
  };

  factory LoreCharacter.fromJson(Object? value) {
    final map = loreObject(value, const {
      'id','name','description','aliases','tags','secrets',
      'appearance','personality','background','role','motivations','values',
      'relatedCharacterIds','homePlaceId',
    }, 'personnage');
    if (map['homePlaceId'] != null && map['homePlaceId'] is! String) {
      throw const FormatException('Lieu du personnage invalide.');
    }
    return LoreCharacter(
      id: loreString(map,'id',max:100),
      name: loreString(map,'name',max:150),
      description: loreString(map,'description'),
      aliases: loreStrings(map,'aliases'), tags: loreStrings(map,'tags'),
      secrets: loreString(map,'secrets'),
      appearance: loreString(map,'appearance'),
      personality: loreString(map,'personality'),
      background: loreString(map,'background'),
      role: loreString(map,'role',max:150),
      motivations: loreString(map,'motivations'),
      values: loreString(map,'values'),
      relatedCharacterIds: LoreRecord.ids(map,'relatedCharacterIds'),
      homePlaceId: map['homePlaceId'] as String?,
    );
  }
  LoreCharacter copyWith({List<String>? relatedCharacterIds,
      String? homePlaceId, bool clearHomePlace = false}) => LoreCharacter(
    id: id, name: name, description: description, aliases: aliases, tags: tags,
    secrets: secrets, appearance: appearance, personality: personality,
    background: background, role: role, motivations: motivations, values: values,
    relatedCharacterIds: relatedCharacterIds ?? this.relatedCharacterIds,
    homePlaceId: clearHomePlace ? null : homePlaceId ?? this.homePlaceId,
  );
  @override
  void validate() {
    super.validate();
    LoreCharacter.fromJson(toJson());
  }
}

class LorePlace extends LoreRecord {
  const LorePlace({
    required super.id, required super.name,
    super.description, super.aliases, super.tags, super.secrets,
    this.type = '', this.atmosphere = '', this.history = '',
    this.features = '', this.characterIds = const [], this.placeIds = const [],
  });
  final String type, atmosphere, history, features;
  final List<String> characterIds, placeIds;
  Map<String, Object?> toJson() => {
    ...baseJson(), 'type': type, 'atmosphere': atmosphere,
    'history': history, 'features': features,
    'characterIds': characterIds, 'placeIds': placeIds,
  };
  factory LorePlace.fromJson(Object? value) {
    final m = loreObject(value, const {
      'id','name','description','aliases','tags','secrets','type',
      'atmosphere','history','features','characterIds','placeIds',
    }, 'lieu');
    return LorePlace(
      id: loreString(m,'id',max:100), name: loreString(m,'name',max:150),
      description: loreString(m,'description'), aliases: loreStrings(m,'aliases'),
      tags: loreStrings(m,'tags'), secrets: loreString(m,'secrets'),
      type: loreString(m,'type',max:150),
      atmosphere: loreString(m,'atmosphere'), history: loreString(m,'history'),
      features: loreString(m,'features'),
      characterIds: LoreRecord.ids(m,'characterIds'),
      placeIds: LoreRecord.ids(m,'placeIds'),
    );
  }
  LorePlace copyWith({List<String>? characterIds, List<String>? placeIds}) =>
      LorePlace(id:id,name:name,description:description,aliases:aliases,tags:tags,
        secrets:secrets,type:type,atmosphere:atmosphere,history:history,
        features:features,characterIds:characterIds??this.characterIds,
        placeIds:placeIds??this.placeIds);
  @override
  void validate() {
    super.validate();
    LorePlace.fromJson(toJson());
  }
}

enum LoreScenarioImportance { main, secondary }

class LoreScenario extends LoreRecord {
  const LoreScenario({
    required super.id, required super.name,
    super.description, super.aliases, super.tags, super.secrets,
    this.summary = '', this.importance = LoreScenarioImportance.secondary,
    this.initialContext = '', this.objectives = '', this.introduction = '',
    this.characterIds = const [], this.placeIds = const [],
    this.eventIds = const [],
  });
  String get title => name;
  final String summary, initialContext, objectives, introduction;
  final LoreScenarioImportance importance;
  final List<String> characterIds, placeIds, eventIds;
  Map<String, Object?> toJson() => {
    ...baseJson(), 'summary': summary, 'importance': importance.name,
    'initialContext': initialContext, 'objectives': objectives,
    'introduction': introduction, 'characterIds': characterIds,
    'placeIds': placeIds, 'eventIds': eventIds,
  };
  factory LoreScenario.fromJson(Object? value) {
    final m = loreObject(value, const {
      'id','name','description','aliases','tags','secrets','summary',
      'importance','initialContext','objectives','introduction','characterIds',
      'placeIds','eventIds',
    }, 'scénario');
    final importance = m['importance'];
    if (importance is! String ||
        !LoreScenarioImportance.values.any((v) => v.name == importance)) {
      throw const FormatException('Importance de scénario invalide.');
    }
    return LoreScenario(
      id: loreString(m,'id',max:100),name:loreString(m,'name',max:150),
      description:loreString(m,'description'),aliases:loreStrings(m,'aliases'),
      tags:loreStrings(m,'tags'),secrets:loreString(m,'secrets'),
      summary:loreString(m,'summary'),
      importance: LoreScenarioImportance.values.byName(importance),
      initialContext:loreString(m,'initialContext'),
      objectives:loreString(m,'objectives'),
      introduction:loreString(m,'introduction'),
      characterIds:LoreRecord.ids(m,'characterIds'),
      placeIds:LoreRecord.ids(m,'placeIds'),eventIds:LoreRecord.ids(m,'eventIds'),
    );
  }
  LoreScenario copyWith({List<String>? characterIds, List<String>? placeIds,
      List<String>? eventIds}) => LoreScenario(
    id:id,name:name,description:description,aliases:aliases,tags:tags,secrets:secrets,
    summary:summary,importance:importance,initialContext:initialContext,
    objectives:objectives,introduction:introduction,
    characterIds:characterIds??this.characterIds,
    placeIds:placeIds??this.placeIds,eventIds:eventIds??this.eventIds,
  );
  @override
  void validate() {
    super.validate();
    LoreScenario.fromJson(toJson());
  }
}

enum LoreEventTrigger { planned, conditional, optional }

class LoreEvent extends LoreRecord {
  const LoreEvent({
    required super.id, required super.name,
    super.description, super.aliases, super.tags, super.secrets,
    this.trigger = LoreEventTrigger.optional,
    this.condition = '', this.mandatory = false,
    this.timing = '', this.consequences = '', this.priority = 0,
    this.characterIds = const [], this.placeIds = const [],
    this.scenarioIds = const [],
  });
  String get title => name;
  final LoreEventTrigger trigger;
  final String condition, timing, consequences;
  final bool mandatory;
  final int priority;
  final List<String> characterIds, placeIds, scenarioIds;
  Map<String, Object?> toJson() => {
    ...baseJson(), 'trigger': trigger.name, 'condition': condition,
    'mandatory': mandatory, 'timing': timing, 'consequences': consequences,
    'priority': priority, 'characterIds': characterIds,
    'placeIds': placeIds, 'scenarioIds': scenarioIds,
  };
  factory LoreEvent.fromJson(Object? value) {
    final m = loreObject(value, const {
      'id','name','description','aliases','tags','secrets','trigger','condition',
      'mandatory','timing','consequences','priority','characterIds',
      'placeIds','scenarioIds',
    }, 'événement');
    final trigger = m['trigger'];
    if (trigger is! String ||
        !LoreEventTrigger.values.any((v) => v.name == trigger) ||
        m['mandatory'] is! bool || m['priority'] is! int) {
      throw const FormatException('Déclenchement d’événement invalide.');
    }
    return LoreEvent(
      id:loreString(m,'id',max:100),name:loreString(m,'name',max:150),
      description:loreString(m,'description'),aliases:loreStrings(m,'aliases'),
      tags:loreStrings(m,'tags'),secrets:loreString(m,'secrets'),
      trigger:LoreEventTrigger.values.byName(trigger),
      condition:loreString(m,'condition'),
      mandatory:m['mandatory'] as bool, timing:loreString(m,'timing'),
      consequences:loreString(m,'consequences'),priority:m['priority'] as int,
      characterIds:LoreRecord.ids(m,'characterIds'),
      placeIds:LoreRecord.ids(m,'placeIds'),
      scenarioIds:LoreRecord.ids(m,'scenarioIds'),
    );
  }
  LoreEvent copyWith({List<String>? characterIds, List<String>? placeIds,
      List<String>? scenarioIds}) => LoreEvent(
    id:id,name:name,description:description,aliases:aliases,tags:tags,secrets:secrets,
    trigger:trigger,condition:condition,mandatory:mandatory,timing:timing,
    consequences:consequences,priority:priority,
    characterIds:characterIds??this.characterIds,
    placeIds:placeIds??this.placeIds,scenarioIds:scenarioIds??this.scenarioIds,
  );
  @override
  void validate() {
    super.validate();
    if (priority < 0 || priority > 10 ||
        (trigger == LoreEventTrigger.conditional && condition.trim().isEmpty)) {
      throw const FormatException('Condition ou priorité d’événement invalide.');
    }
    LoreEvent.fromJson(toJson());
  }
}
