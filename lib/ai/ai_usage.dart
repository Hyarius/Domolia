import 'dart:convert';
import 'ai_diagnostics.dart';

/// Only metering metadata is persisted: never prompts, RAW or secrets.
class AiUsageRecord {
  const AiUsageRecord({
    required this.id, required this.sessionId, required this.stage,
    required this.createdAtUtc, this.inputTokens, this.outputTokens,
    this.cachedTokens, this.reasoningTokens, this.providerCostUsd,
    this.toolCalls = 0, this.durationMs, this.failed = false,
    this.usageEstimated = false, this.usageSource = 'unknown',
    this.requestCharacters, this.requestBytes, this.playerEventId,
  });

  final String id, sessionId, stage;
  final DateTime createdAtUtc;
  final int? inputTokens, outputTokens, cachedTokens, reasoningTokens;
  final double? providerCostUsd;
  final int toolCalls;
  final int? durationMs;
  final bool failed;
  final bool usageEstimated;
  /// Provenance of token counts: provider, diagnostic fallback, or unknown.
  final String usageSource;
  /// Outgoing JSON payload only, never persisted prompt text.
  final int? requestCharacters, requestBytes, playerEventId;

  String get task {
    if (stage.startsWith('narrator_')) return 'Narrateur';
    if (stage == 'jsonifier') return 'JSONificateur';
    if (stage == 'live_memory') return 'Live Memory';
    if (stage == 'context_optimizer') return 'Optimiseur';
    if (stage == 'image_generation') return 'Illustrations';
    if (stage == 'image_direction') return 'Mise en scène';
    return 'Autres';
  }

  int? get totalTokens => inputTokens == null || outputTokens == null
      ? null : inputTokens! + outputTokens!;

  Map<String, Object?> toJson() => {
    'id': id, 'sessionId': sessionId, 'stage': stage,
    'createdAtUtc': createdAtUtc.toIso8601String(),
    'inputTokens': inputTokens, 'outputTokens': outputTokens,
    'cachedTokens': cachedTokens, 'reasoningTokens': reasoningTokens,
    'providerCostUsd': providerCostUsd, 'toolCalls': toolCalls,
    'durationMs': durationMs, 'failed': failed,
    'usageEstimated': usageEstimated, 'usageSource': usageSource,
    'requestCharacters': requestCharacters, 'requestBytes': requestBytes,
    'playerEventId': playerEventId,
  };

  factory AiUsageRecord.fromJson(Map<String, dynamic> value) => AiUsageRecord(
    id: value['id'] as String,
    sessionId: value['sessionId'] as String,
    stage: value['stage'] as String,
    createdAtUtc: DateTime.parse(value['createdAtUtc'] as String),
    inputTokens: value['inputTokens'] as int?,
    outputTokens: value['outputTokens'] as int?,
    cachedTokens: value['cachedTokens'] as int?,
    reasoningTokens: value['reasoningTokens'] as int?,
    providerCostUsd: (value['providerCostUsd'] as num?)?.toDouble(),
    toolCalls: value['toolCalls'] as int? ?? 0,
    durationMs: value['durationMs'] as int?,
    failed: value['failed'] as bool? ?? false,
    usageEstimated: value['usageEstimated'] as bool? ?? false,
    usageSource: value['usageSource'] as String? ?? 'unknown',
    requestCharacters: value['requestCharacters'] as int?,
    requestBytes: value['requestBytes'] as int?,
    playerEventId: value['playerEventId'] as int?,
  );

  /// Never infer billed tokens from max_tokens, string length or requests.
  factory AiUsageRecord.fromExchange(String sessionId, AiExchange exchange) =>
      AiUsageRecord.fromDiagnosticJson(sessionId, exchange.toJson());

  /// Parses redacted diagnostics as well as live exchanges. Responses SSE
  /// reports usage in response.completed.response.usage; Chat Completions
  /// reports it in usage. Missing fields remain unknown, never zero.
  factory AiUsageRecord.fromDiagnosticJson(
      String sessionId, Map<String, dynamic> data) {
    final interpretation = data['interpretation'] is Map<String, dynamic>
        ? data['interpretation'] as Map<String, dynamic>
        : <String, dynamic>{};
    final response = data['response'] is Map<String, dynamic>
        ? data['response'] as Map<String, dynamic>
        : <String, dynamic>{};
    final raw = response['rawBody'] is String
        ? response['rawBody'] as String : '';
    Map<String, dynamic>? usage;
    Map<String, dynamic>? ou;
    void capture(dynamic decoded) {
      if (decoded is! Map<String, dynamic>) return;
      final direct = decoded['usage'];
      final nestedResponse = decoded['response'];
      final nested = nestedResponse is Map<String, dynamic>
          ? nestedResponse['usage'] : null;
      if (direct is Map<String, dynamic>) usage = direct;
      if (nested is Map<String, dynamic>) usage = nested;
      if (decoded['ou'] is Map<String, dynamic>) {
        ou = decoded['ou'] as Map<String, dynamic>;
      }
    }
    if (raw.trimLeft().startsWith('{')) {
      try { capture(jsonDecode(raw)); } catch (_) { /* Unavailable. */ }
    } else {
      for (final line in const LineSplitter().convert(raw)) {
        if (!line.startsWith('data:') ||
            (!line.contains('"usage"') && !line.contains('"ou"'))) {
          continue;
        }
        try { capture(jsonDecode(line.substring(5).trim())); }
        catch (_) { /* Truncated or malformed stream event. */ }
      }
    }

    final input = usage?['prompt_tokens'] ?? usage?['input_tokens'];
    final output = usage?['completion_tokens'] ?? usage?['output_tokens'];
    final promptDetails = usage?['prompt_tokens_details'] ??
        usage?['input_tokens_details'];
    final completionDetails = usage?['completion_tokens_details'] ??
        usage?['output_tokens_details'];
    final cached = promptDetails is Map
        ? promptDetails['cached_tokens'] : null;
    final reasoning = completionDetails is Map
        ? completionDetails['reasoning_tokens'] : null;
    final cost = ou?['cost_usd'] ?? usage?['cost'];
    final promptFallback = interpretation['promptTokens'];
    final completionFallback = interpretation['completionTokens'];
    final providerUsage = input is int && output is int;
    final diagnosticUsage = promptFallback is int &&
        completionFallback is int;
    final request = data['request'];
    final requestBody = request is Map ? request['rawBody'] : null;
    final timestamp = DateTime.tryParse(
        data['recordedAtUtc']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return AiUsageRecord(
      id: 'usage-${timestamp.microsecondsSinceEpoch}',
      sessionId: sessionId, stage: data['stage']?.toString() ?? 'unknown',
      createdAtUtc: timestamp,
      inputTokens: input is int ? input :
          promptFallback is int ? promptFallback : null,
      outputTokens: output is int ? output :
          completionFallback is int ? completionFallback : null,
      cachedTokens: cached is int ? cached : null,
      reasoningTokens: reasoning is int ? reasoning : null,
      providerCostUsd: cost is num && cost >= 0 ? cost.toDouble() : null,
      toolCalls: interpretation['toolCalls'] as int? ?? 0,
      durationMs: data['durationMs'] as int?,
      usageEstimated: ou?['usage_estimated'] == true,
      usageSource: providerUsage ? 'provider'
          : diagnosticUsage ? 'diagnostic' : 'unknown',
      requestCharacters: requestBody is String ? requestBody.length : null,
      requestBytes: requestBody is String
          ? utf8.encode(requestBody).length : null,
      playerEventId: data['playerEventId'] as int?,
      failed: interpretation['error'] != null ||
          (response['statusCode'] is int && response['statusCode'] != 200),
    );
  }

}

abstract interface class AiUsageStore {
  Future<void> putUsage(AiUsageRecord record);
  Future<List<AiUsageRecord>> loadUsage(String sessionId);
}

class AiUsageTotals {
  const AiUsageTotals(this.records);
  final List<AiUsageRecord> records;
  int get calls => records.length;
  int get toolCalls => records.fold(0, (sum, r) => sum + r.toolCalls);
  int get errors => records.where((r) => r.failed).length;
  int get estimatedUsage => records.where((r) => r.usageEstimated).length;
  int get providerReportedUsage => records.where((r) => r.usageSource == 'provider').length;
  int get requestCharactersKnown => records.fold(0, (sum, r) => sum + (r.requestCharacters ?? 0));
  int get requestBytesKnown => records.fold(0, (sum, r) => sum + (r.requestBytes ?? 0));
  int get measuredTokens => records.fold(
      0, (sum, r) => sum + (r.totalTokens ?? 0));
  int get unknownTokens => records.where((r) => r.totalTokens == null).length;
  int get measuredInput => records.fold(
      0, (sum, r) => sum + (r.inputTokens ?? 0));
  int get measuredOutput => records.fold(
      0, (sum, r) => sum + (r.outputTokens ?? 0));
  int get cachedTokensKnown => records.fold(
      0, (sum, r) => sum + (r.cachedTokens ?? 0));
  int get reasoningTokensKnown => records.fold(
      0, (sum, r) => sum + (r.reasoningTokens ?? 0));
  double get knownCostUsd => records.fold(
      0.0, (sum, r) => sum + (r.providerCostUsd ?? 0.0));
  int get unknownCost => records.where(
      (r) => r.providerCostUsd == null).length;
}

class AiUsageSummary {
  const AiUsageSummary(this.records);
  final List<AiUsageRecord> records;
  AiUsageTotals get total => AiUsageTotals(records);
  AiUsageTotals forTask(String task) =>
      AiUsageTotals(records.where((r) => r.task == task).toList());
  static const tasks = ['Narrateur', 'JSONificateur', 'Live Memory',
      'Optimiseur', 'Mise en scène', 'Illustrations'];
}
