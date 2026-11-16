import 'dart:convert';
import 'ai_diagnostics.dart';

/// Only metering metadata is persisted: never prompts, RAW or secrets.
class AiUsageRecord {
  const AiUsageRecord({
    required this.id, required this.sessionId, required this.stage,
    required this.createdAtUtc, this.inputTokens, this.outputTokens,
    this.cachedTokens, this.reasoningTokens, this.providerCostUsd,
    this.toolCalls = 0, this.durationMs, this.failed = false,
    this.usageEstimated = false,
  });

  final String id, sessionId, stage;
  final DateTime createdAtUtc;
  final int? inputTokens, outputTokens, cachedTokens, reasoningTokens;
  final double? providerCostUsd;
  final int toolCalls;
  final int? durationMs;
  final bool failed;
  final bool usageEstimated;

  String get task {
    if (stage.startsWith('narrator_')) return 'Narrateur';
    if (stage == 'jsonifier') return 'JSONificateur';
    if (stage == 'live_memory') return 'Live Memory';
    if (stage == 'context_optimizer') return 'Optimiseur';
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
    'usageEstimated': usageEstimated,
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
  );

  /// Never infer billed tokens from max_tokens, string length or requests.
  factory AiUsageRecord.fromExchange(
      String sessionId, AiExchange exchange) {
    final data = exchange.toJson();
    final interpretation = data['interpretation'] as Map<String, dynamic>;
    final response = data['response'] as Map<String, dynamic>;
    final raw = response['rawBody'] as String? ?? '';
    Map<String, dynamic>? usage;
    Map<String, dynamic>? ou;
    void capture(dynamic decoded) {
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['usage'] is Map<String, dynamic>) {
        usage = decoded['usage'] as Map<String, dynamic>;
      }
      if (decoded['ou'] is Map<String, dynamic>) {
        ou = decoded['ou'] as Map<String, dynamic>;
      }
    }
    if (raw.trimLeft().startsWith('{')) {
      try { capture(jsonDecode(raw)); } catch (_) { /* Unavailable. */ }
    } else {
      for (final line in const LineSplitter().convert(raw)) {
        if (!line.startsWith('data:')) continue;
        try { capture(jsonDecode(line.substring(5).trim())); }
        catch (_) { /* [DONE] or partial chunk. */ }
      }
    }
    final input = usage?['prompt_tokens'];
    final output = usage?['completion_tokens'];
    final promptDetails = usage?['prompt_tokens_details'];
    final completionDetails = usage?['completion_tokens_details'];
    final cached = promptDetails is Map ? promptDetails['cached_tokens'] : null;
    final reasoning = completionDetails is Map
        ? completionDetails['reasoning_tokens'] : null;
    final cost = ou?['cost_usd'] ?? usage?['cost'];
    return AiUsageRecord(
      id: 'usage-${exchange.createdAtUtc.microsecondsSinceEpoch}',
      sessionId: sessionId, stage: exchange.stage ?? 'unknown',
      createdAtUtc: exchange.createdAtUtc,
      inputTokens: input is int ? input : interpretation['promptTokens'] as int?,
      outputTokens: output is int ? output
          : interpretation['completionTokens'] as int?,
      cachedTokens: cached is int ? cached : null,
      reasoningTokens: reasoning is int ? reasoning : null,
      providerCostUsd: cost is num && cost >= 0 ? cost.toDouble() : null,
      toolCalls: interpretation['toolCalls'] as int? ?? 0,
      durationMs: data['durationMs'] as int?,
      usageEstimated: ou?['usage_estimated'] == true,
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
  int get measuredTokens => records.fold(
      0, (sum, r) => sum + (r.totalTokens ?? 0));
  int get unknownTokens => records.where((r) => r.totalTokens == null).length;
  int get measuredInput => records.fold(
      0, (sum, r) => sum + (r.inputTokens ?? 0));
  int get measuredOutput => records.fold(
      0, (sum, r) => sum + (r.outputTokens ?? 0));
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
      'Optimiseur'];
}
