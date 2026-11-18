import 'dart:convert';

import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:domolia/logging/app_logger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Every AI exchange emits redacted start and finish app-log records', () async {
    final logger = AppLogger.current;
    await logger.clear();
    final recorder = AiExchangeRecorder();
    final exchange = recorder.begin(
      provider: 'openai-compatible',
      method: 'POST',
      url: 'https://example.test/v1/chat/completions',
      requestBody: '{"prompt":"a private narrative","api_key":"sk-private-secret"}',
      secret: 'sk-private-secret',
      accept: 'application/json',
    );
    exchange.stage = 'image_direction';
    exchange.playerEventId = 42;
    exchange.statusCode = 200;
    exchange.addRawResponse(utf8.encode('{"response":"private answer"}'));
    exchange.complete(promptTokens: 120, completionTokens: 32);
    // Enrichment must not count another billed request.
    exchange.complete(promptTokens: 120, completionTokens: 32);

    await logger.flush();
    final entries = (await logger.entries())
        .where((entry) => entry.component == 'ai.http').toList();
    expect(entries, hasLength(2));
    expect(entries[0].message, 'Appel IA lancé');
    expect(entries[1].message, 'Appel IA terminé');
    expect(entries[1].details['stage'], 'image_direction');
    expect(entries[1].details['playerEventId'], 42);
    expect(entries[1].details['promptTokens'], 120);
    expect(entries[1].details['completionTokens'], 32);
    expect(entries[0].details['exchangeId'], entries[1].details['exchangeId']);

    final snapshot = await logger.snapshot();
    expect(snapshot, isNot(contains('sk-private-secret')));
    expect(snapshot, isNot(contains('private narrative')));
    expect(snapshot, isNot(contains('private answer')));
    expect(exchange.exportJson(), contains('[REDACTED]'));
  });

  test('Failed AI calls are distinguished without retaining error messages', () async {
    final logger = AppLogger.current;
    await logger.clear();
    final exchange = AiExchangeRecorder().begin(
      provider: 'openuncensored',
      method: 'POST',
      url: 'https://example.test/v1/images/generations',
      requestBody: '{"prompt":"personal scene"}',
      secret: 'ou-test-token',
      accept: 'application/json',
    )..stage = 'image_generation';
    exchange.statusCode = 503;
    exchange.complete(error: 'Sensitive upstream failure');
    await logger.flush();
    final events = (await logger.entries())
        .where((entry) => entry.component == 'ai.http').toList();
    expect(events, hasLength(2));
    expect(events.last.level, AppLogLevel.warning);
    expect(events.last.details['statusCode'], 503);
    expect(await logger.snapshot(), isNot(contains('Sensitive upstream failure')));
  });
}
