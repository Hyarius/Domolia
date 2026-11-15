import 'dart:convert';

import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:domolia/chat/chat_exports.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/raw_generation.dart';
import 'package:flutter_test/flutter_test.dart';

const timeline = <ChatTimelineEvent>[
  ChatEntry(id: 0, speaker: ChatSpeaker.narrator,
      name: 'Narrateur', text: 'Avant la première scène'),
  ChatSceneChange(id: 1),
  ChatEntry(id: 2, speaker: ChatSpeaker.player,
      name: 'Vous', text: 'Je pars'),
  ChatEntry(id: 3, speaker: ChatSpeaker.character,
      name: 'Lina', text: 'Je te suis'),
  ChatSceneChange(id: 4),
  ChatEntry(id: 5, speaker: ChatSpeaker.narrator,
      name: 'Narrateur', text: 'Arrivée'),
  ChatEntry(id: 6, speaker: ChatSpeaker.player,
      name: 'Vous', text: 'Je regarde'),
];

List<int> eventIds(Map<String, dynamic> export) =>
    (export['events'] as List)
        .map((event) => (event as Map<String, dynamic>)['id'] as int)
        .toList();

void main() {
  test('Complete transcript includes all messages and scene boundaries', () {
    final export = exportConversation(timeline, bookTitle: 'Livre A',
        sessionTitle: 'Partie 1');
    expect(eventIds(export), [0, 1, 2, 3, 4, 5, 6]);
    expect(export['bookTitle'], 'Livre A');
    expect(export['sessionTitle'], 'Partie 1');
    expect(export['exportedEvents'], 7);
    expect((export['events'] as List)[1]['type'], 'scene_change');
    expect(jsonDecode(jsonEncode(export)), isA<Map<String, dynamic>>());
  });

  test('Last X scenes are counted from scene_change boundaries', () {
    expect(eventIds(exportConversation(timeline,
      scope: ChatExportScope.lastScenes, count: 1)), [5, 6]);
    expect(eventIds(exportConversation(timeline,
      scope: ChatExportScope.lastScenes, count: 2)), [2, 3, 4, 5, 6]);
    expect(eventIds(exportConversation(timeline,
      scope: ChatExportScope.lastScenes, count: 3)), [0, 1, 2, 3, 4, 5, 6]);
    expect(eventIds(exportConversation(const <ChatTimelineEvent>[],
      scope: ChatExportScope.lastScenes, count: 1)), isEmpty);
  });

  test('Last X messages ignore scene separators for the count', () {
    expect(eventIds(exportConversation(timeline,
      scope: ChatExportScope.lastMessages, count: 1)), [6]);
    expect(eventIds(exportConversation(timeline,
      scope: ChatExportScope.lastMessages, count: 3)), [3, 4, 5, 6]);
    expect(eventIds(exportConversation(timeline,
      scope: ChatExportScope.lastMessages, count: 10)), [0, 1, 2, 3, 4, 5, 6]);
    expect(() => exportConversation(timeline,
      scope: ChatExportScope.lastMessages, count: 0), throwsRangeError);
  });

  test('AI exchange exports actual JSON and raw SSE with credentials redacted', () {
    final recorder = AiExchangeRecorder();
    final exchange = recorder.begin(
      provider: 'openai-compatible',
      method: 'POST',
      url: 'https://example.invalid/v1/chat/completions',
      requestBody: '{"model":"test","messages":[{"role":"user","content":"hi"}]}',
      secret: 'private-token',
      accept: 'text/event-stream',
    );
    exchange.statusCode = 200;
    final raw = 'data: {"delta":"Bonjour"}\r\n\r\n'
        'data: {"error":"Bearer private-token"}\n\n';
    exchange.addRawResponse(utf8.encode(raw));
    final export = exchange.toJson();
    expect(export['format'], 'domolia-ai-exchange-v1');
    expect((export['request'] as Map)['body']['model'], 'test');
    expect((export['request'] as Map)['headers']['Authorization'],
        'Bearer [REDACTED]');
    expect((export['response'] as Map)['rawBody'],
        'data: {"delta":"Bonjour"}\r\n\r\n'
        'data: {"error":"Bearer [REDACTED]"}\n\n');
    expect(exchange.exportJson(), isNot(contains('private-token')));
  });

  test('Raw AI response capture is bounded without dropping request metadata', () {
    final recorder = AiExchangeRecorder();
    final exchange = recorder.begin(
      provider: 'chatgpt-responses', method: 'POST',
      url: 'https://api.openai.com/v1/responses',
      requestBody: '{"model":"test","input":[]}',
      secret: 'oauth-token', accept: 'text/event-stream',
    );
    exchange.addRawResponse(List<int>.filled(
        AiExchange.maxRawResponseBytes + 10, 65));
    expect(exchange.truncated, true);
    expect((exchange.toJson()['response'] as Map)['rawBody'].length,
        AiExchange.maxRawResponseBytes);
  });

  test('Pipeline export groups narrator and JSONifier attempts and preserves RAW', () {
    final recorder = AiExchangeRecorder();
    final narrator = recorder.begin(
      provider: 'openai-compatible', method: 'POST',
      url: 'https://example.invalid/v1/chat/completions',
      requestBody: '{"model":"m1","messages":[{"role":"user","content":"Bonjour"}]}',
      secret: 'secret-ia-token', accept: 'text/event-stream',
    );
    narrator.stage = 'narrator_raw';
    narrator.playerEventId = 2;
    narrator.statusCode = 200;
    narrator.addRawResponse(utf8.encode('data: RAW narratif\\n\\n'));
    narrator.complete(promptTokens: 300, completionTokens: 80);

    final jsonifier = recorder.begin(
      provider: 'openai-compatible', method: 'POST',
      url: 'https://example.invalid/v1/chat/completions',
      requestBody: '{"model":"m1","messages":[{"role":"user","content":"RAW narratif"}]}',
      secret: 'secret-ia-token', accept: 'text/event-stream',
    );
    jsonifier.stage = 'jsonifier';
    jsonifier.playerEventId = 2;
    jsonifier.statusCode = 200;
    jsonifier.addRawResponse(utf8.encode('data: {"error":"Bearer secret-ia-token"}\\n\\n'));
    jsonifier.complete(error: 'JSONification : enveloppe invalide');

    final trace = exportAiPipelineTrace(timeline, const [
      RawGeneration(playerEventId: 2, rawText: 'RAW narratif'),
    ], [
      StoredAiDiagnostic(id: 'n1', sessionId: 'session-1',
        createdAtUtc: DateTime.utc(2026, 11, 15), content: narrator.exportJson()),
      StoredAiDiagnostic(id: 'f1', sessionId: 'session-1',
        createdAtUtc: DateTime.utc(2026, 11, 15), content: jsonifier.exportJson()),
    ], latestExchange: jsonifier, bookTitle: 'Skogheim',
      sessionTitle: 'Partie 1');
    final turns = trace['turns'] as List;
    final first = turns.singleWhere((v) => v['playerEventId'] == 2);
    expect(first['playerMessage'], 'Je pars');
    expect(first['raw']['text'], 'RAW narratif');
    expect(first['raw']['status'], 'pending_jsonification');
    final stages = first['phases'] as List;
    expect(stages.map((s) => s['stage']), ['narrator_raw', 'jsonifier']);
    expect(stages[0]['request']['body']['model'], 'm1');
    expect(stages[0]['response']['rawBody'], contains('RAW narratif'));
    expect(stages[1]['interpretation']['error'],
      'JSONification : enveloppe invalide');
    expect(trace['capturedExchangeCount'], 2);
    final jsonText = jsonEncode(trace);
    expect(jsonText, isNot(contains('secret-ia-token')));
    expect(jsonText, contains('Bearer [REDACTED]'));
    expect(trace['bookTitle'], 'Skogheim');
    expect(trace['sessionTitle'], 'Partie 1');
  });

  test('Pipeline trace includes persisted RAW even without any HTTP diagnostics', () {
    final trace = exportAiPipelineTrace(timeline, const [
      RawGeneration(playerEventId: 2, rawText: 'Le RAW est sauvegardé'),
      RawGeneration(playerEventId: 6, rawText: 'Texte structuré',
        firstEventId: 7, lastEventId: 8),
    ], const []);
    expect(trace['capturedExchangeCount'], 0);
    final turns = trace['turns'] as List;
    expect(turns.singleWhere((e) => e['playerEventId'] == 2)['raw']['status'],
      'pending_jsonification');
    expect(turns.singleWhere((e) => e['playerEventId'] == 6)['raw']['status'],
      'jsonified');
    expect(jsonEncode(trace), contains('Le RAW est sauvegardé'));
    expect(jsonEncode(trace), contains('Seuls les échanges encore conservés'));
  });

  test('Pipeline trace records orphan exchanges and malformed stored diagnostics', () {
    final recorder = AiExchangeRecorder();
    final orphan = recorder.begin(
      provider: 'openai-compatible', method: 'POST',
      url: 'https://example.invalid/v1/chat/completions',
      requestBody: '{"model":"test"}', secret: 'secret-token',
      accept: 'application/json',
    );
    orphan.complete(error: 'Rejected before matching player turn');
    final trace = exportAiPipelineTrace(const [], const [], [
      StoredAiDiagnostic(id: 'broken', sessionId: 's',
        createdAtUtc: DateTime.utc(2026), content: 'not-json'),
    ], latestExchange: orphan);
    expect(trace['unreadableDiagnosticCount'], 1);
    expect((trace['unassignedExchanges'] as List), hasLength(1));
    expect(trace['capturedExchangeCount'], 1);
    expect(trace['turns'], isEmpty);
  });

  test('Conversation export includes optional emotion on character messages', () {
    final exported = exportConversation(const [
      ChatEntry(id: 2, speaker: ChatSpeaker.character,
          name: 'Liv', text: 'Quoi ?!', status: 'étonnée'),
    ]);
    final events = exported['events'] as List;
    expect(events.single['status'], 'étonnée');
    expect(events.single['text'], 'Quoi ?!');
  });

}
