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
}
