import 'dart:convert';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Narrator and different characters become distinct messages', () {
    final parser = ChatLineDecoder();
    final lines = [
      {'speaker': 'narrator', 'name': 'Narrateur', 'text': 'La porte s’ouvre.'},
      {'speaker': 'character', 'name': 'Lina', 'text': 'Entre !'},
      {'speaker': 'character', 'name': 'Marc', 'text': 'Il fait froid.'},
    ];
    final raw = lines.map(jsonEncode).join('\n');
    final all = <ChatLine>[];
    for (var i = 0; i < raw.length; i += 7) {
      final end = i + 7 > raw.length ? raw.length : i + 7;
      all.addAll(parser.add(raw.substring(i, end)));
    }
    all.addAll(parser.finish());
    expect(all, hasLength(3));
    expect(all.map((x) => x.speaker), [
      ChatSpeaker.narrator, ChatSpeaker.character, ChatSpeaker.character,
    ]);
    expect(all.map((x) => x.name), ['Narrateur', 'Lina', 'Marc']);
  });

  test('Incremental JSON renders speaker text, not JSON punctuation', () {
    final parser = ChatLineDecoder();
    parser.add('{"speaker":"character","name":"Lina","text":"Bon');
    expect(parser.preview!.name, 'Lina');
    expect(parser.preview!.text, 'Bon');
    parser.add('jour, voyageur');
    expect(parser.preview!.text, 'Bonjour, voyageur');
    final complete = parser.add(' !"}\n');
    expect(complete.single.text, 'Bonjour, voyageur !');
    expect(parser.preview, isNull);
  });

  test('Escaped quotes are decoded', () {
    final parser = ChatLineDecoder();
    final raw = jsonEncode({
      'speaker': 'character', 'name': 'Lina',
      'text': 'Elle dit : "Bonjour".',
    });
    parser.add(raw.substring(0, raw.length - 3));
    expect(parser.preview!.text, contains('Bonjour'));
    final parsed = parser.add('${raw.substring(raw.length - 3)}\n');
    expect(parsed.single.text, 'Elle dit : "Bonjour".');
  });

  test('Narrator always has its canonical name', () {
    final parser = ChatLineDecoder();
    final result = parser.add(
      '{"speaker":"narrator","name":"Malicious","text":"Il pleut."}\n',
    );
    expect(result.single.name, 'Narrateur');
  });

  for (final raw in [
    '{"speaker":"player","name":"Vous","text":"Je pars."}',
    '{"speaker":"character","name":"Vous","text":"Je pars."}',
    '{"speaker":"character","name":"Narrateur","text":"Je pars."}',
    '{"speaker":"character","name":"","text":"Bonjour."}',
    '{"speaker":"narrator","name":"Narrateur","text":""}',
    '{"speaker":"narrator","name":"Narrateur","text":true}',
    'NOT JSON',
  ]) {
    test('Invalid / player-spoofing model output rejected', () {
      final parser = ChatLineDecoder();
      expect(() => parser.add('$raw\n'), throwsFormatException);
    });
  }

  test('Limit to 20 generated messages per turn', () {
    final parser = ChatLineDecoder();
    final line = jsonEncode({
      'speaker': 'narrator', 'name': 'Narrateur', 'text': 'Une phrase.',
    });
    expect(parser.add('${List.filled(20, line).join('\n')}\n'), hasLength(20));
    expect(() => parser.add('$line\n'), throwsFormatException);
  });

  test('Long model stream rejected', () {
    final parser = ChatLineDecoder();
    expect(() => parser.add('a' * 131073), throwsFormatException);
  });
}
