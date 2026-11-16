import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/narrative_stream_buffer.dart';

void main() {
  test('NDJSON fragments create stable in-progress bubble IDs', () {
    final buffer = NarrativeStreamBuffer();
    buffer.add('{"type":"message","speaker":"narrator",'
        '"name":"Narrateur","text":"La porte');
    final first = buffer.previewEvents(42).single as ChatEntry;
    expect(first.id, 42);
    expect(first.text, 'La porte');
    expect(first.inProgress, true);
    buffer.add(' s’ouvre."}\\n{"type":"message","speaker":"character",'
        '"name":"Oren","status":"prudent","text":"Bonjour');
    final partial = buffer.previewEvents(42);
    expect(partial.map((e) => e.id), [42, 43]);
    expect((partial.first as ChatEntry).text, 'La porte s’ouvre.');
    expect((partial.last as ChatEntry).text, 'Bonjour');
    buffer.add(', voyageur."}');
    final events = buffer.finish();
    expect(events, hasLength(2));
    expect((events.last as ChatLine).status, 'prudent');
    expect(buffer.storyText(), contains('Oren : Bonjour, voyageur.'));
  });

  test('scene changes never create draft bubbles with broken JSON', () {
    final buffer = NarrativeStreamBuffer();
    buffer.add('{"type":"message","speaker":"narrator",'
        '"name":"Narrateur","text":"Une porte."}\\n');
    buffer.add('{"type":"scene_change"');
    expect(buffer.previewEvents(1), hasLength(1));
    buffer.add('}\\n{"type":"message","speaker":"character",'
        '"name":"Oren","text":"Entrez."}');
    final events = buffer.finish();
    expect(events[1], isA<ChatSceneChangeOutput>());
    expect(buffer.previewEvents(1).map((e) => e.id), [1, 2, 3]);
  });

  test('broken JSON and player impersonation reject the entire turn', () {
    final malformed = NarrativeStreamBuffer();
    malformed.add('{"type":"message","speaker":"narrator",'
        '"name":"Narrateur","text":"Début."}\\n');
    expect(() => malformed.add('{INVALID}\\n'), throwsFormatException);
    final spoof = NarrativeStreamBuffer();
    expect(() => spoof.add(jsonEncode({
      'type': 'message', 'speaker': 'player', 'name': 'Vous',
      'text': 'Je promets.'
    }) + '\\n'), throwsFormatException);
  });

  test('trailing scene separators are rejected before persistence', () {
    final buffer = NarrativeStreamBuffer();
    buffer.add('{"type":"message","speaker":"narrator",'
        '"name":"Narrateur","text":"Au revoir."}\\n'
        '{"type":"scene_change"}');
    expect(buffer.finish, throwsFormatException);
  });

  test('no temporary preview of raw JSON punctuation', () {
    final buffer = NarrativeStreamBuffer();
    buffer.add('{"type":"message","speaker":"character","name":"Oren",'
        '"text":"La cl');
    expect((buffer.previewEvents(1).single as ChatEntry).text, 'La cl');
    buffer.add('é est ici."}');
    expect(buffer.finish(), hasLength(1));
    expect(buffer.storyText(), 'Oren : La clé est ici.');
  });
}
