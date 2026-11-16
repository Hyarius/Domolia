import 'dart:convert';

import 'package:domolia/ai/ai_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const config = AiConfiguration(
  baseUrl: defaultAiBaseUrl, model: defaultAiModel,
  apiKey: 'private-test-token',
);
const definition = AiToolDefinition('search_history', 'Search',
    {'type': 'object', 'properties': {
      'query': {'type': 'string'},
    }});

void main() {
  test('SSE carries partial JSON arguments and usage with native messages', () async {
    final provider = OpenAiCompatibleChatProvider(client: MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer private-test-token');
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      expect(payload['tool_choice'], 'auto');
      expect((payload['tools'] as List).single['function']['name'],
          'search_history');
      expect((payload['messages'] as List).last['role'], 'user');
      final frames = [
        {'choices': [{'delta': {'tool_calls': [
          {'index': 0, 'id': 'call_1',
           'function': {'name': 'search_history', 'arguments': '{"query":'}}
        ]}}]},
        {'choices': [{'delta': {'tool_calls': [
          {'index': 0, 'function': {'arguments': '"Liv"}'}}
        ]}}]},
        {'choices': [{'delta': {}, 'finish_reason': 'tool_calls'}]},
        {'choices': [], 'usage': {
          'prompt_tokens': 45, 'completion_tokens': 14,
        }},
      ];
      return http.Response(
        '${frames.map((f) => 'data: ${jsonEncode(f)}\n\n').join()}data: [DONE]\n\n',
        200,
      );
    }));
    final chunks = await provider.streamToolChat(config,
        messages: const [AiToolMessage(role: 'user', content: 'Hello')],
        tools: const [definition]).toList();
    expect(chunks.where((c) => c.argumentsDelta != null)
        .map((c) => c.argumentsDelta).join(), '{"query":"Liv"}');
    expect(chunks.last.promptTokens, 45);
    expect(chunks.any((c) => c.finishReason == 'tool_calls'), true);
  });

  test('Assistant tool_calls and tool results preserve their IDs', () {
    final assistant = AiToolMessage(role: 'assistant', calls: const [
      AiToolInvocation(id: 'x', name: 'search_lore', arguments: '{}'),
    ]);
    final answer = const AiToolMessage(
        role: 'tool', toolCallId: 'x', content: '{"results":[]}');
    expect(assistant.toJson()['tool_calls'][0]['id'], 'x');
    expect(answer.toJson()['tool_call_id'], 'x');
    expect(answer.toJson()['role'], 'tool');
  });

  test('Explicit tool incompatibility is distinguished from authentication', () async {
    for (final code in [400, 422]) {
      final provider = OpenAiCompatibleChatProvider(
        client: MockClient((_) async => http.Response(
          '{"error":{"param":"tools","message":"unsupported"}}', code,
        )),
      );
      await expectLater(provider.streamToolChat(config,
          messages: const [AiToolMessage(role: 'user', content: 'Test')],
          tools: const [definition]).toList(),
          throwsA(isA<AiToolsUnsupportedException>()));
    }
    final authentication = OpenAiCompatibleChatProvider(
      client: MockClient((_) async => http.Response(
        '{"error":{"param":"tools"}}', 401,
      )),
    );
    await expectLater(authentication.streamToolChat(config,
        messages: const [AiToolMessage(role: 'user', content: 'Test')],
        tools: const [definition]).toList(),
        throwsA(isA<AiProviderException>()
            .having((e) => e, 'not compatibility',
              isNot(isA<AiToolsUnsupportedException>()))));
  });

  test('A stream interrupted before DONE cannot be accepted', () async {
    final provider = OpenAiCompatibleChatProvider(
      client: MockClient((_) async => http.Response(
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,'
        '"id":"a","function":{"name":"search_lore","arguments":"{"}}]}}]}\n\n',
        200,
      )),
    );
    await expectLater(provider.streamToolChat(config,
        messages: const [AiToolMessage(role: 'user', content: 'Test')],
        tools: const [definition]).toList(),
        throwsA(isA<AiProviderException>()));
  });
}
