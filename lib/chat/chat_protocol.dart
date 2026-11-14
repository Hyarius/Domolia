import 'dart:convert';

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
    this.inProgress = false,
  }) : super(id);
  final ChatSpeaker speaker;
  final String name;
  final String text;
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
  const ChatLine({required this.speaker, required this.name, required this.text});
  final ChatSpeaker speaker;
  final String name;
  final String text;
}

/// NDJSON: a message or exactly {"type":"scene_change"}.
/// The narrator is an ordinary speaker. Old untyped messages remain valid.
/// No generated line can impersonate the player.
class ChatLineDecoder {
  String _pending = '';
  int _parsed = 0;

  List<ChatOutputEvent> add(String fragment) {
    _pending += fragment;
    if (_pending.length > 131072) {
      throw const FormatException('Réponse structurée trop longue.');
    }
    final lines = <ChatOutputEvent>[];
    while (true) {
      final end = _pending.indexOf('\n');
      if (end < 0) break;
      final raw = _pending.substring(0, end).trim();
      _pending = _pending.substring(end + 1);
      if (raw.isNotEmpty) lines.add(_parse(raw));
    }
    return lines;
  }

  List<ChatOutputEvent> finish() {
    final last = _pending.trim();
    _pending = '';
    return last.isEmpty ? const [] : [_parse(last)];
  }

  ChatOutputEvent _parse(String line) {
    if (line.length > 8192 || _parsed >= 20) {
      throw const FormatException('Nombre ou taille de messages IA excessifs.');
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      throw const FormatException('Le modèle n’a pas respecté le format des messages.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Événement IA structuré invalide.');
    }
    if (decoded['type'] == 'scene_change') {
      if (decoded.length != 1) {
        throw const FormatException(
          'Un changement de scène ne contient ni titre ni métadonnées.',
        );
      }
      _parsed++;
      return const ChatSceneChangeOutput();
    }
    if ((decoded['type'] != null && decoded['type'] != 'message') ||
        decoded['speaker'] is! String ||
        decoded['name'] is! String ||
        decoded['text'] is! String) {
      throw const FormatException('Message IA structuré invalide.');
    }
    final speaker = decoded['speaker'] as String;
    final text = (decoded['text'] as String).trim();
    final proposed = (decoded['name'] as String).trim();
    if (text.isEmpty || text.length > 6000 || proposed.isEmpty || proposed.length > 50) {
      throw const FormatException('Nom ou texte de message IA invalide.');
    }
    if (speaker == 'narrator') {
      _parsed++;
      return ChatLine(speaker: ChatSpeaker.narrator, name: 'Narrateur', text: text);
    }
    if (speaker == 'character' &&
        proposed.toLowerCase() != 'narrateur' &&
        proposed.toLowerCase() != 'vous' &&
        !proposed.contains(RegExp(r'[\r\n]'))) {
      _parsed++;
      return ChatLine(speaker: ChatSpeaker.character, name: proposed, text: text);
    }
    throw const FormatException('L’IA ne peut pas parler à la place du joueur.');
  }

  /// A partial scene boundary must not appear as a character bubble.
  bool get isPendingSceneChange =>
      RegExp(r'"type"\s*:\s*"scene_change"').hasMatch(_pending);

  /// Show the in-progress text, never JSON punctuation or control fields.
  ChatLine? get preview {
    if (isPendingSceneChange) return null;
    final speakerMatch =
        RegExp(r'"speaker"\s*:\s*"(narrator|character)"').firstMatch(_pending);
    final nameMatch =
        RegExp(r'"name"\s*:\s*"((?:\\.|[^"\\])*)"').firstMatch(_pending);
    if (speakerMatch == null || nameMatch == null) return null;
    final speaker = speakerMatch.group(1)!;
    String name;
    try {
      name = jsonDecode('"${nameMatch.group(1)!}"') as String;
    } catch (_) {
      return null;
    }
    if (name.trim().isEmpty || name.length > 50 ||
        (speaker == 'character' &&
            (name.toLowerCase() == 'vous' || name.toLowerCase() == 'narrateur'))) {
      return null;
    }
    final textMatch = RegExp(r'"text"\s*:\s*"').firstMatch(_pending);
    if (textMatch == null) return null;
    final remaining = _pending.substring(textMatch.end);
    final buffer = StringBuffer();
    var escaped = false;
    for (final char in remaining.split('')) {
      if (!escaped && char == '"') break;
      buffer.write(char);
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      }
    }
    final rawText = buffer.toString();
    String? text;
    for (var length = rawText.length;
        length >= 0 && length >= rawText.length - 8;
        length--) {
      try {
        text = jsonDecode('"${rawText.substring(0, length)}"') as String;
        break;
      } catch (_) {
        // Wait for the rest of an escaped JSON codepoint.
      }
    }
    if (text == null) return null;
    return ChatLine(
      speaker: speaker == 'narrator' ? ChatSpeaker.narrator : ChatSpeaker.character,
      name: speaker == 'narrator' ? 'Narrateur' : name.trim(),
      text: text,
    );
  }
}
