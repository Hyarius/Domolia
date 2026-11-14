import 'dart:convert';

import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:domolia/chat/chat_exports.dart';
import 'package:domolia/chat/chat_protocol.dart';
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
}
