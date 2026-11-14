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
    final all = <ChatOutputEvent>[];
    for (var i = 0; i < raw.length; i += 7) {
      final end = i + 7 > raw.length ? raw.length : i + 7;
      all.addAll(parser.add(raw.substring(i, end)));
    }
    all.addAll(parser.finish());
    expect(all, hasLength(3));
    expect(all.whereType<ChatLine>().map((x) => x.speaker), [
      ChatSpeaker.narrator, ChatSpeaker.character, ChatSpeaker.character,
    ]);
    expect(all.whereType<ChatLine>().map((x) => x.name), ['Narrateur', 'Lina', 'Marc']);
  });

  test('Incremental JSON renders speaker text, not JSON punctuation', () {
    final parser = ChatLineDecoder();
    parser.add('{"speaker":"character","name":"Lina","text":"Bon');
    expect(parser.preview!.name, 'Lina');
    expect(parser.preview!.text, 'Bon');
    parser.add('jour, voyageur');
    expect(parser.preview!.text, 'Bonjour, voyageur');
    final complete = parser.add(' !"}\n');
    expect((complete.single as ChatLine).text, 'Bonjour, voyageur !');
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
    expect((parsed.single as ChatLine).text, 'Elle dit : "Bonjour".');
  });

  test('Narrator always has its canonical name', () {
    final parser = ChatLineDecoder();
    final result = parser.add(
      '{"speaker":"narrator","name":"Malicious","text":"Il pleut."}\n',
    );
    expect((result.single as ChatLine).name, 'Narrateur');
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
  test('Untitled scene delimiter is a distinct NDJSON event', () {
    final parser = ChatLineDecoder();
    final output = parser.add(
      '{"type":"message","speaker":"character","name":"Lina",'
      '"text":"Viens !"}\n'
      '{"type":"scene_change"}\n'
      '{"type":"message","speaker":"narrator","name":"Narrateur",'
      '"text":"La porte s’ouvre."}\n',
    );
    expect(output, hasLength(3));
    expect(output[0], isA<ChatLine>());
    expect(output[1], isA<ChatSceneChangeOutput>());
    expect(output[2], isA<ChatLine>());
    expect((output[2] as ChatLine).text, 'La porte s’ouvre.');
  });

  test('Scene separator waits for a complete valid JSON line', () {
    final parser = ChatLineDecoder();
    expect(parser.add('{"type":"scene_'), isEmpty);
    expect(parser.add('change"'), isEmpty);
    expect(parser.isPendingSceneChange, true);
    expect(parser.preview, isNull);
    expect(parser.add('}\n'), [isA<ChatSceneChangeOutput>()]);
    expect(parser.isPendingSceneChange, false);
  });

  test('Scene boundaries cannot have a title or any extra metadata', () {
    for (final raw in [
      '{"type":"scene_change","title":"New place"}',
      '{"type":"scene_change","location":"Somewhere"}',
      '{"type":"scene_change","name":"Scene 2"}',
      '{"type":"unknown"}',
    ]) {
      final parser = ChatLineDecoder();
      expect(() => parser.add('$raw\n'), throwsFormatException);
    }
  });

  test('Scene marker is valid as final event without newline', () {
    final parser = ChatLineDecoder();
    parser.add('{"type":"scene_change"}');
    expect(parser.finish(), [isA<ChatSceneChangeOutput>()]);
  });

}
