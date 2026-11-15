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
}
