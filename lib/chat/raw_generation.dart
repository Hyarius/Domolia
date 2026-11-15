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

  RawGeneration structured(int first, int last, {String? compactText}) => RawGeneration(
    playerEventId: playerEventId,
    rawText: rawText,
    compactText: compactText,
    firstEventId: first,
    lastEventId: last,
  );
}
