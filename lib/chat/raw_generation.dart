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

  /// Narrative content captured when the turn was validated. Never reparse
  /// the model's original output: old persisted formats stay opaque.
  String get validatedNarrative => isStructured &&
          compactText != null && compactText!.trim().isNotEmpty
      ? compactText!
      : stripIllustrationBlocks(rawText);

  RawGeneration structured(int first, int last, {String? compactText}) => RawGeneration(
    playerEventId: playerEventId,
    rawText: rawText,
    compactText: compactText,
    firstEventId: first,
    lastEventId: last,
  );
}
