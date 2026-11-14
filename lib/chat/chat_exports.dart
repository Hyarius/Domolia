import 'chat_protocol.dart';

enum ChatExportScope { complete, lastScenes, lastMessages }

/// Export committed events only. Streaming previews and unsent drafts are
/// excluded because they are not part of the saved conversation.
Map<String, dynamic> exportConversation(
  List<ChatTimelineEvent> timeline, {
  ChatExportScope scope = ChatExportScope.complete,
  int count = 1,
  String? bookTitle,
  String? sessionTitle,
}) {
  if (count < 1 || count > 50000) {
    throw RangeError.range(count, 1, 50000, 'count');
  }

  var first = 0;
  switch (scope) {
    case ChatExportScope.complete:
      break;
    case ChatExportScope.lastScenes:
      var remaining = count;
      for (var i = timeline.length - 1; i >= 0; i--) {
        if (timeline[i] is ChatSceneChange) {
          if (remaining == 1) {
            first = i + 1;
            break;
          }
          remaining--;
        }
      }
    case ChatExportScope.lastMessages:
      var remaining = count;
      for (var i = timeline.length - 1; i >= 0; i--) {
        if (timeline[i] is ChatEntry) {
          remaining--;
          if (remaining == 0) {
            first = i;
            break;
          }
        }
      }
  }

  final selected = timeline.skip(first).toList(growable: false);
  return {
    'format': 'domolia-conversation-v1',
    'exportedAtUtc': DateTime.now().toUtc().toIso8601String(),
    if (bookTitle != null) 'bookTitle': bookTitle,
    if (sessionTitle != null) 'sessionTitle': sessionTitle,
    'selection': {
      'scope': scope.name,
      if (scope != ChatExportScope.complete) 'count': count,
    },
    'totalEventsInConversation': timeline.length,
    'exportedEvents': selected.length,
    'events': [
      for (final event in selected)
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
    ],
  };
}
