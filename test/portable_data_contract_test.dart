import 'dart:convert';

import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('portable Book JSON preserves cover and omits credential fields', () {
    // A valid one-pixel WebP. Cover bytes, not file paths, must travel.
    // PR #7 separately fixes PNG/JPEG validation on the existing main branch.
    const cover = 'UklGRh4AAABXRUJQVlA4TBEAAAAvAAAAAAdQrXrUqP+BiOh/AAA=';
    const book = BookDefinition(
      id: 'book-portable',
      title: 'Livre portable',
      coverBase64: cover,
      coverMime: 'image/webp',
      tags: {'nsfw'},
      narrativeStyle: 'Narration personnelle.',
      detailLevel: 4,
      openingMessages: ['Bienvenue.'],
    );

    final encoded = book.exportJson();
    final decoded = BookDefinition.importJson(encoded);
    final object = jsonDecode(encoded) as Map<String, dynamic>;

    expect(decoded.id, book.id);
    expect(decoded.coverBase64, cover);
    expect(decoded.coverMime, 'image/webp');
    expect(decoded.detailLevel, 4);
    expect(decoded.tags, contains('nsfw'));
    expect(object.keys, isNot(contains('apiKey')));
    expect(object.keys, isNot(contains('refreshToken')));
    expect(object.keys, isNot(contains('profileId')));
  });

  test('part timeline roundtrips speaker roles and scene separators', () {
    const session = BookSession(
      id: 'session-portable',
      bookId: 'book-portable',
      title: 'Première partie',
      timeline: <ChatTimelineEvent>[
        ChatEntry(
          id: 0, speaker: ChatSpeaker.player, name: 'Vous', text: 'Bonjour',
        ),
        ChatSceneChange(id: 1),
        ChatEntry(
          id: 2, speaker: ChatSpeaker.narrator, name: 'Narrateur',
          text: 'Une nouvelle scène commence.',
        ),
      ],
    );

    final decoded = BookSession.decodeTimeline(session.encodeTimeline());
    expect(decoded, hasLength(3));
    expect((decoded[0] as ChatEntry).speaker, ChatSpeaker.player);
    expect(decoded[1], isA<ChatSceneChange>());
    expect((decoded[2] as ChatEntry).text, 'Une nouvelle scène commence.');
  });

  test('part timeline rejects reused event ids before restoration', () {
    const invalid = '['
        '{"id":1,"type":"scene_change"},'
        '{"id":1,"type":"message","speaker":"player",'
        '"name":"Vous","text":"Collision"}'
        ']';
    expect(() => BookSession.decodeTimeline(invalid), throwsFormatException);
  });
}
