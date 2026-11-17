import 'dart:convert';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:domolia/ai/chatgpt_auth.dart';
import 'package:domolia/ai/chatgpt_responses.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class InMemoryOAuthStore implements ChatGptSessionStore {
  final Map<String, ChatGptSession> accounts = {};
  @override
  Future<String> hostId() async => 'urn:uuid:00000000-0000-4000-8000-000000000001';
  @override
  Future<ChatGptSession?> read(String id) async => accounts[id];
  @override
  Future<void> write(String id, ChatGptSession session) async {
    accounts[id] = session;
  }
  @override
  Future<void> delete(String id) async { accounts.remove(id); }
}

class FakeBrowser implements ChatGptAuthBrowser {
  FakeBrowser(this.callback);
  final Map<String, String> Function(Uri url) callback;
  @override
  Future<Map<String, String>> authorize(Uri Function(Uri callback) buildUrl) async =>
      callback(buildUrl(Uri.parse('http://127.0.0.1:15000/auth/callback')));
}

ChatGptSession mockSession({
  String client = 'oaiapp_123',
  String token = 'oauth-mocked',
  DateTime? expiry,
}) => ChatGptSession(
  clientId: client,
  subject: 'user-1',
  email: 'test@example.com',
  idToken: 'sample-id-token',
  accessToken: token,
  refreshToken: 'mock-refresh',
  scopes: {'openid', 'chatgpt.tokens.use.direct', 'resource.invoke'},
  expiresAt: expiry ?? DateTime.now().toUtc().add(const Duration(hours: 1)),
);

void main() {
  test('Named ChatGPT sessions remain separate in encrypted-store contract', () async {
    final store = InMemoryOAuthStore();
    await store.write('one', mockSession(token: 'first'));
    await store.write('two', mockSession(token: 'second'));
    expect((await store.read('one'))!.accessToken, 'first');
    expect((await store.read('two'))!.accessToken, 'second');
    await store.delete('one');
    expect(await store.read('one'), isNull);
    expect((await store.read('two'))!.accessToken, 'second');
  });

  test('OAuth validates callback state before calling any token endpoint', () async {
    var requests = 0;
    final store = InMemoryOAuthStore();
    final service = ChatGptAuthService(
      store: store,
      browser: FakeBrowser((url) {
        expect(url.host, 'auth.openai.com');
        expect(url.queryParameters['client_id'], 'dynamic_agent_client');
        expect(url.queryParameters['agent_name_hint'], 'Domolia');
        expect(url.queryParameters['code_challenge_method'], 'S256');
        expect(url.queryParameters['scope'], contains('chatgpt.tokens.use.direct'));
        expect(url.queryParameters['ext_agent_host_id'], startsWith('urn:uuid:'));
        return {'code': 'untrusted-code', 'state': 'different-state'};
      }),
      client: MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );
    await expectLater(
      service.signIn('named-chatgpt-profile'),
      throwsA(isA<AiProviderException>()),
    );
    expect(requests, 0);
    expect(await store.read('named-chatgpt-profile'), isNull);
  });

  test('Valid cached OAuth token is returned without networking', () async {
    final store = InMemoryOAuthStore();
    await store.write('local', mockSession());
    var called = false;
    final service = ChatGptAuthService(
      store: store,
      client: MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      }),
    );
    expect(await service.accessToken('local'), 'oauth-mocked');
    expect(called, false);
  });

  test('Refresh replaces rotating credentials atomically for selected profile', () async {
    final store = InMemoryOAuthStore();
    await store.write('a', mockSession(
      expiry: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
    ));
    await store.write('b', mockSession(token: 'other'));
    var calls = 0;
    final service = ChatGptAuthService(
      store: store,
      client: MockClient((request) async {
        calls++;
        expect(request.url.host, 'auth.openai.com');
        expect(request.bodyFields['grant_type'], 'refresh_token');
        expect(request.bodyFields['refresh_token'], 'mock-refresh');
        expect(request.bodyFields['resource'], 'https://api.openai.com/v1');
        return http.Response(jsonEncode({
          'access_token': 'renewed',
          'refresh_token': 'new-refresh',
          'expires_in': 3600,
          'scope': 'openid chatgpt.tokens.use.direct resource.invoke',
        }), 200);
      }),
    );
    final values = await Future.wait([
      service.accessToken('a'),
      service.accessToken('a'),
    ]);
    expect(values, ['renewed', 'renewed']);
    expect(calls, 1);
    expect((await store.read('a'))!.refreshToken, 'new-refresh');
    expect((await store.read('b'))!.accessToken, 'other');
  });

  test('Responses API uses OAuth bearer, store:false and streaming', () async {
    final recorder = AiExchangeRecorder();
    final provider = ChatGptResponsesProvider(
      diagnostics: recorder,
      client: MockClient((request) async {
        expect(request.followRedirects, false);
        expect(request.url.toString(), 'https://api.openai.com/v1/responses');
        expect(request.headers['Authorization'], 'Bearer oauth-mocked');
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        expect(payload['stream'], true);
        expect(payload['store'], false);
        expect(payload.containsKey('max_output_tokens'), false);
        expect(payload['input'], isA<List>());
        return http.Response(
          'data: {"type":"response.output_text.delta","delta":"Bonjour"}\n\n'
          'data: {"type":"response.completed","response":{"usage":'
          '{"input_tokens":7,"output_tokens":3}}}\n\n',
          200,
        );
      }),
    );
    final chunks = await provider.streamChat(
      AiConfiguration(
        baseUrl: 'https://api.openai.com/v1',
        model: 'test-model',
        apiKey: 'oauth-mocked',
      ),
      messages: const [AiMessage(role: 'user', content: 'Salut')],
    ).toList();
    expect(chunks.map((part) => part.text).join(), 'Bonjour');
    expect(chunks.last.promptTokens, 7);
    final exported = recorder.last!.toJson();
    expect((exported['request'] as Map)['url'],
      'https://api.openai.com/v1/responses');
    expect((exported['request'] as Map)['body']['store'], false);
    expect((exported['response'] as Map)['rawBody'],
      contains('response.output_text.delta'));
    expect(recorder.last!.exportJson(), isNot(contains('oauth-mocked')));
  });

  test('Responses failure is surfaced without raw token or body', () async {
    final provider = ChatGptResponsesProvider(
      client: MockClient((_) async => http.Response(
        'data: {"type":"response.failed","response":{"error":'
        '{"message":"private oauth-mocked"}}}\n\n',
        200,
      )),
    );
    await expectLater(
      provider.streamChat(
        const AiConfiguration(
          baseUrl: 'https://api.openai.com/v1',
          model: 'test-model', apiKey: 'oauth-mocked',
        ),
        messages: const [AiMessage(role: 'user', content: 'Salut')],
      ).toList(),
      throwsA(isA<AiProviderException>().having(
        (error) => error.userMessage,
        'no secrets',
        isNot(contains('oauth-mocked')),
      )),
    );
  });
  test('OSS Responses omits unsupported budget, preserves reasoning', () async {
    final bodies = <Map<String, dynamic>>[];
    final provider = ChatGptResponsesProvider(
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        bodies.add(body);
        expect(request.headers['Authorization'], 'Bearer test-secret');
        return http.Response(
          'data: {"type":"response.output_text.delta","delta":"Reponse"}\n\n'
          'data: {"type":"response.completed","response":{"usage":'
          '{"input_tokens":14,"output_tokens":120}}}\n\n',
          200,
        );
      }),
    );
    const base = AiConfiguration(
      baseUrl: 'https://api.openai.com/v1',
      model: 'gpt-5.6-luna', apiKey: 'test-secret',
    );
    final outputs = <String>[];
    for (final (effort, limit) in [
      ('low', 8192), ('none', 4096), (null, 16384),
    ]) {
      final chunks = await provider.streamChat(
        base.withReasoning(effort),
        messages: const [AiMessage(role: 'user', content: 'Bonjour')],
        maxTokens: limit,
      ).toList();
      outputs.add(chunks.map((chunk) => chunk.text).join());
    }
    expect(outputs, ['Reponse', 'Reponse', 'Reponse']);
    expect(bodies.every((b) => !b.containsKey('max_output_tokens')), true);
    expect((bodies[0]['reasoning'] as Map)['effort'], 'low');
    expect((bodies[1]['reasoning'] as Map)['effort'], 'none');
    expect(bodies[2].containsKey('reasoning'), false);
    expect(jsonEncode(bodies), isNot(contains('test-secret')));
  });

  test('OSS Responses puts system guidance into instructions', () async {
    final provider = ChatGptResponsesProvider(
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['instructions'], 'Consigne A\n\nConsigne B');
        expect(body['input'], [
          {'role': 'user', 'content': 'Bonjour'},
        ]);
        expect(body.containsKey('max_output_tokens'), false);
        return http.Response(
          'data: {"type":"response.output_text.delta","delta":"Salut"}\n\n'
          'data: {"type":"response.completed","response":{}}\n\n',
          200,
        );
      }),
    );
    final answer = await provider.complete(
      const AiConfiguration(
        baseUrl: 'https://api.openai.com/v1',
        model: 'test-model', apiKey: 'test-secret',
      ),
      messages: const [
        AiMessage(role: 'system', content: 'Consigne A'),
        AiMessage(role: 'user', content: 'Bonjour'),
        AiMessage(role: 'system', content: 'Consigne B'),
      ],
    );
    expect(answer, 'Salut');
  });

  test('Same tool protocol works over Responses and feeds result back', () async {
    final recorded = <Map<String, dynamic>>[];
    final provider = ChatGptResponsesProvider(
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        recorded.add(body);
        expect(body['store'], false);
        expect(body['stream'], true);
        expect(body.containsKey('max_output_tokens'), false);
        expect(body['instructions'], 'Recherche le lore pertinent.');
        if (recorded.length == 1) {
          expect(body['input'], [
            {'role': 'user', 'content': 'Trouve le dragon.'},
          ]);
          final namespace = (body['tools'] as List).single as Map;
          expect(namespace['type'], 'namespace');
          expect(namespace['name'], 'domolia');
          expect((namespace['tools'] as List).single['name'], 'lore');
          return http.Response(
            'data: {"type":"response.output_item.added",'
            '"output_index":1,"item":{"type":"function_call",'
            '"call_id":"call1","namespace":"domolia",'
            '"name":"lore","arguments":""}}\n\n'
            'data: {"type":"response.function_call_arguments.delta",'
            '"output_index":1,"delta":"{\"query\":"}\n\n'
            'data: {"type":"response.function_call_arguments.delta",'
            '"output_index":1,"delta":"\"dragon\"}"}\n\n'
            'data: {"type":"response.output_item.done",'
            '"output_index":1,"item":{"type":"function_call",'
            '"call_id":"call1","name":"lore","arguments":"{\"query\":\"dragon\"}"}}\n\n'
            'data: {"type":"response.completed","response":{"usage":'
            '{"input_tokens":8,"output_tokens":4}}}\n\n',
            200,
          );
        }
        expect(body.containsKey('tools'), false);
        final input = body['input'] as List;
        expect(input[1], {
          'type': 'function_call', 'namespace': 'domolia',
          'call_id': 'call1', 'name': 'lore',
          'arguments': '{"query":"dragon"}',
        });
        expect(input[2], {
          'type': 'function_call_output',
          'call_id': 'call1',
          'output': '{"name":"Aile rouge"}',
        });
        return http.Response(
          'data: {"type":"response.output_text.delta",'
          '"delta":"Le dragon est rouge."}\n\n'
          'data: {"type":"response.completed",'
          '"response":{"usage":{"input_tokens":12,"output_tokens":7}}}\n\n',
          200,
        );
      }),
    );
    const config = AiConfiguration(baseUrl: 'https://api.openai.com/v1',
        model: 'test-model', apiKey: 'test-secret');
    const definitions = [
      AiToolDefinition('lore', 'Chercher le lore', {
        'type': 'object',
        'properties': {'query': {'type': 'string'}},
        'required': ['query'],
      }),
    ];
    final first = await provider.streamToolChat(config, messages: const [
      AiToolMessage(role: 'system', content: 'Recherche le lore pertinent.'),
      AiToolMessage(role: 'user', content: 'Trouve le dragon.'),
    ], tools: definitions).toList();
    expect(first.where((v) => v.callIndex != null).length, 4);
    expect(first.where((v) => v.callName != null).first.callName, 'lore');
    expect(first.where((v) => v.argumentsDelta != null)
        .map((v) => v.argumentsDelta).join(), '{"query":"dragon"}');
    expect(first.last.finishReason, 'tool_calls');
    expect(first.last.promptTokens, 8);

    final second = await provider.streamToolChat(config, messages: const [
      AiToolMessage(role: 'system', content: 'Recherche le lore pertinent.'),
      AiToolMessage(role: 'user', content: 'Trouve le dragon.'),
      AiToolMessage(role: 'assistant', calls: [
        AiToolInvocation(
          id: 'call1', name: 'lore', arguments: '{"query":"dragon"}'),
      ]),
      AiToolMessage(role: 'tool', toolCallId: 'call1',
          content: '{"name":"Aile rouge"}'),
    ], tools: []).toList();
    expect(second.map((v) => v.text).join(), 'Le dragon est rouge.');
    expect(second.last.finishReason, 'stop');
    expect(second.last.promptTokens, 12);
    expect(recorded.length, 2);
    expect(jsonEncode(recorded), isNot(contains('test-secret')));
  });

  test('Bad budgets and effort are rejected before an HTTP request', () async {
    var calls = 0;
    final provider = ChatGptResponsesProvider(
      client: MockClient((_) async {
        calls++;
        return http.Response('', 200);
      }),
    );
    const configuration = AiConfiguration(
      baseUrl: 'https://api.openai.com/v1',
      model: 'gpt-5.6-luna', apiKey: 'private',
    );
    await expectLater(provider.streamChat(configuration,
      messages: const [AiMessage(role: 'user', content: 'Bonjour')],
      maxTokens: 50000,
    ).toList(), throwsA(isA<AiProviderException>()));
    await expectLater(provider.streamChat(
      configuration.withReasoning('invalid'),
      messages: const [AiMessage(role: 'user', content: 'Bonjour')],
    ).toList(), throwsA(isA<AiProviderException>()));
    expect(calls, 0);
  });

  test('Incomplete Luna responses identify consumed output/reasoning budget',
      () async {
    final provider = ChatGptResponsesProvider(
      client: MockClient((_) async => http.Response(
        'data: {"type":"response.incomplete","response":'
        '{"status":"incomplete","incomplete_details":'
        '{"reason":"max_output_tokens"}}}\n\n', 200,
      )),
    );
    await expectLater(
      provider.streamChat(const AiConfiguration(
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-5.6-luna', apiKey: 'secret',
      ), messages: const [AiMessage(role: 'user', content: 'Bonjour')],
        maxTokens: 4096).toList(),
      throwsA(isA<AiProviderException>().having(
        (e) => e.userMessage, 'budget message', contains('raisonnement'))),
    );
  });

}
