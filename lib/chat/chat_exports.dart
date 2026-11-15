import '../ai/ai_diagnostics.dart';
import 'chat_protocol.dart';
import 'raw_generation.dart';

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
    'bookTitle': ?bookTitle,
    'sessionTitle': ?sessionTitle,
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


/// Reconstruct an inspectable local pipeline trace without re-running the IA.
///
/// Stored exchanges already contain redacted HTTP requests and raw provider
/// responses, including errors. A persisted RAW survives even when diagnostics
/// were disabled, pruned, or when the JSONifier failed.
Map<String, dynamic> exportAiPipelineTrace(
  List<ChatTimelineEvent> timeline,
  List<RawGeneration> rawGenerations,
  List<StoredAiDiagnostic> diagnostics, {
  AiExchange? latestExchange,
  String? bookTitle,
  String? sessionTitle,
}) {
  final turns = <int, Map<String, dynamic>>{};
  Map<String, dynamic> turn(int id) => turns.putIfAbsent(id, () => {
    'playerEventId': id,
    'playerMessage': null,
    'raw': null,
    'phases': <Map<String, dynamic>>[],
  });
  for (final event in timeline) {
    if (event is ChatEntry && event.speaker == ChatSpeaker.player) {
      turn(event.id)['playerMessage'] = event.text;
    }
  }
  for (final raw in rawGenerations) {
    turn(raw.playerEventId)['raw'] = {
      'text': raw.rawText,
      'status': raw.isStructured ? 'jsonified' : 'pending_jsonification',
      'firstEventId': raw.firstEventId,
      'lastEventId': raw.lastEventId,
    };
  }

  // The active in-memory exchange may not yet have been flushed to SQLite.
  // Deduplicate it using the stable timestamp and origin of the HTTP call.
  final exchanges = <Map<String, dynamic>>[];
  var invalidDiagnostics = 0;
  for (final diagnostic in diagnostics) {
    try {
      exchanges.add(diagnostic.data);
    } catch (_) {
      invalidDiagnostics++;
    }
  }
  if (latestExchange != null) {
    final data = latestExchange.toJson();
    final isStored = exchanges.any((saved) =>
        saved['recordedAtUtc'] == data['recordedAtUtc'] &&
        saved['stage'] == data['stage'] &&
        saved['playerEventId'] == data['playerEventId']);
    if (!isStored) exchanges.add(data);
  }
  exchanges.sort((a, b) =>
      (a['recordedAtUtc']?.toString() ?? '')
          .compareTo(b['recordedAtUtc']?.toString() ?? ''));

  final unassigned = <Map<String, dynamic>>[];
  for (final exchange in exchanges) {
    final id = exchange['playerEventId'];
    if (id is int) {
      (turn(id)['phases'] as List<Map<String, dynamic>>).add(exchange);
    } else {
      unassigned.add(exchange);
    }
  }

  return {
    'format': 'domolia-ai-pipeline-trace-v1',
    'exportedAtUtc': DateTime.now().toUtc().toIso8601String(),
    if (bookTitle != null) 'bookTitle': bookTitle,
    if (sessionTitle != null) 'sessionTitle': sessionTitle,
    'diagnosticsRetentionNotice': 'Seuls les échanges encore conservés '
        'localement sont disponibles. Les échanges désactivés, purgés, '
        'écrasés par la limite de conservation ou jamais capturés '
        'ne peuvent pas être reconstitués. Les RAW persistants sont '
        'exportés indépendamment des diagnostics HTTP.',
    'privacyNotice': 'Les identifiants de connexion sont masqués dans '
        'les échanges capturés, mais les messages, le Lore et les '
        'réponses peuvent contenir des données privées.',
    'capturedExchangeCount': exchanges.length,
    'unreadableDiagnosticCount': invalidDiagnostics,
    'turns': turns.values.toList(growable: false),
    'unassignedExchanges': unassigned,
  };
}
