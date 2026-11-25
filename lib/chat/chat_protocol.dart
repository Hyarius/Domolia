enum ChatSpeaker { player, narrator, character }

/// Book-level default, optionally overridden by a Party.
/// Automatic intentionally only proposes placeholders in PR33.
enum IllustrationMode { disabled, suggestions, automatic }

enum IllustrationIntentState { proposed, ignored, cancelled, queued }

/// A proposal is not narrative evidence or a generated image. Its ID is the
/// stable timeline event ID, and its origin is the player turn that produced it.
class ChatIllustrationIntent extends ChatTimelineEvent {
  const ChatIllustrationIntent({
    required int id,
    required this.playerEventId,
    required this.description,
    this.state = IllustrationIntentState.proposed,
  }) : super(id);

  final int playerEventId;
  final String description;
  final IllustrationIntentState state;
}

/// Only validated narrative is reusable as context or evidence. The original
/// RAW (including optional proposals) remains untouched in diagnostics.
String stripIllustrationBlocks(String raw) {
  final image = RegExp(r'^\[\s*IMAGE\s*\]', caseSensitive: false);
  final narrative = RegExp(
    r'^\[\s*(?:NARRATION|NARRATEUR|PERSONNAGE|CHARACTER|SCENE|SCÈNE|SCENE_CHANGE|CHANGEMENT_DE_SCENE)(?:\s*[:\]])',
    caseSensitive: false,
  );
  var inside = false;
  final kept = <String>[];
  for (final line in raw.split('\n')) {
    final trimmed = line.trimLeft();
    if (image.hasMatch(trimmed)) {
      inside = true;
      continue;
    }
    if (inside && (narrative.hasMatch(trimmed) || trimmed.startsWith('@') ||
        trimmed.trimRight() == '*' || trimmed.trimRight() == '---')) {
      inside = false;
    }
    if (!inside) kept.add(line);
  }
  return kept.join('\n').trim();
}


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

class ChatIllustrationOutput extends ChatOutputEvent {
  const ChatIllustrationOutput(this.description);
  final String description;
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

