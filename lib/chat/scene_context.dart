import 'dart:math';

import '../ai/ai_provider.dart';
import '../books/book_lore.dart';
import '../books/lore_startup_context.dart';
import 'chat_protocol.dart';
import 'narrator.dart';
import 'theatrical_narrator_protocol.dart';

/// Local dramaturgy and retrieval for one playable beat. All evidence comes
/// from the current branch of the Party, including after an edit or rewind.
class SceneContext {
  const SceneContext();

  static const _direction = '''
Écris en français au présent. Incarne le monde et les PNJ. Vouvoie le joueur. Le joueur seul décide de ses paroles, gestes, pensées et engagements.
Pars de son initiative et montre ce qu’elle change. En dialogue, fais répondre celui qui a quelque chose à obtenir, cacher ou concéder. Sa voix et son savoir lui appartiennent. Un geste visible peut contredire ses mots. Laisse aussi place au silence.
Arrête-toi au premier choix qui appartient au joueur. Ni menu ni question de relance automatique. Respecte le ton du Livre, les conditions, les secrets et les absences. Une intention ou une offre ne vaut pas fait accompli.''';

  static String _excerpt(String text, int limit) {
    final value = text.trim();
    if (value.length <= limit) return value;
    var end = limit - 1;
    if ((value.codeUnitAt(end - 1) & 0xfc00) == 0xd800) end--;
    final space = value.lastIndexOf(RegExp(r'\s'), end);
    if (space > end * .75) end = space;
    return '${value.substring(0, end).trimRight()}…';
  }

  /// Keep a small permanent premise even after the opening drops out.
  String premise(BookLore lore) {
    final g = lore.global;
    final main = lore.scenarios
        .where((s) => s.importance == LoreScenarioImportance.main)
        .firstOrNull;
    final fields = {
      'Univers': _excerpt(g.universe, 90),
      'Genre': _excerpt(g.genre, 70),
      'Époque': _excerpt(g.era, 60),
      'Cadre': _excerpt(g.overview, 200),
      'Au départ': _excerpt(g.initialContext, 330),
      'Règles': _excerpt(g.rules, 300),
      'Tension': _excerpt(g.conflicts, 120),
      'Direction': _excerpt(g.directions, 140),
      if (main != null)
        'Intrigue possible': _excerpt(
          '${main.name} — ${main.summary.isEmpty ? main.description : main.summary}',
          170,
        ),
    };
    return [
      for (final e in fields.entries)
        if (e.value.isNotEmpty) '${e.key} : ${e.value}',
    ].join('\n');
  }

  List<AiMessage> build({
    required List<ChatTimelineEvent> timeline,
    required Narrator narrator,
    required BookLore lore,
    required String briefing,
    required bool suggestImages,
    String Function(List<String> focus)? memory,
    int recentBudget = 2400,
  }) {
    final turns = <_PlayedTurn>[];
    var turn = _PlayedTurn();
    ChatEntry? sceneOpening;
    var openingTurn = -1;
    var afterTransition = false;
    for (final event in timeline) {
      if (event is ChatEntry && !event.inProgress) {
        if (event.speaker == ChatSpeaker.player) {
          if (!turn.isEmpty) turns.add(turn);
          turn = _PlayedTurn(action: event);
        } else {
          turn.beats.add(event);
          if (afterTransition && event.speaker == ChatSpeaker.narrator) {
            sceneOpening = event;
            openingTurn = turns.length;
            afterTransition = false;
          }
        }
      } else if (event is ChatSceneChange) {
        turn.beats.add(event);
        afterTransition = true;
        sceneOpening = null;
      }
    }
    // Only the outstanding player action is outside the history budget.
    final current = turn.beats.isEmpty ? turn.action : null;
    if (current == null && !turn.isEmpty) turns.add(turn);
    final recent = <AiMessage>[];
    var remaining = min(recentBudget, 2400);
    var firstRecent = turns.length;
    while (firstRecent > 0 && turns.length - firstRecent < 4) {
      final prior = turns[firstRecent - 1];
      final messages = prior.messages;
      final length = messages.fold<int>(0, (n, m) => n + m.content.length);
      if (length > remaining) {
        if (recent.isEmpty && remaining >= 150) {
          recent.addAll(prior.tail(remaining));
          firstRecent--;
        }
        break;
      }
      firstRecent--;
      recent.insertAll(0, messages);
      remaining -= length;
    }

    final focus = [
      if (current != null) current.text,
      ...recent.reversed.take(2).map((m) => m.content),
    ];
    final canon = const LoreStartupContextBuilder().relevant(
      lore,
      [
        ...focus,
        if (turns.every((t) => t.action == null)) lore.global.initialContext,
      ],
      maxCharacters: 800,
      dialogueFocus: true,
    );
    final memories = memory?.call(focus) ?? '';
    final recall = _recall(turns.take(firstRecent), current?.text ?? '');
    final style = narrator.narrativePrompt
        .replaceFirst(defaultNarratorNarrativePrompt.trim(), '')
        .replaceAll(
          'Ne produis ni JSON, ni balises, ni instructions destinées à une interface.',
          '',
        )
        .replaceAll(
          'Exprime naturellement la narration et les dialogues, sans format informatique.',
          '',
        )
        .trim();
    final tuning = narrator.tuning;
    tuning.validate();
    final maxWords = [90, 170, 270, 450, 700][tuning.responseLength - 1];
    final system = [
      _direction,
      if (narrator.protocolPrompt.trim() !=
          defaultNarratorProtocolPrompt.trim())
        narrator.protocolPrompt.trim(),
      if (style.isNotEmpty) style,
      'Jusqu’à $maxWords mots. ${NarrativeTuning.pacingDescriptions[tuning.scenePacing - 1]}',
      if (tuning.styleKeywords.isNotEmpty) tuning.styleKeywords.join(', '),
      theatricalNarratorProtocol.trim(),
      if (suggestImages) theatricalIllustrationInstruction,
      if (briefing.isNotEmpty) 'Livre\n$briefing',
      if (canon.isNotEmpty) 'Fiches du Livre\n$canon',
      if (sceneOpening != null && openingTurn < firstRecent)
        'À l’ouverture de cette scène : ${_excerpt(sceneOpening.text, 180)}',
      if (memories.isNotEmpty) 'Souvenirs de partie\n$memories',
    ].join('\n');
    return [
      AiMessage(role: 'system', content: system),
      ...recall,
      ...recent,
      if (current != null) AiMessage(role: 'user', content: current.text),
    ];
  }

  static final _summaryPrefix = RegExp(
    r'^Résumé narratif factuel du tour\s*:\s*',
    caseSensitive: false,
  );
  static final _unsafeName = RegExp(r'[\[\]\r\n|@]');
  static String _header(ChatEntry entry) {
    final name = entry.name.trim();
    if (entry.speaker != ChatSpeaker.character ||
        name.isEmpty ||
        name.length > 50 ||
        _unsafeName.hasMatch(name) ||
        {
          'vous',
          'joueur',
          'moi',
          'player',
          'narrateur',
          'narrator',
        }.contains(name.toLowerCase())) {
      return '*';
    }
    final status = entry.status?.trim() ?? '';
    return status.isEmpty || status.length > 50 || _unsafeName.hasMatch(status)
        ? '@$name'
        : '@$name|$status';
  }

  static final _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);
  static const _stop = {
    'qui',
    'que',
    'une',
    'des',
    'les',
    'aux',
    'oui',
    'non',
    'son',
    'ses',
    'est',
    'sur',
    'par',
    'mon',
    'mes',
    'dit',
    'ici',
    'lui',
    'ils',
    'cet',
    'peu',
    'pas',
    'toi',
    'moi',
    'leur',
    'sans',
    'avec',
    'alors',
    'vous',
    'elle',
    'elles',
    'nous',
    'pour',
    'dans',
    'plus',
    'suis',
    'cette',
    'comme',
    'sont',
    'était',
    'demande',
    'encore',
    'mais',
    'quoi',
    'faire',
    'cela',
    'veux',
    'bien',
    'tout',
    'comment',
    'pourquoi',
  };

  // Return one attributed exchange. Player claims stay in the user role.
  List<AiMessage> _recall(Iterable<_PlayedTurn> turns, String query) {
    final terms = _word
        .allMatches(query.toLowerCase())
        .map((m) => m[0]!)
        .where(
          (w) =>
              (w.length >= 3 || int.tryParse(w) != null) && !_stop.contains(w),
        )
        .toSet();
    if (terms.isEmpty) return [];
    String passage(String text, int limit) {
      if (text.length <= limit) return text;
      final match = _word
          .allMatches(text)
          .where((m) => terms.contains(m[0]!.toLowerCase()))
          .firstOrNull;
      if (match == null || match.end < limit) return _excerpt(text, limit);
      // Start near the matched word, preferably at a sentence boundary.
      final before = max(0, match.start - limit ~/ 3);
      final boundary = text.indexOf(RegExp(r'[.!?]\s+|\n'), before);
      final space = text.indexOf(' ', before);
      final start = boundary >= 0 && boundary < match.start
          ? boundary + 1
          : space >= 0 && space < match.start
          ? space + 1
          : match.start;
      return '…${_excerpt(text.substring(start), limit - 1)}';
    }

    ChatEntry? action;
    ChatEntry? line;
    var best = 0;
    for (final turn in turns) {
      final player = turn.action;
      if (player == null) continue;
      int hits(String text) => _word
          .allMatches(text.toLowerCase())
          .map((m) => m[0]!)
          .toSet()
          .intersection(terms)
          .length;
      final playerHits = hits(player.text);
      for (final e in turn.beats.whereType<ChatEntry>()) {
        final score = playerHits + 2 * hits('${e.name} ${e.text}');
        if (score > 0 && score >= best) {
          best = score;
          action = player;
          line = e;
        }
      }
    }
    if (action == null || line == null) return [];
    return [
      AiMessage(
        role: 'user',
        content: '(Tour ancien) ${passage(action.text, 130)}',
      ),
      AiMessage(
        role: 'assistant',
        content: '${_header(line)}\n${passage(line.text, 300)}',
      ),
    ];
  }
}

class _PlayedTurn {
  _PlayedTurn({this.action});
  final ChatEntry? action;
  final beats = <ChatTimelineEvent>[];

  bool get isEmpty => action == null && beats.isEmpty;

  List<AiMessage> get messages {
    final script = <String>[];
    for (final beat in beats) {
      if (beat is ChatSceneChange) {
        script.add('---');
      } else if (beat is ChatEntry) {
        final text = beat.text
            .replaceFirst(SceneContext._summaryPrefix, '')
            .trim();
        if (text.isNotEmpty) script.add('${SceneContext._header(beat)}\n$text');
      }
    }
    return [
      if (action != null) AiMessage(role: 'user', content: action!.text),
      if (script.isNotEmpty)
        AiMessage(role: 'assistant', content: script.join('\n')),
    ];
  }

  List<AiMessage> tail(int budget) {
    final last = beats.whereType<ChatEntry>().lastOrNull;
    if (last == null) return [];
    final header = SceneContext._header(last);
    final text = last.text.trim();
    var start = max(0, text.length - budget + header.length + 3);
    if (start < text.length && (text.codeUnitAt(start) & 0xfc00) == 0xdc00) {
      start++;
    }
    return [
      AiMessage(
        role: 'assistant',
        content: '$header\n${start > 0 ? '…' : ''}${text.substring(start)}',
      ),
    ];
  }
}
