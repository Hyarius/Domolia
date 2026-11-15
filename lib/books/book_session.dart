import 'dart:convert';
import 'dart:math';

import '../chat/chat_protocol.dart';

/// Personal and never included in a BookDefinition export.
class BookSession {
  const BookSession({
    required this.id,
    required this.bookId,
    required this.title,
    this.timeline = const [],
    this.aiProfileId,
    this.updatedAtUtc,
  });

  final String id;
  final String bookId;
  final String title;
  final List<ChatTimelineEvent> timeline;
  /// Overrides the parent Book's default AI profile for this conversation.
  final String? aiProfileId;
  final DateTime? updatedAtUtc;

  static String freshId() =>
      'session-${DateTime.now().microsecondsSinceEpoch}-'
      '${Random.secure().nextInt(0x7fffffff)}';

  BookSession copyWith({String? title, List<ChatTimelineEvent>? timeline,
      String? aiProfileId, bool clearAiProfile = false, DateTime? updatedAtUtc}) => BookSession(
        id: id,
        bookId: bookId,
        title: title ?? this.title,
        timeline: timeline ?? this.timeline,
        aiProfileId: clearAiProfile ? null : aiProfileId ?? this.aiProfileId,
        updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      );

  String encodeTimeline() => jsonEncode([
        for (final event in timeline)
          if (event is ChatSceneChange)
            {'id': event.id, 'type': 'scene_change'}
          else if (event is ChatEntry)
            {
              'id': event.id,
              'type': 'message',
              'speaker': event.speaker.name,
              'name': event.name,
              'text': event.text,
            },
      ]);

  static List<ChatTimelineEvent> decodeTimeline(String raw) {
    final parsed = jsonDecode(raw);
    if (parsed is! List || parsed.length > 50000) {
      throw const FormatException('Historique de partie invalide.');
    }
    final result = <ChatTimelineEvent>[];
    var previousId = -1;
    for (final item in parsed) {
      if (item is! Map<String, dynamic> || item['id'] is! int) {
        throw const FormatException('Événement de partie invalide.');
      }
      final id = item['id'] as int;
      if (id <= previousId) {
        throw const FormatException('Ordre des événements invalide.');
      }
      previousId = id;
      if (item['type'] == 'scene_change' && item.length == 2) {
        result.add(ChatSceneChange(id: id));
      } else if (item['type'] == 'message' &&
          item['speaker'] is String &&
          item['name'] is String && item['text'] is String &&
          ChatSpeaker.values.any((s) => s.name == item['speaker'])) {
        result.add(ChatEntry(
          id: id,
          speaker: ChatSpeaker.values.byName(item['speaker'] as String),
          name: item['name'] as String,
          text: item['text'] as String,
        ));
      } else {
        throw const FormatException('Événement de partie inconnu.');
      }
    }
    return List.unmodifiable(result);
  }
}
