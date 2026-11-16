import 'chat_protocol.dart';

/// One validated narrative turn. Accepted NDJSON lines are visible immediately,
/// but remain transient until the controller commits the entire turn atomically.
class NarrativeStreamBuffer {
  ChatLineDecoder _decoder = ChatLineDecoder();
  final List<ChatOutputEvent> _accepted = [];

  /// Add a raw transport fragment. Malformed lines abort the entire turn;
  /// no partial result may be persisted or treated as a Live Memory source.
  void add(String fragment) {
    _accepted.addAll(_decoder.add(fragment));
  }

  /// Provisional events use the *future* committed IDs, preventing a visual
  /// replacement when the same widgets become durable after the transaction.
  List<ChatTimelineEvent> previewEvents(int firstId) {
    final result = <ChatTimelineEvent>[];
    var next = firstId;
    for (final entry in _accepted) {
      if (entry is ChatSceneChangeOutput) {
        result.add(ChatSceneChange(id: next++));
      } else if (entry is ChatLine) {
        result.add(ChatEntry(
          id: next++, speaker: entry.speaker, name: entry.name,
          text: entry.text, status: entry.status, inProgress: true,
        ));
      }
    }
    final current = _decoder.preview;
    if (current != null && current.text.isNotEmpty) {
      result.add(ChatEntry(
        id: next, speaker: current.speaker, name: current.name,
        text: current.text, status: current.status, inProgress: true,
      ));
    }
    return List.unmodifiable(result);
  }

  List<ChatOutputEvent> finish() {
    _accepted.addAll(_decoder.finish());
    if (_accepted.isEmpty ||
        !_accepted.any((e) => e is ChatLine) ||
        _accepted.last is ChatSceneChangeOutput) {
      throw const FormatException('Narration structurée incomplète.');
    }
    for (var i = 1; i < _accepted.length; i++) {
      if (_accepted[i] is ChatSceneChangeOutput &&
          _accepted[i - 1] is ChatSceneChangeOutput) {
        throw const FormatException('Séparateurs de scène consécutifs.');
      }
    }
    return List.unmodifiable(_accepted);
  }

  /// Compatibility representation for existing SQLite RAW snapshots and
  /// source-quote validation in Live Memory. Never includes JSON syntax.
  String storyText() => _accepted.map((entry) {
    if (entry is ChatSceneChangeOutput) return '[Changement de scène]';
    final line = entry as ChatLine;
    return line.speaker == ChatSpeaker.character
        ? '${line.name} : ${line.text}'
        : line.text;
  }).join('\n\n');

  void reset() {
    _decoder = ChatLineDecoder();
    _accepted.clear();
  }
}
