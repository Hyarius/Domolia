import 'package:crypto/crypto.dart';
import '../chat/raw_generation.dart';
import 'dart:convert';

/// A sourced assertion in one Party, never an instruction or a Book canon edit.
class LiveMemoryFact {
  const LiveMemoryFact({
    required this.id,
    required this.category,
    required this.entityId,
    required this.label,
    required this.field,
    required this.text,
    required this.kind,
    required this.certainty,
    required this.visibility,
    required this.importance,
    required this.sourceTurnId,
    required this.sourceSide,
    required this.sourceQuote,
    this.loreId,
    this.pinned = false,
    this.manual = false,
  });

  final String id;
  final String category;
  final String entityId;
  final String label;
  final String field;
  final String text;
  final String kind; // stable, state, event
  final String certainty; // confirmed, reported, uncertain
  final String visibility; // player, narrator
  final int importance;
  final int sourceTurnId;
  final String sourceSide; // raw, player, manual
  final String sourceQuote;
  final String? loreId;
  final bool pinned;
  final bool manual;

  Map<String, dynamic> toJson() => {
    'id': id, 'category': category, 'entity': entityId, 'label': label,
    'field': field, 'text': text, 'kind': kind, 'certainty': certainty,
    'visibility': visibility, 'importance': importance,
    'sourceTurnId': sourceTurnId, 'sourceSide': sourceSide,
    'sourceQuote': sourceQuote, if (loreId != null) 'loreId': loreId,
    'pinned': pinned, 'manual': manual,
  };

  LiveMemoryFact copyWith({String? text, String? certainty,
      bool? pinned, bool? manual, String? sourceSide, String? sourceQuote}) =>
      LiveMemoryFact(
        id: id, category: category, entityId: entityId, label: label,
        field: field, text: text ?? this.text, kind: kind,
        certainty: certainty ?? this.certainty, visibility: visibility,
        importance: importance, sourceTurnId: sourceTurnId,
        sourceSide: sourceSide ?? this.sourceSide,
        sourceQuote: sourceQuote ?? this.sourceQuote,
        loreId: loreId, pinned: pinned ?? this.pinned,
        manual: manual ?? this.manual,
      );

  static LiveMemoryFact fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid memory fact.');
    }
    String s(String key, {int max = 800}) {
      final v = value[key];
      if (v is! String || v.isEmpty || v.length > max) {
        throw FormatException('Invalid memory $key.');
      }
      return v;
    }
    final id = s('id', max: 96);
    if (!RegExp(r'^[a-z0-9][a-z0-9:_-]{2,95}$').hasMatch(id)) {
      throw const FormatException('Invalid memory ID.');
    }
    final category = s('category', max: 24);
    final kind = s('kind', max: 16);
    final certainty = s('certainty', max: 16);
    final visibility = s('visibility', max: 16);
    final side = s('sourceSide', max: 16);
    if (!{'character', 'place', 'object', 'event', 'relationship',
      'commitment', 'state'}.contains(category) ||
        !{'stable', 'state', 'event'}.contains(kind) ||
        !{'confirmed', 'reported', 'uncertain'}.contains(certainty) ||
        !{'player', 'narrator'}.contains(visibility) ||
        !{'raw', 'player', 'manual'}.contains(side)) {
      throw const FormatException('Invalid memory classification.');
    }
    final importance = value['importance'];
    final turn = value['sourceTurnId'];
    if (importance is! int || importance < 1 || importance > 5 ||
        turn is! int || turn < 0) {
      throw const FormatException('Invalid memory importance or source.');
    }
    final lore = value['loreId'];
    if (lore != null && (lore is! String || lore.length > 120)) {
      throw const FormatException('Invalid canonical reference.');
    }
    return LiveMemoryFact(
      id: id, category: category, entityId: s('entity', max: 96),
      label: s('label', max: 100), field: s('field', max: 80),
      text: s('text'), kind: kind, certainty: certainty,
      visibility: visibility, importance: importance,
      sourceTurnId: turn, sourceSide: side,
      sourceQuote: s('sourceQuote', max: 320),
      loreId: lore as String?, pinned: value['pinned'] == true,
      manual: value['manual'] == true,
    );
  }
}

/// Validated operation proposed by an untrusted extractor. The quote must
/// literally occur in the persisted player message or validated RAW.
class LiveMemoryOperation {
  const LiveMemoryOperation({required this.action, required this.fact});
  final String action; // upsert or retract
  final LiveMemoryFact fact;

  Map<String, dynamic> toJson() => {'action': action, 'fact': fact.toJson()};

  static List<LiveMemoryOperation> parse(String response, {
    required int playerEventId,
    required String playerText,
    required String validatedRaw,
  }) {
    if (response.length > 32000) {
      throw const FormatException('Memory extraction too large.');
    }
    final parsed = jsonDecode(response);
    if (parsed is! Map<String, dynamic> ||
        parsed.length != 1 || parsed['operations'] is! List) {
      throw const FormatException('Expected strict memory operations JSON.');
    }
    final ops = parsed['operations'] as List;
    if (ops.length > 24) {
      throw const FormatException('Too many memory operations.');
    }
    final result = <LiveMemoryOperation>[];
    final seen = <String>{};
    for (final value in ops) {
      if (value is! Map<String, dynamic> ||
          value.keys.toSet().difference({'action', 'id', 'category',
            'entity', 'label', 'field', 'text', 'kind', 'certainty',
            'visibility', 'importance', 'sourceSide', 'quote',
            'loreId'}).isNotEmpty ||
          value['action'] is! String) {
        throw const FormatException('Malformed memory operation.');
      }
      final action = value['action'] as String;
      if (!{'upsert', 'retract'}.contains(action)) {
        throw const FormatException('Unsupported memory operation.');
      }
      final side = value['sourceSide'];
      final quote = value['quote'];
      if (side != 'raw' && side != 'player' ||
          quote is! String || quote.length < 3 || quote.length > 320 ||
          !(side == 'raw' ? validatedRaw : playerText).contains(quote)) {
        throw const FormatException('Unverifiable memory source quote.');
      }
      // Parse and validate all classifications before applying any operation.
      final fact = LiveMemoryFact.fromJson({
        ...value, 'sourceTurnId': playerEventId,
        'sourceSide': side, 'sourceQuote': quote,
      }..remove('action')..remove('quote'));
      if (!seen.add(fact.id)) {
        throw const FormatException('Duplicate memory operation ID.');
      }
      result.add(LiveMemoryOperation(action: action, fact: fact));
    }
    return List.unmodifiable(result);
  }

  static List<LiveMemoryOperation> decodeSaved(String encoded) {
    final raw = jsonDecode(encoded);
    if (raw is! List || raw.length > 24) {
      throw const FormatException('Invalid stored memory operations.');
    }
    return [
      for (final row in raw)
        if (row is Map<String, dynamic> &&
            {'upsert', 'retract'}.contains(row['action']))
          LiveMemoryOperation(
            action: row['action'] as String,
            fact: LiveMemoryFact.fromJson(row['fact']),
          )
        else
          throw const FormatException('Invalid stored memory operation.'),
    ];
  }
}

/// Stored separately from generated operations. Manual removals are tombstones,
/// so a future replay cannot resurrect unwanted facts.
class LiveMemoryOverride {
  const LiveMemoryOverride(this.id, {this.fact, this.deleted = false});
  final String id;
  final LiveMemoryFact? fact;
  final bool deleted;
}

class LiveMemoryProjection {
  static List<LiveMemoryFact> replay(
      Iterable<List<LiveMemoryOperation>> turns,
      Iterable<LiveMemoryOverride> overrides) {
    final facts = <String, LiveMemoryFact>{};
    for (final ops in turns) {
      for (final op in ops) {
        if (op.action == 'retract') {
          facts.remove(op.fact.id);
        } else {
          // Stable IDs are required; near-identical assertions from different
          // spellings of a name share an established category+field.
          final equivalent = facts.values.where((f) =>
              f.category == op.fact.category &&
              f.field == op.fact.field &&
              f.kind != 'event' && op.fact.kind != 'event' &&
              f.label.toLowerCase() == op.fact.label.toLowerCase());
          if (equivalent.isNotEmpty && equivalent.first.id != op.fact.id) {
            facts.remove(equivalent.first.id);
          }
          facts[op.fact.id] = op.fact;
        }
      }
    }
    for (final override in overrides) {
      if (override.deleted) {
        facts.remove(override.id);
      } else if (override.fact != null) {
        facts[override.id] = override.fact!;
      }
    }
    return List.unmodifiable(facts.values);
  }
}

/// Conservative deterministic selection; old high-value details remain eligible.
class LiveMemorySelector {
  const LiveMemorySelector({this.maxCharacters = 3600});
  final int maxCharacters;
  static Set<String> words(String input) => RegExp(r'[a-z0-9]{3,}')
      .allMatches(input.toLowerCase())
      .map((m) => m.group(0)!).toSet();

  String build(Iterable<LiveMemoryFact> facts, Iterable<String> recent) {
    final query = words(recent.join(' '));
    final ranked = <(int, LiveMemoryFact)>[];
    for (final fact in facts) {
      final keys = words('${fact.label} ${fact.entityId} ${fact.text}');
      final hits = keys.intersection(query).length;
      final active = fact.category == 'state' ||
          fact.category == 'commitment' ||
          fact.kind == 'state';
      final score = fact.importance * 4 + hits * 12 +
          (active ? 18 : 0) + (fact.pinned ? 12 : 0);
      ranked.add((score, fact));
    }
    ranked.sort((a, b) {
      final byScore = b.$1.compareTo(a.$1);
      return byScore != 0 ? byScore : a.$2.id.compareTo(b.$2.id);
    });
    final out = StringBuffer();
    for (final (_, fact) in ranked) {
      final line = '[${fact.category}/${fact.kind}; ${fact.certainty}; '
          '${fact.visibility}; source: tour ${fact.sourceTurnId}] '
          '${fact.label} — ${fact.text}\n';
      if (out.length + line.length > maxCharacters) continue;
      out.write(line);
    }
    return out.toString();
  }
}

String liveMemorySourceHash(RawGeneration generation) => sha256.convert(
    utf8.encode('${generation.playerEventId}:'
        '${generation.firstEventId}:${generation.lastEventId}:'
        '${generation.rawText}')).toString();
