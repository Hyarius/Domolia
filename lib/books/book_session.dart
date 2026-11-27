import 'dart:convert';
import 'dart:math';

import '../chat/chat_protocol.dart';
import '../ai/ai_task_generation.dart';

/// Personal and never included in a BookDefinition export.
class BookSession {
  const BookSession({
    required this.id,
    required this.bookId,
    required this.title,
    this.timeline = const [],
    this.aiProfileId,
    this.formatterProfileId,
    this.optimizerProfileId,
    this.memoryProfileId,
    this.memoryEnabled = false,
    this.toolCallingEnabled = false,
    this.illustrationModeOverride,
    this.generationOverrides = const {},
    this.optimizedLore,
    this.optimizedLoreHash,
    this.updatedAtUtc,
  });

  final String id;
  final String bookId;
  final String title;
  final List<ChatTimelineEvent> timeline;
  /// Overrides the parent Book's default AI profile for this conversation.
  final String? aiProfileId;
  /// Explicit per-Party overrides; null inherits the application task profile.
  final String? formatterProfileId;
  final String? optimizerProfileId;
  final String? memoryProfileId;
  final bool memoryEnabled;
  /// Per-Party opt-out; never overrides an incompatible profile.
  final bool toolCallingEnabled;
  /// Null inherits the Book setting, including changes made after creation.
  final IllustrationMode? illustrationModeOverride;
  /// Task-specific output/reasoning overrides; never part of a shared Book.
  final Map<AiNarrativeTask, AiTaskGenerationOverride> generationOverrides;
  /// Generated summary only. The canonical Lore remains in BookDefinition.
  /// Empty string means an optimization was attempted and rejected.
  final String? optimizedLore;
  final String? optimizedLoreHash;
  final DateTime? updatedAtUtc;

  static String freshId() =>
      'session-${DateTime.now().microsecondsSinceEpoch}-'
      '${Random.secure().nextInt(0x7fffffff)}';

  BookSession copyWith({
    String? title,
    List<ChatTimelineEvent>? timeline,
    String? aiProfileId,
    bool clearAiProfile = false,
    String? formatterProfileId,
    bool clearFormatterProfile = false,
    String? optimizerProfileId,
    bool clearOptimizerProfile = false,
    String? memoryProfileId,
    bool clearMemoryProfile = false,
    bool? memoryEnabled,
    bool? toolCallingEnabled,
    IllustrationMode? illustrationModeOverride,
    bool clearIllustrationMode = false,
    Map<AiNarrativeTask, AiTaskGenerationOverride>? generationOverrides,
    String? optimizedLore,
    String? optimizedLoreHash,
    DateTime? updatedAtUtc,
  }) => BookSession(
        id: id,
        bookId: bookId,
        title: title ?? this.title,
        timeline: timeline ?? this.timeline,
        aiProfileId: clearAiProfile ? null : aiProfileId ?? this.aiProfileId,
        formatterProfileId: clearFormatterProfile
            ? null : formatterProfileId ?? this.formatterProfileId,
        optimizerProfileId: clearOptimizerProfile
            ? null : optimizerProfileId ?? this.optimizerProfileId,
        memoryProfileId: clearMemoryProfile
            ? null : memoryProfileId ?? this.memoryProfileId,
        memoryEnabled: memoryEnabled ?? this.memoryEnabled,
        toolCallingEnabled: toolCallingEnabled ?? this.toolCallingEnabled,
        illustrationModeOverride: clearIllustrationMode
            ? null : illustrationModeOverride ?? this.illustrationModeOverride,
        generationOverrides: generationOverrides ?? this.generationOverrides,
        optimizedLore: optimizedLore ?? this.optimizedLore,
        optimizedLoreHash: optimizedLoreHash ?? this.optimizedLoreHash,
        updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      );

  String encodeTimeline() => jsonEncode([
        for (final event in timeline)
          if (event is ChatSceneChange)
            {'id': event.id, 'type': 'scene_change'}
          else if (event is ChatIllustrationIntent)
            {
              'id': event.id,
              'type': 'image_intent',
              'playerEventId': event.playerEventId,
              'description': event.description,
              'state': event.state.name,
            }
          else if (event is ChatEntry)
            {
              'id': event.id,
              'type': 'message',
              'speaker': event.speaker.name,
              'name': event.name,
              'text': event.text,
              if (event.status != null) 'status': event.status,
            },
      ]);

  static List<ChatTimelineEvent> decodeTimeline(String raw) {
    final parsed = jsonDecode(raw);
    if (parsed is! List || parsed.length > 50000) {
      throw const FormatException('Historique de partie invalide.');
    }
    final result = <ChatTimelineEvent>[];
    final seenIds = <int>{};
    for (final item in parsed) {
      if (item is! Map<String, dynamic> || item['id'] is! int) {
        throw const FormatException('Événement de partie invalide.');
      }
      final id = item['id'] as int;
      if (id < 0 || !seenIds.add(id)) {
        throw const FormatException('Identifiant d’événement invalide ou dupliqué.');
      }
      if (item['type'] == 'scene_change' && item.length == 2) {
        result.add(ChatSceneChange(id: id));
      } else if (item['type'] == 'image_intent' &&
          item['playerEventId'] is int &&
          (item['playerEventId'] as int) >= 0 &&
          item['description'] is String &&
          (item['description'] as String).trim().isNotEmpty &&
          (item['description'] as String).length <= ChatIllustrationIntent.maxDescriptionLength &&
          item['state'] is String &&
          IllustrationIntentState.values.any((v) => v.name == item['state']) &&
          item.length == 5) {
        result.add(ChatIllustrationIntent(
          id: id,
          playerEventId: item['playerEventId'] as int,
          description: item['description'] as String,
          state: IllustrationIntentState.values.byName(item['state'] as String),
        ));
      } else if (item['type'] == 'message' &&
          item['speaker'] is String &&
          item['name'] is String && item['text'] is String &&
          (item['status'] == null || item['status'] is String &&
              (item['status'] as String).length <= 65) &&
          ChatSpeaker.values.any((s) => s.name == item['speaker'])) {
        result.add(ChatEntry(
          id: id,
          speaker: ChatSpeaker.values.byName(item['speaker'] as String),
          name: item['name'] as String,
          text: item['text'] as String,
          status: item['status'] as String?,
        ));
      } else {
        throw const FormatException('Événement de partie inconnu.');
      }
    }
    return List.unmodifiable(result);
  }
}
