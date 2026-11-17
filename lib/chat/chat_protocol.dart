enum ChatSpeaker { player, narrator, character }


sealed class ChatTimelineEvent {
  const ChatTimelineEvent(this.id);
  final int id;
}

class ChatEntry extends ChatTimelineEvent {
  const ChatEntry({
    required int id,
    required this.speaker,
    required this.name,
    required this.text,
    this.status,
    this.inProgress = false,
  }) : super(id);
  final ChatSpeaker speaker;
  final String name;
  final String text;
  /// Optional short emotion, tone or visible attitude shown with the name.
  final String? status;
  final bool inProgress;
}

/// A titleless scene boundary, not a message or an avatar.
class ChatSceneChange extends ChatTimelineEvent {
  const ChatSceneChange({required int id}) : super(id);
}

sealed class ChatOutputEvent {
  const ChatOutputEvent();
}

class ChatSceneChangeOutput extends ChatOutputEvent {
  const ChatSceneChangeOutput();
}

class ChatLine extends ChatOutputEvent {
  const ChatLine({required this.speaker, required this.name, required this.text,
      this.status});
  final ChatSpeaker speaker;
  final String name;
  final String text;
  final String? status;
}

