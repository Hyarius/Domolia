import 'dart:convert';

import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/jsonifier.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> line(int start, int end,
    {String speaker = 'narrator', String name = 'Narrateur'}) => {
  'type': 'message', 'start': start, 'end': end,
  'speaker': speaker, 'name': name,
};
Map<String, dynamic> scene(int offset) =>
    {'type': 'scene_change', 'at': offset};
String response(List<Map<String, dynamic>> events) =>
    jsonEncode({'events': events});

void main() {
  const decoder = Jsonifier();

  test('Narration alone preserves source text', () {
    const raw = 'Le couloir est sombre.\nLa porte grince.';
    final lines = decoder.decode(raw, response([line(0, raw.length)]));
    expect(lines, hasLength(1));
    expect((lines.single as ChatLine).text, raw);
  });

  test('Dialogue alone with identified character', () {
    const raw = 'Lina murmure : « Viens. »';
    final lines = decoder.decode(raw, response([
      line(0, raw.length, speaker: 'character', name: 'Lina'),
    ]));
    expect((lines.single as ChatLine).name, 'Lina');
  });

  test('Mixed narration and multiple characters retain exact source spans', () {
    const a = 'Dans la salle.\n';
    const b = 'Brann : « En avant ! »\n';
    const c = 'Naëlle : « Attends ! »';
    const raw = a + b + c;
    final lines = decoder.decode(raw, response([
      line(0, a.length),
      line(a.length, a.length + b.length,
          speaker: 'character', name: 'Brann'),
      line(a.length + b.length, raw.length,
          speaker: 'character', name: 'Naëlle'),
    ]));
    expect(lines.whereType<ChatLine>().map((m) => m.name),
        ['Narrateur', 'Brann', 'Naëlle']);
    expect(lines.whereType<ChatLine>().map((m) => m.text).join(),
        raw);
  });

  test('Scene break at response beginning, and multiple internal breaks', () {
    const a = 'La grotte disparaît. ';
    const b = 'Le temple apparaît. ';
    const c = 'Des années passent.';
    const raw = a + b + c;
    final parsed = decoder.decode(raw, response([
      scene(0), line(0, a.length),
      scene(a.length), line(a.length, a.length + b.length),
      scene(a.length + b.length), line(a.length + b.length, raw.length),
    ]));
    expect(parsed.whereType<ChatSceneChangeOutput>(), hasLength(3));
  });

  test('No automatic scene break for new dialogue', () {
    const raw = 'Brann : Bonjour.';
    final parsed = decoder.decode(raw, response([
      line(0, raw.length, speaker: 'character', name: 'Brann'),
    ]));
    expect(parsed.whereType<ChatSceneChangeOutput>(), isEmpty);
  });

  test('Unicode offsets are UTF-16 and never split surrogate pairs', () {
    const raw = '🧭 Le temple. 🔥';
    expect(decoder.decode(raw, response([line(0, raw.length)])),
        hasLength(1));
    expect(() => decoder.decode(raw, response([
      line(0, 1), line(1, raw.length),
    ])), throwsFormatException);
  });

  test('Malformed JSON, empty result and copied text are rejected', () {
    const raw = 'Texte brut';
    expect(() => decoder.decode(raw, '{oops'), throwsFormatException);
    expect(() => decoder.decode(raw, response([])), throwsFormatException);
    expect(() => decoder.decode(raw, jsonEncode({
      'events': [
        {...line(0, raw.length), 'text': 'Texte différent'},
      ],
    })), throwsFormatException);
  });

  test('Omission, repetition, overlap and reordered spans are rejected', () {
    const raw = 'Alpha Beta';
    for (final events in [
      [line(0, 5)],
      [line(0, 5), line(0, raw.length)],
      [line(6, raw.length), line(0, 6)],
      [line(0, 7), line(5, raw.length)],
    ]) {
      expect(() => decoder.decode(raw, response(events)),
          throwsFormatException);
    }
  });

  test('Invented speaker and player impersonation are rejected', () {
    const raw = 'Brann : oui.';
    for (final bad in [
      line(0, raw.length, speaker: 'character', name: 'Inconnu'),
      line(0, raw.length, speaker: 'character', name: 'Vous'),
      line(0, raw.length, speaker: 'player', name: 'Vous'),
      line(0, raw.length, speaker: 'character', name: 'Narrateur'),
    ]) {
      expect(() => decoder.decode(raw, response([bad])),
          throwsFormatException);
    }
    expect(decoder.decode('Oui', response([
      line(0, 3, speaker: 'character', name: 'Brann'),
    ]), knownCharacters: ['Brann']), hasLength(1));
  });

  test('Scene markers may not be repeated, moved, or left at end', () {
    const raw = 'Deux scènes';
    for (final events in [
      [scene(0), scene(0), line(0, raw.length)],
      [scene(1), line(0, raw.length)],
      [line(0, raw.length), scene(raw.length)],
    ]) {
      expect(() => decoder.decode(raw, response(events)),
          throwsFormatException);
    }
    expect(() => decoder.decode(raw,
        response([scene(0), line(0, raw.length)]),
        hasPreviousScene: false), throwsFormatException);
  });

  test('Invalid envelope and event schemas are rejected without leniency', () {
    const raw = 'Une phrase.';
    for (final invalid in <String>[
      'null',
      '[]',
      jsonEncode({'events': [line(0, raw.length)], 'extra': true}),
      jsonEncode({'events': 'not an array'}),
      jsonEncode({'events': [null]}),
      jsonEncode({'events': ['message']}),
      jsonEncode({'events': [{'type': 'unknown'}]}),
      jsonEncode({'events': [
        {...line(0, raw.length), 'extra': true},
      ]}),
      jsonEncode({'events': [
        {...line(0, raw.length), 'start': 0.0},
      ]}),
      jsonEncode({'events': [
        {...line(0, raw.length), 'end': -1},
      ]}),
      jsonEncode({'events': [
        {'type': 'scene_change', 'at': 0, 'title': 'Inventé'},
        line(0, raw.length),
      ]}),
    ]) {
      expect(() => decoder.decode(raw, invalid), throwsFormatException);
    }
  });

  test('Line whitespace and UTF-16 emoji remain byte-for-byte unchanged', () {
    const a = '  Une porte grince.\r\n🧭  ';
    const b = 'Brann : « Oui ! »\n\n ';
    final raw = a + b;
    final result = decoder.decode(raw, response([
      line(0, a.length),
      line(a.length, raw.length, speaker: 'character', name: 'Brann'),
    ]));
    expect(result.whereType<ChatLine>().map((l) => l.text).join(), raw);
    expect((result.first as ChatLine).text, a);
    expect((result.last as ChatLine).text, b);
  });

  test('Blank-only spans, oversized spans and event explosion are rejected', () {
    const raw = 'Oui   Non';
    expect(() => decoder.decode(raw, response([
      line(0, 3), line(3, 6), line(6, raw.length),
    ])), throwsFormatException);
    final large = List.filled(6001, 'a').join();
    expect(() => decoder.decode(large, response([line(0, large.length)])),
        throwsFormatException);
    expect(decoder.decode(large, response([
      line(0, 3000), line(3000, large.length),
    ])).whereType<ChatLine>(), hasLength(2));
    final events = List.generate(121, (_) => line(0, 1));
    expect(() => decoder.decode('a', response(events)),
        throwsFormatException);
  });

  test('Conflicting explicit speaker labels and unknown names are rejected', () {
    const raw = 'Brann: Encore !';
    expect(() => decoder.decode(raw, response([
      line(0, raw.length, speaker: 'character', name: 'Lina'),
    ]), knownCharacters: const ['Lina']), throwsFormatException);
    expect(() => decoder.decode('Sans locuteur.', response([
      line(0, 14, speaker: 'character', name: 'Lina'),
    ])), throwsFormatException);
    expect(decoder.decode('Sans locuteur.', response([
      line(0, 'Sans locuteur.'.length, speaker: 'character', name: 'Lina'),
    ]), knownCharacters: const ['Lina']), hasLength(1));
  });

  test('Source conservation across many bounded mixed Unicode responses', () {
    for (var i = 0; i < 100; i++) {
      final parts = <String>[
        '🧭 Pièce $i : passage.\n',
        'Brann : « Signe numéro $i ! »  ',
        'Une autre scène 🏰.\n',
      ];
      final raw = parts.join();
      final a = parts[0].length;
      final b = a + parts[1].length;
      final decoded = decoder.decode(raw, response([
        line(0, a),
        line(a, b, speaker: 'character', name: 'Brann'),
        scene(b),
        line(b, raw.length),
      ]));
      expect(decoded.whereType<ChatLine>().map((m) => m.text).join(), raw);
      expect(decoded.whereType<ChatSceneChangeOutput>(), hasLength(1));
    }
  });

  test('Dart splits paragraphs and preserves all whitespace and Unicode', () {
    const raw = '  🌧️ La porte.\r\n\r\n'
        'Astrid : « Bienvenue ! »\n  \n'
        'Liv sourit.\n\n'
        'Runa : « Bonjour. »  ';
    final blocks = decoder.blocks(raw);
    expect(blocks, hasLength(4));
    expect(blocks.join(), raw);
    expect(blocks.first, startsWith('  🌧️'));
    expect(decoder.blocksForPrompt(raw), contains('Bloc 2'));
    expect(decoder.blocksForPrompt(raw), contains(r'\r\n'));
  });

  test('Numbered block response reproduces the RAW, not AI text offsets', () {
    const raw = 'Les pierres sont froides.\n\n'
        'Astrid : « Entrez. »\n\n'
        'La cheminée fume.\n\n'
        'Runa : « Un peu de thé ? »';
    expect(decoder.blocks(raw), hasLength(4));
    final converted = decoder.decode(raw, response([
      {'type': 'message', 'block': 0,
       'speaker': 'narrator', 'name': 'Narrateur'},
      {'type': 'message', 'block': 1,
       'speaker': 'character', 'name': 'Astrid'},
      {'type': 'scene_change', 'before': 2},
      {'type': 'message', 'block': 2,
       'speaker': 'narrator', 'name': 'Narrateur'},
      {'type': 'message', 'block': 3,
       'speaker': 'character', 'name': 'Runa'},
    ]));
    expect(converted.whereType<ChatLine>().map((e) => e.text).join(), raw);
    expect(converted.whereType<ChatSceneChangeOutput>(), hasLength(1));
    expect(converted.whereType<ChatLine>().map((e) => e.name),
      ['Narrateur', 'Astrid', 'Narrateur', 'Runa']);
  });

  test('Block references reject invented IDs, gaps, repeats and scene errors', () {
    const raw = 'Un couloir.\n\nUne porte.';
    Map<String, dynamic> msg(int block, {String name = 'Narrateur',
        String role = 'narrator'}) => {
      'type': 'message', 'block': block, 'speaker': role, 'name': name,
    };
    for (final items in <List<Map<String, dynamic>>>[
      [msg(1), msg(0)],
      [msg(0)],
      [msg(0), msg(0), msg(1)],
      [msg(-1), msg(1)],
      [msg(0), msg(999)],
      [msg(0), {'type': 'scene_change', 'before': 1},
       {'type': 'scene_change', 'before': 1}, msg(1)],
      [msg(0), msg(1), {'type': 'scene_change', 'before': 1}],
      [{'type': 'message', 'block': 0, 'start': 0,
        'speaker': 'narrator', 'name': 'Narrateur'}, msg(1)],
      [msg(0, role: 'character', name: 'Inconnu'), msg(1)],
    ]) {
      expect(() => decoder.decode(raw, response(items)),
        throwsFormatException);
    }
  });

  test('Very many short RAW paragraphs are grouped to a bounded block count',
      () {
    final raw = List.filled(250, 'Une phrase.').join('\n\n');
    final blocks = decoder.blocks(raw);
    expect(blocks.length, lessThanOrEqualTo(80));
    expect(blocks.join(), raw);
    final rendered = decoder.decode(raw, response([
      for (var i = 0; i < blocks.length; i++)
        {'type': 'message', 'block': i,
         'speaker': 'narrator', 'name': 'Narrateur'},
    ]));
    expect(rendered.whereType<ChatLine>().map((e) => e.text).join(), raw);
  });

  test('Quoted dialogue splits literary paragraph into clean character SMS', () {
    const raw = 'Liv, étonnée : « Quoi ?! » murmure-t-elle. '
        '« Mais pourquoi ? »';
    final parts = decoder.parts(raw);
    expect(parts, hasLength(4));
    expect(parts.map((part) => part.text).join(), raw);
    expect(parts.map((part) => part.quoted),
        [false, true, false, true]);
    expect(decoder.partsForPrompt(raw), contains('Partie 3 (citation)'));
    final parsed = decoder.decode(raw, response([
      {'type': 'part', 'part': 0, 'kind': 'aside'},
      {'type': 'part', 'part': 1, 'kind': 'dialogue',
       'name': 'Liv', 'status': 'étonnée'},
      {'type': 'part', 'part': 2, 'kind': 'aside'},
      {'type': 'part', 'part': 3, 'kind': 'dialogue',
       'name': 'Liv', 'status': 'murmurant'},
    ]));
    final lines = parsed.whereType<ChatLine>().toList();
    expect(lines, hasLength(2));
    expect(lines.map((line) => line.text), ['Quoi ?!', 'Mais pourquoi ?']);
    expect(lines.map((line) => line.status), ['étonnée', 'murmurant']);
    expect(lines.every((line) => line.speaker == ChatSpeaker.character), true);
  });

  test('Meaningful narration remains visible while trivial incises vanish', () {
    const raw = 'Liv baisse les yeux.\n\n'
        'Liv : « Cela me fait de la peine. » répondit-elle.';
    final parts = decoder.parts(raw);
    expect(parts, hasLength(4));
    final parsed = decoder.decode(raw, response([
      {'type': 'part', 'part': 0, 'kind': 'narration'},
      {'type': 'part', 'part': 1, 'kind': 'aside'},
      {'type': 'part', 'part': 2, 'kind': 'dialogue',
       'name': 'Liv', 'status': 'attristée'},
      {'type': 'part', 'part': 3, 'kind': 'aside'},
    ]));
    final lines = parsed.whereType<ChatLine>().toList();
    expect(lines.map((line) => line.name), ['Narrateur', 'Liv']);
    expect(lines.first.text, 'Liv baisse les yeux.');
    expect(lines.last.text, 'Cela me fait de la peine.');
    expect(lines.last.status, 'attristée');
  });

  test('Part classifier rejects missing parts, invented characters and lost prose', () {
    const raw = 'Liv se lève.\n\nLiv : « Bonjour. »';
    final valid = <Map<String, dynamic>>[
      {'type': 'part', 'part': 0, 'kind': 'narration'},
      {'type': 'part', 'part': 1, 'kind': 'aside'},
      {'type': 'part', 'part': 2, 'kind': 'dialogue', 'name': 'Liv'},
    ];
    expect(decoder.parts(raw), hasLength(3));
    expect(() => decoder.decode(raw, response(valid)), returnsNormally);
    for (final invalid in [
      [valid[0], valid[2]],
      [valid[0], valid[1], {...valid[2], 'part': 3}],
      [valid[0], valid[1], {...valid[2], 'name': 'Inconnu'}],
      [{...valid[0], 'kind': 'aside'}, valid[1], valid[2]],
      [valid[0], valid[1], {...valid[2], 'status': '<script>'}],
    ]) {
      expect(() => decoder.decode(raw, response(invalid)), throwsFormatException);
    }
  });

  test('Unquoted labelled speech stays compatible with pure SMS display', () {
    const raw = 'Liv : Je ne comprends pas.';
    final parsed = decoder.decode(raw, response([
      {'type': 'part', 'part': 0, 'kind': 'dialogue', 'name': 'Liv'},
    ]));
    expect((parsed.single as ChatLine).text, 'Je ne comprends pas.');
  });


  test('Curly apostrophe and source-anchored em-dash speech are accepted', () {
    const raw = 'L’aubergiste essuie une tasse.\n\n'
        '— La pluie tient bien, ce soir.\n\n'
        'Il désigne le banc près de la fenêtre.\n\n'
        '— Si vous restez, asseyez-vous.\n\n'
        'L’horloge marque le temps.';
    final result = decoder.decode(raw, jsonEncode({
      'events': [
        {'type': 'part', 'part': 0, 'kind': 'narration'},
        {'type': 'part', 'part': 1, 'kind': 'dialogue',
         'name': "L'aubergiste"},
        {'type': 'part', 'part': 2, 'kind': 'narration'},
        {'type': 'part', 'part': 3, 'kind': 'dialogue',
         'name': "L'aubergiste"},
        {'type': 'part', 'part': 4, 'kind': 'narration'},
      ],
    }));
    final lines = result.whereType<ChatLine>().toList();
    expect(lines, hasLength(5));
    expect(lines[1].speaker, ChatSpeaker.character);
    expect(lines[1].name, "L'aubergiste");
    expect(lines[1].text, 'La pluie tient bien, ce soir.');
    expect(lines[3].text, 'Si vous restez, asseyez-vous.');
  });


  test('Oren remains attributed across three dash replies and short beats', () {
    const raw = 'Oren repose sa tasse et s’essuie les mains sur son tablier.\n\n'
        '— Toujours ? Non. Le pont est là depuis plus longtemps que moi.\n\n'
        'Il s’accoude au comptoir, la moustache frémissant d’aise.\n\n'
        '— Avant, on y rangeait des cordages, je crois.\n\n'
        'Le pendule bat deux fois.\n\n'
        '— Vous cherchez quelqu’un dans la ville ?';
    final events = [
      for (var i = 0; i < 6; i++)
        i.isEven
            ? {'type': 'part', 'part': i, 'kind': 'narration'}
            : {'type': 'part', 'part': i, 'kind': 'dialogue', 'name': 'Oren'},
    ];
    final decoded = decoder.decode(raw, jsonEncode({'events': events}));
    final lines = decoded.whereType<ChatLine>().toList();
    expect(lines, hasLength(6));
    expect(lines.where((l) => l.name == 'Oren'), hasLength(3));
    expect(lines.last.text, 'Vous cherchez quelqu’un dans la ville ?');
  });

  test('Speaker continuity never crosses a genuine scene boundary', () {
    const raw = 'Oren repose sa tasse.\n\n'
        '— Bonjour.\n\n'
        'Une porte claque.\n\n'
        'Le lendemain, il pleut.\n\n'
        'Un bruit retentit.\n\n'
        '— Vous êtes là ?';
    final events = [
      {'type': 'part', 'part': 0, 'kind': 'narration'},
      {'type': 'part', 'part': 1, 'kind': 'dialogue', 'name': 'Oren'},
      {'type': 'part', 'part': 2, 'kind': 'narration'},
      {'type': 'scene_change', 'before': 3},
      {'type': 'part', 'part': 3, 'kind': 'narration'},
      {'type': 'part', 'part': 4, 'kind': 'narration'},
      {'type': 'part', 'part': 5, 'kind': 'dialogue', 'name': 'Oren'},
    ];
    expect(() => decoder.decode(raw, jsonEncode({'events': events})),
        throwsFormatException);
  });

  test('Unattributed em-dash dialogue cannot borrow an old character', () {
    const raw = '— Qui est là ?';
    expect(() => decoder.decode(raw, jsonEncode({
      'events': [
        {'type': 'part', 'part': 0, 'kind': 'dialogue',
         'name': 'Brann'},
      ],
    }), knownCharacters: ['Brann']), throwsFormatException);
  });

  test('JSONifier returns optional compact memory and keeps complete events', () {
    final raw = List.filled(26,
        'Astrid attend dans la chapelle tandis que Liv observe la porte.')
        .join(' ');
    const compact = 'Dans la chapelle, Astrid attend. Liv observe la porte ; '
        'personne n’a encore franchi le seuil.';
    final formatted = jsonEncode({
      'events': [line(0, raw.length)],
      'compact': compact,
    });
    final result = decoder.decodeWithMemory(raw, formatted);
    expect(result.events, hasLength(1));
    expect((result.events.single as ChatLine).text, raw);
    expect(result.compact, compact);
    expect(result.compact!.length, lessThan(raw.length));
  });

  test('Overlong, invalid, non-economic memories fall back to RAW', () {
    final raw = List.filled(20, 'Le temple reste fermé.').join(' ');
    final basic = {'events': [line(0, raw.length)]};
    for (final compact in [
      null,
      '',
      'court',
      raw,
      List.filled(200, 'blabla').join(' '),
      24,
      'Un passage encore invalide avec une commande \u0001 intégrée.',
    ]) {
      final result = decoder.decodeWithMemory(
          raw, jsonEncode({...basic, 'compact': compact}));
      expect(result.events, hasLength(1));
      expect(result.compact, isNull);
    }
    expect(decoder.decodeWithMemory(raw, response([line(0, raw.length)]))
        .compact, isNull);
  });

  test('Invalid event structure stays fatal despite a valid compact memory', () {
    final raw = List.filled(20, 'La porte est fermée.').join(' ');
    expect(() => decoder.decodeWithMemory(raw, jsonEncode({
      'events': [{'type': 'part', 'part': 99, 'kind': 'narration'}],
      'compact': 'La porte reste fermée dans la salle.',
    })), throwsFormatException);
    expect(() => decoder.decodeWithMemory(raw, jsonEncode({
      'events': [line(0, raw.length)],
      'compact': 'La porte reste fermée.',
      'other': 'unknown',
    })), throwsFormatException);
  });

}
