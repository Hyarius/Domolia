import 'dart:convert';
import 'dart:io';

import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:domolia/ai/ai_usage.dart';
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
    expect(record.toJson().toString(), isNot(contains('not-stored-secret')));
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
