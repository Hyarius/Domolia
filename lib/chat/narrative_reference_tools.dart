import 'dart:convert';

import '../ai/ai_provider.dart';
import '../books/book_lore.dart';
import '../memory/live_memory.dart';
import 'chat_protocol.dart';
import 'raw_generation.dart';

/// Read-only lookups bound to the current Book and Party by the controller.
/// SQLite has already loaded these snapshots; no remote search is performed.
class NarrativeReferenceTools {
  const NarrativeReferenceTools({
    required this.lore,
    required this.timeline,
    required this.rawGenerations,
    this.memory,
    this.memoryHistory,
  });

  final BookLore Function() lore;
  final List<ChatTimelineEvent> Function() timeline;
  final List<RawGeneration> Function() rawGenerations;
  final List<LiveMemoryFact> Function()? memory;
  final List<LiveMemoryFact> Function()? memoryHistory;

  static const definitions = <AiToolDefinition>[
    AiToolDefinition('search_memory',
        'Search sourced facts about this Party, not Book canon. Includes old details, relationships and uncertain reports.', {
      'type': 'object', 'properties': {
        'query': {'type': 'string'},
        'category': {'type': 'string', 'enum': [
          'all', 'character', 'place', 'object', 'event',
          'relationship', 'commitment', 'state']},
        'limit': {'type': 'integer', 'minimum': 1, 'maximum': 5},
      }, 'required': ['query'],
    }),
    AiToolDefinition('get_memory_entry',
        'Read a Party memory by its stable ID with certainty and source turn.', {
      'type': 'object', 'properties': {
        'id': {'type': 'string'},
      }, 'required': ['id'],
    }),
    AiToolDefinition('get_event_history',
        'Search retained past events and commitments for this Party.', {
      'type': 'object', 'properties': {
        'query': {'type': 'string'},
        'limit': {'type': 'integer', 'minimum': 1, 'maximum': 5},
      }, 'required': ['query'],
    }),
    AiToolDefinition('search_lore',
        'Search Book canon: names, aliases, IDs and descriptions. Potential events have NOT necessarily happened.', {
      'type': 'object', 'properties': {
        'query': {'type': 'string'},
        'category': {'type': 'string',
          'enum': ['character', 'place', 'scenario', 'event', 'all']},
        'limit': {'type': 'integer', 'minimum': 1, 'maximum': 5},
      }, 'required': ['query'],
    }),
    AiToolDefinition('get_lore_entry',
        'Retrieve a canonical entry including secrets, relationships and unverified conditions.', {
      'type': 'object', 'properties': {
        'category': {'type': 'string',
          'enum': ['character', 'place', 'scenario', 'event']},
        'id': {'type': 'string'},
      }, 'required': ['category', 'id'],
    }),
    AiToolDefinition('get_lore_global',
        'Read an exact global Book canon section omitted or abbreviated from the local starting briefing. Secrets must not be revealed to the player before discovery.', {
      'type': 'object', 'properties': {
        'section': {'type': 'string', 'enum': [
          'universe','overview','genre','era','initialContext',
          'history','rules','conflicts','directions','secrets']},
        'offset': {'type': 'integer', 'minimum': 0, 'maximum': 50000},
      }, 'required': ['section'],
    }),
    AiToolDefinition('search_history',
        'Search all turns in THIS Party, including player messages, compact summaries and original RAW.', {
      'type': 'object', 'properties': {
        'query': {'type': 'string'},
        'limit': {'type': 'integer', 'minimum': 1, 'maximum': 5},
      }, 'required': ['query'],
    }),
    AiToolDefinition('get_history_excerpt',
        'Read original RAW from an old turn by player_event_id or a timeline event_id; count at most 3.', {
      'type': 'object', 'properties': {
        'player_event_id': {'type': 'integer'},
        'event_id': {'type': 'integer'},
        'count': {'type': 'integer', 'minimum': 1, 'maximum': 3},
        'raw_offset': {'type': 'integer', 'minimum': 0, 'maximum': 131072},
      },
    }),
  ];

  static String _fold(String s) {
    const accent = 'àáâäãåçèéêëìíîïñòóôöõùúûüýÿœæ';
    const ascii = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final b = StringBuffer();
    for (final rune in s.toLowerCase().runes) {
      final c = String.fromCharCode(rune);
      final index = accent.indexOf(c);
      b.write(index < 0 ? c : ascii[index]);
    }
    return b.toString();
  }

  static List<String> _words(String query) =>
      RegExp(r'[a-z0-9]{2,}').allMatches(_fold(query))
          .map((m) => m.group(0)!).toSet().toList();

  static String _query(Map<String, dynamic> input) {
    final q = input['query'];
    if (q is! String || q.trim().length < 2 || q.length > 160 ||
        _words(q).isEmpty) {
      throw const FormatException('Invalid search query (2-160 characters)');
    }
    return q.trim();
  }

  static int _limit(Map<String, dynamic> input) {
    final n = input['limit'] ?? 5;
    if (n is! int || n < 1 || n > 5) {
      throw const FormatException('limit must be between 1 and 5');
    }
    return n;
  }

  static String _category(Map<String, dynamic> input, {bool all = false}) {
    final category = input['category'] ?? (all ? 'all' : null);
    if (category is! String || !{
      'character', 'place', 'scenario', 'event', if (all) 'all',
    }.contains(category)) {
      throw const FormatException('Invalid Lore category');
    }
    return category;
  }

  static int _score(String value, String query) {
    final haystack = _fold(value);
    final terms = _words(query);
    final hits = terms.where(haystack.contains).length;
    if (hits == 0) return 0;
    return hits * 5 + (hits == terms.length ? 10 : 0) +
        (haystack.contains(_fold(query)) ? 12 : 0);
  }

  static String _excerpt(String text, String query, {int size = 240}) {
    if (text.length <= size) return text;
    final folded = _fold(text), terms = _words(query);
    var index = 0;
    for (final term in terms) {
      final at = folded.indexOf(term);
      if (at != -1) { index = at; break; }
    }
    final start = (index - 45).clamp(0, text.length - size).toInt();
    return (start > 0 ? '…' : '') + text.substring(start, start + size) +
        (start + size < text.length ? '…' : '');
  }

  Iterable<(String, LoreRecord)> _entries(String category) sync* {
    final l = lore();
    if (category == 'all' || category == 'character') {
      for (final e in l.characters) {
        yield ('character', e);
      }
    }
    if (category == 'all' || category == 'place') {
      for (final e in l.places) {
        yield ('place', e);
      }
    }
    if (category == 'all' || category == 'scenario') {
      for (final e in l.scenarios) {
        yield ('scenario', e);
      }
    }
    if (category == 'all' || category == 'event') {
      for (final e in l.events) {
        yield ('event', e);
      }
    }
  }

  static dynamic _short(dynamic value) {
    if (value is String) {
      return value.length <= 800 ? value : '${value.substring(0, 800)}… [abrégé]';
    }
    if (value is List) {
      return value.take(40).map(_short).toList();
    }
    if (value is Map) {
      return {
        for (final e in value.entries) e.key.toString(): _short(e.value),
      };
    }
    return value;
  }

  /// Match the actual field containing an exact canonical detail. A short
  /// excerpt can answer a lookup without a second get_lore_entry round-trip.
  /// Secrets remain restricted to explicit full-entry retrieval.
  String _searchLore(Map<String, dynamic> input) {
    final query = _query(input);
    final results = <(int, String, LoreRecord, String, String)>[];
    for (final (type, item) in _entries(_category(input, all: true))) {
      final fields = switch (item) {
        LoreCharacter e => <String, String>{
          'description': e.description, 'background': e.background,
          'appearance': e.appearance, 'personality': e.personality,
          'motivations': e.motivations, 'values': e.values,
        },
        LorePlace e => <String, String>{
          'description': e.description, 'history': e.history,
          'features': e.features, 'atmosphere': e.atmosphere,
        },
        LoreScenario e => <String, String>{
          'description': e.description, 'summary': e.summary,
          'initialContext': e.initialContext,
          'introduction': e.introduction,
        },
        LoreEvent e => <String, String>{
          'description': e.description, 'condition': e.condition,
          'consequences': e.consequences, 'timing': e.timing,
        },
        _ => <String, String>{'description': item.description},
      };
      final nameScore = _score(
        [item.id, item.name, ...item.aliases, ...item.tags].join(' '),
        query,
      );
      var bestScore = 0;
      var bestField = 'description';
      var bestText = item.description;
      for (final field in fields.entries) {
        final score = _score(field.value, query);
        if (score > bestScore) {
          bestScore = score;
          bestField = field.key;
          bestText = field.value;
        }
      }
      final score = nameScore * 2 + bestScore;
      if (score > 0) {
        results.add((score, type, item, bestField, bestText));
      }
    }
    results.sort((a, b) {
      final score = b.$1.compareTo(a.$1);
      return score != 0 ? score : a.$3.id.compareTo(b.$3.id);
    });
    return jsonEncode({
      'source': 'book_canon',
      'results': [
        for (final (_, type, item, field, text) in results.take(_limit(input)))
          {
            'category': type, 'id': item.id, 'name': item.name,
            'matchedField': field,
            'excerpt': _excerpt(text, query, size: 260),
            if (type == 'event') 'status': 'potential_not_verified',
          },
      ],
    });
  }

  String _getLore(Map<String, dynamic> input) {
    final category = _category(input);
    final id = input['id'];
    if (id is! String || id.isEmpty || id.length > 120) {
      throw const FormatException('Invalid Lore ID');
    }
    for (final (type, entry) in _entries(category)) {
      if (entry.id != id) continue;
      final data = switch (entry) {
        LoreCharacter e => e.toJson(),
        LorePlace e => e.toJson(),
        LoreScenario e => e.toJson(),
        LoreEvent e => e.toJson(),
        _ => <String, dynamic>{},
      };
      return jsonEncode({
        'source': 'book_canon', 'category': type,
        'status': type == 'event' ? 'potential_not_verified' : 'canonical',
        if (type == 'event') 'conditionsVerified': false,
        'entry': _short(data),
      });
    }
    return jsonEncode({'source': 'book_canon', 'error': 'entry_not_found'});
  }

  String _getGlobalLore(Map<String, dynamic> input) {
    final section = input['section'];
    final offset = input['offset'] ?? 0;
    final fields = lore().global.toJson();
    if (section is! String || !fields.containsKey(section) ||
        offset is! int || offset < 0 || offset > 50000) {
      throw const FormatException('Invalid global Lore section or offset');
    }
    final value = fields[section] as String;
    final start = offset.clamp(0, value.length).toInt();
    final end = (start + 2600).clamp(0, value.length).toInt();
    return jsonEncode({
      'source': 'book_canon',
      'section': section,
      'text': value.substring(start, end),
      'offset': start,
      'total_characters': value.length,
      'has_more': end < value.length,
      'notice': section == 'secrets'
          ? 'Narrator-only secret. Never present as discovered without a witnessed in-Party event.'
          : 'Canonical Book text, not proof of any in-Party event.',
    });
  }

  List<({ChatEntry player, String text, RawGeneration? raw})> _turns() {
    final availableRaw = {
      for (final generation in rawGenerations())
        if (generation.isStructured) generation.playerEventId: generation,
    };
    final output = <({ChatEntry player, String text, RawGeneration? raw})>[];
    ChatEntry? player;
    final lines = <String>[];
    void flush() {
      if (player == null) return;
      final original = availableRaw[player.id];
      output.add((
        player: player,
        raw: original,
        text: [
          player.text,
          if (original != null) original.compactText ?? '',
          if (original != null) original.rawText,
          ...lines,
        ].join('\n'),
      ));
    }
    for (final event in timeline()) {
      if (event is ChatEntry && event.speaker == ChatSpeaker.player) {
        flush();
        player = event;
        lines.clear();
      } else if (player != null && event is ChatEntry) {
        lines.add('${event.name} : ${event.text}');
      }
    }
    flush();
    return output;
  }

  String _searchHistory(Map<String, dynamic> input) {
    final query = _query(input);
    final results = <(int, int, String, String)>[];
    for (final turn in _turns()) {
      final score = _score(turn.text, query);
      if (score > 0) {
        results.add((score, turn.player.id,
            turn.player.text, _excerpt(turn.text, query)));
      }
    }
    results.sort((a, b) {
      final byScore = b.$1.compareTo(a.$1);
      return byScore != 0 ? byScore : b.$2.compareTo(a.$2);
    });
    return jsonEncode({
      'source': 'active_party_history',
      'results': [
        for (final (_, id, player, text) in results.take(_limit(input)))
          {
            'player_event_id': id,
            'player': _excerpt(player, query, size: 120),
            'excerpt': text,
            'notice': 'Compact summaries may omit facts. RAW is available.',
          },
      ],
    });
  }

  String _getHistory(Map<String, dynamic> input) {
    final id = input['player_event_id'] ?? input['event_id'];
    final count = input['count'] ?? 1;
    final rawOffset = input['raw_offset'] ?? 0;
    if (id is! int || id < 0 || count is! int || count < 1 || count > 3 ||
        rawOffset is! int || rawOffset < 0 || rawOffset > 131072) {
      throw const FormatException('Invalid turn ID or count (maximum 3)');
    }
    final turns = _turns();
    var index = turns.indexWhere((t) => t.player.id == id);
    if (index < 0 && input['event_id'] != null) {
      final events = timeline();
      final at = events.indexWhere((e) => e.id == id);
      if (at >= 0) {
        for (var i = at; i >= 0; i--) {
          final e = events[i];
          if (e is ChatEntry && e.speaker == ChatSpeaker.player) {
            index = turns.indexWhere((t) => t.player.id == e.id);
            break;
          }
        }
      }
    }
    if (index < 0) return jsonEncode({'error': 'turn_not_found'});
    return jsonEncode({
      'source': 'active_party_history',
      'turns': [
        for (final t in turns.skip(index).take(count))
          {
            'player_event_id': t.player.id,
            'player_message': _short(t.player.text),
            if (t.raw != null) ...{
              'raw_total_characters': t.raw!.rawText.length,
              'raw_offset': rawOffset,
              'raw_original': t.raw!.rawText.substring(
                rawOffset.clamp(0, t.raw!.rawText.length),
                (rawOffset + (count == 1 ? 4500 : 1250))
                    .clamp(0, t.raw!.rawText.length),
              ),
              'raw_truncated': rawOffset +
                  (count == 1 ? 4500 : 1250) < t.raw!.rawText.length,
            },
            if (t.raw?.compactText != null)
              'compact': _short(t.raw!.compactText),
            if (t.raw == null)
              'legacy_excerpt': _excerpt(t.text, '', size: 800),
          },
      ],
    });
  }

  String _searchMemory(Map<String, dynamic> input,
      {bool eventsOnly = false}) {
    final query = _query(input);
    final category = input['category'] ?? 'all';
    if (category is! String || !{'all', 'character', 'place', 'object',
          'event', 'relationship', 'commitment', 'state'}.contains(category)) {
      throw const FormatException('Invalid memory category.');
    }
    final results = <(int, LiveMemoryFact)>[];
    final records = eventsOnly
        ? (memoryHistory?.call() ?? memory?.call())
        : memory?.call();
    for (final fact in records ?? const <LiveMemoryFact>[]) {
      if (eventsOnly && fact.category != 'event' &&
          fact.category != 'commitment' && fact.kind != 'state') { continue; }
      if (!eventsOnly && category != 'all' && fact.category != category) { continue; }
      final score = _score(
          '${fact.label} ${fact.text} ${fact.entityId}', query);
      if (score > 0) { results.add((score, fact)); }
    }
    results.sort((a, b) {
      final byScore = b.$1.compareTo(a.$1);
      return byScore != 0 ? byScore : a.$2.id.compareTo(b.$2.id);
    });
    return jsonEncode({
      'source': 'active_party_live_memory',
      'results': [
        for (final (_, fact) in results.take(_limit(input)))
          {'id': fact.id, 'category': fact.category,
           'label': fact.label, 'text': fact.text,
           'certainty': fact.certainty, 'visibility': fact.visibility,
           'source_turn_id': fact.sourceTurnId},
      ],
    });
  }

  String _getMemory(Map<String, dynamic> input) {
    final id = input['id'];
    if (id is! String || id.isEmpty || id.length > 96) {
      throw const FormatException('Invalid memory ID.');
    }
    for (final fact in memory?.call() ?? const <LiveMemoryFact>[]) {
      if (fact.id == id) {
        return jsonEncode({
          'source': 'active_party_live_memory', 'entry': fact.toJson(),
        });
      }
    }
    return jsonEncode({'source': 'active_party_live_memory',
      'error': 'entry_not_found'});
  }

  /// Bad arguments and unknown tools become bounded technical results.
  String execute(String name, String arguments) {
    try {
      if (arguments.length > 4096) {
        throw const FormatException('Tool arguments exceed 4096 characters');
      }
      final value = jsonDecode(arguments);
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Expected JSON object');
      }
      final result = switch (name) {
        'search_memory' => _searchMemory(value),
        'get_memory_entry' => _getMemory(value),
        'get_event_history' => _searchMemory(value, eventsOnly: true),
        'search_lore' => _searchLore(value),
        'get_lore_entry' => _getLore(value),
        'get_lore_global' => _getGlobalLore(value),
        'search_history' => _searchHistory(value),
        'get_history_excerpt' => _getHistory(value),
        _ => jsonEncode({'error': 'unknown_tool'}),
      };
      if (result.length > 6000) {
        return jsonEncode({'error': 'result_exceeds_budget',
          'message': 'Refine the query or request a smaller excerpt'});
      }
      return result;
    } on FormatException catch (failure) {
      return jsonEncode({'error': 'invalid_arguments', 'message': failure.message});
    } catch (_) {
      return jsonEncode({'error': 'lookup_failed'});
    }
  }
}
