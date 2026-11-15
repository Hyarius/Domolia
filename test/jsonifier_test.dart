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

}
