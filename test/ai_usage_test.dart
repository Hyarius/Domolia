import 'dart:convert';
import 'dart:io';

import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:domolia/ai/ai_usage.dart';
import 'package:domolia/chat/chat_exports.dart';
import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

AiExchange _exchange(String raw, {String stage = 'narrator_tool_round_0',
    int? toolCalls, int? prompt, int? completion}) {
  final recorder = AiExchangeRecorder();
  final value = recorder.begin(
    provider: 'fake', method: 'POST',
    url: 'https://example.invalid/chat/completions',
    requestBody: jsonEncode({'model': 'model',
        'max_tokens': 4096, 'messages': []}),
    secret: 'not-stored-secret', accept: 'application/json',
  );
  value.statusCode = 200;
  value.addRawResponse(utf8.encode(raw));
  value.stage = stage;
  value.complete(promptTokens: prompt, completionTokens: completion,
      toolCalls: toolCalls ?? 0);
  return value;
}

void main() {
  test('SSE tool round counts usage once and never treats budget as tokens', () {
    final exchange = _exchange(
        'data: {"choices":[{"delta":{"content":""}}]}\n'
        'data: {"usage":{"prompt_tokens":2405,"completion_tokens":79,'
        '"prompt_tokens_details":{"cached_tokens":500},'
        '"completion_tokens_details":{"reasoning_tokens":12},'
        '"cost":0.00098}}\n'
        'data: [DONE]\n', toolCalls: 2);
    final record = AiUsageRecord.fromExchange('party', exchange);
    expect(record.task, 'Narrateur');
    expect(record.inputTokens, 2405);
    expect(record.outputTokens, 79);
    expect(record.totalTokens, 2484);
    expect(record.cachedTokens, 500);
    expect(record.reasoningTokens, 12);
    expect(record.providerCostUsd, closeTo(0.00098, 1e-8));
    expect(record.toolCalls, 2);
    final routed = AiUsageRecord.fromExchange('party', _exchange(
        '{"usage":{"prompt_tokens":12,"completion_tokens":4},'
        '"ou":{"cost_usd":0.00042,"usage_estimated":true}}'));
    expect(routed.providerCostUsd, closeTo(0.00042, 1e-8));
    expect(routed.usageEstimated, true);
    expect(record.toJson().toString(), isNot(contains('not-stored-secret')));
  });

  test('Responses completed event meters Live Memory and diagnostics export', () {
    final exchange = _exchange(
      'data: {"type":"response.output_text.delta","delta":"{}"}\n'
      'data: {"type":"response.completed","response":{"usage":{'
      '"input_tokens":1280,"output_tokens":820,"total_tokens":2100,'
      '"input_tokens_details":{"cached_tokens":120},'
      '"output_tokens_details":{"reasoning_tokens":35}}}}\n',
      stage: 'live_memory',
    );
    exchange.playerEventId = 101;
    final record = AiUsageRecord.fromExchange('party', exchange);
    expect(record.task, 'Live Memory');
    expect(record.inputTokens, 1280);
    expect(record.outputTokens, 820);
    expect(record.cachedTokens, 120);
    expect(record.reasoningTokens, 35);
    expect(record.totalTokens, 2100);
    expect(record.usageSource, 'provider');
    expect(record.playerEventId, 101);
    expect(record.requestCharacters, greaterThan(0));
    expect(record.requestBytes, greaterThan(0));

    final exported = exportAiPipelineTrace(
      const [], const [],
      [StoredAiDiagnostic(
        id: 'exchange-101', sessionId: 'party',
        createdAtUtc: exchange.createdAtUtc,
        content: exchange.exportJson(),
      )],
    );
    final turns = exported['turns'] as List;
    final usage = (turns.single as Map<String, dynamic>)['usage']
        as Map<String, dynamic>;
    expect(usage['memoryRequests'], 1);
    expect(usage['totalTokensKnown'], 2100);
    expect(usage['requestsWithoutTokenUsage'], 0);
    expect(usage['providerReportedUsageRequests'], 1);
    expect(usage['cachedTokensKnown'], 120);
    expect(usage['reasoningTokensKnown'], 35);
    expect(usage['requestBytesKnown'], greaterThan(0));
  });

  test('Incomplete Responses SSE does not invent a zero-token bill', () {
    final exchange = _exchange(
      'data: {"type":"response.in_progress"}\n'
      'data: {"type":"response.failed","response":{"error":{}}}\n',
      stage: 'live_memory',
    );
    final record = AiUsageRecord.fromExchange('party', exchange);
    expect(record.inputTokens, isNull);
    expect(record.outputTokens, isNull);
    expect(record.totalTokens, isNull);
    expect(record.usageSource, 'unknown');
  });

  test('Non-stream extraction and unknown provider usage remain distinct', () {
    final nonStreaming = AiUsageRecord.fromExchange('party',
      _exchange('{"usage":{"prompt_tokens":185,"completion_tokens":29},'
        '"choices":[{"message":{"content":"{}"}}]}',
        stage: 'live_memory'));
    final missing = AiUsageRecord.fromExchange('party',
      _exchange('{"choices":[{"message":{"content":"{}"}}]}',
        stage: 'jsonifier'));
    expect(nonStreaming.task, 'Live Memory');
    expect(nonStreaming.totalTokens, 214);
    expect(nonStreaming.providerCostUsd, isNull);
    expect(missing.inputTokens, isNull);
    expect(missing.outputTokens, isNull);
    final totals = AiUsageSummary([nonStreaming, missing]).total;
    expect(totals.calls, 2);
    expect(totals.unknownTokens, 1);
    expect(totals.unknownCost, 2);
    expect(totals.measuredTokens, 214);
  });

  test('Usage is persistent, idempotent and independent of diagnostic purge',
      () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('usage-ledger-');
    final file = '${directory.path}/test.sqlite';
    final store = SqliteBookStore(
        factory: databaseFactoryFfi, databasePath: file);
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });
    await store.putBook(const BookDefinition(id: 'book', title: 'Benchmark'));
    await store.putSession(const BookSession(
        id: 'party', bookId: 'book', title: 'Test'));
    final first = AiUsageRecord.fromExchange('party',
      _exchange('{"usage":{"prompt_tokens":200,"completion_tokens":30}}',
          stage: 'jsonifier'));
    await store.putUsage(first);
    await store.putUsage(first); // Retried persistence is idempotent.
    await store.clearDiagnostics('party');
    await store.close();
    final reopened = SqliteBookStore(
        factory: databaseFactoryFfi, databasePath: file);
    addTearDown(reopened.close);
    final records = await reopened.loadUsage('party');
    expect(records, hasLength(1));
    expect(records.single.totalTokens, 230);
    await reopened.deleteSession('party');
    expect(await reopened.loadUsage('party'), isEmpty);
  });
}
