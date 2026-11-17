import 'chat_protocol.dart';

/// An original literary reply. Its source is never reconstructed from UI bubbles.
/// IDs refer to player messages, not to generated timeline event positions.
class RawGeneration {
  const RawGeneration({
    required this.playerEventId,
    required this.rawText,
    this.compactText,
    this.firstEventId,
    this.lastEventId,
  });

  final int playerEventId;
  final String rawText;
  /// Short, source-derived context for later narrator calls, never UI text.
  final String? compactText;
  final int? firstEventId;
  final int? lastEventId;

  bool get isStructured => firstEventId != null && lastEventId != null;

  /// Human-readable, source-faithful content used for Live Memory quotes.
  /// Historical records contain literary RAW already; new structured turns
  /// preserve the original NDJSON in [rawText] for diagnostics and auditing.
  String get validatedNarrative {
    if (!isStructured || !rawText.trimLeft().startsWith('{"type":')) {
      return rawText;
    }
    try {
      final parser = ChatLineDecoder();
      final events = <ChatOutputEvent>[
        ...parser.add(rawText),
        ...parser.finish(),
      ];
      if (!events.any((e) => e is ChatLine)) return rawText;
      return events.whereType<ChatLine>().map((line) {
        if (line.speaker == ChatSpeaker.character) {
          return '${line.name} : ${line.text}';
        }
        return line.text;
      }).join('\n');
    } on FormatException {
      // Malformed or historical text is never silently discarded.
      return rawText;
    }
  }

  RawGeneration structured(int first, int last, {String? compactText}) => RawGeneration(
    playerEventId: playerEventId,
    rawText: rawText,
    compactText: compactText,
    firstEventId: first,
    lastEventId: last,
  );
}
