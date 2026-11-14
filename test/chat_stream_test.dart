import 'dart:convert';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const credentials = AiConfiguration(
  baseUrl: defaultAiBaseUrl,
  model: defaultAiModel,
  apiKey: 'ou-super-secret-test',
);

void main() {
  test('Streaming request sends bearer, no redirect and parses SSE delta/usage', () async {
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.toString(),
          'https://api.openuncensored.com/v1/chat/completions');
      expect(request.followRedirects, false);
      expect(request.headers['Authorization'], 'Bearer ou-super-secret-test');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['stream'], true);
      expect(body['max_tokens'], 1200);
      expect((body['stream_options'] as Map)['include_usage'], true);
      expect((body['messages'] as List).last['role'], 'user');
      return http.Response.bytes(utf8.encode(
        'data: {"choices":[{"delta":{"content":"Bonjour"}}]}\n\n'
        'data: {"choices":[{"delta":{"content":" à tous !"}}]}\n\n'
        'data: {"choices":[],"usage":{"prompt_tokens":23,"completion_tokens":8}}\n\n'
        'data: [DONE]\n\n',
      ),
        200,
        headers: {'content-type': 'text/event-stream; charset=utf-8'},
      );
    });
    final recorder = AiExchangeRecorder();
    final provider = OpenAiCompatibleChatProvider(
      client: client, diagnostics: recorder);
    final chunks = await provider.streamChat(
      credentials,
      messages: const [AiMessage(role: 'user', content: 'Salut')],
    ).toList();
    expect(chunks.map((e) => e.text).join(), 'Bonjour à tous !');
    expect(chunks.last.promptTokens, 23);
    expect(chunks.last.completionTokens, 8);
    final trace = recorder.last!.toJson();
    expect((trace['request'] as Map)['url'],
      'https://api.openuncensored.com/v1/chat/completions');
    expect((trace['request'] as Map)['body']['stream_options'],
      {'include_usage': true});
    expect((trace['response'] as Map)['statusCode'], 200);
    expect((trace['response'] as Map)['rawBody'],
      contains('data: {"choices":[],"usage"'));
    expect(recorder.last!.exportJson(), isNot(contains(credentials.apiKey)));
    client.close();
  });

  test('In-band error after HTTP 200 is safe and does not expose upstream body', () async {
    final client = MockClient((_) async => http.Response(
      'data: {"error":{"message":"private key ou-super-secret-test"}}\n\n'
      'data: [DONE]\n\n',
      200,
    ));
    final provider = OpenAiCompatibleChatProvider(client: client);
    await expectLater(
      provider.streamChat(
        credentials,
        messages: const [AiMessage(role: 'user', content: 'Bonjour')],
      ).toList(),
      throwsA(isA<AiProviderException>().having(
        (failure) => failure.userMessage,
        'sanitized',
        allOf(
          contains('interrompu'),
          isNot(contains(credentials.apiKey)),
        ),
      )),
    );
    client.close();
  });

  test('HTTP failures are readable without leaking tokens', () async {
    for (final status in [401, 402, 404, 429, 503]) {
      final client = MockClient((_) async => http.Response(
        '{"error":{"message":"ou-super-secret-test"}}',
        status,
      ));
      final provider = OpenAiCompatibleChatProvider(client: client);
      await expectLater(
        provider.streamChat(
          credentials,
          messages: const [AiMessage(role: 'user', content: 'Bonjour')],
        ).toList(),
        throwsA(isA<AiProviderException>().having(
          (failure) => failure.userMessage,
          'safe message',
          isNot(contains(credentials.apiKey)),
        )),
      );
      client.close();
    }
  });

  test('Truncated SSE is rejected even after partial text', () async {
    final client = MockClient((_) async => http.Response(
      'data: {"choices":[{"delta":{"content":"Bonjour"}}]}\n\n',
      200,
    ));
    final provider = OpenAiCompatibleChatProvider(client: client);
    await expectLater(
      provider.streamChat(
        credentials,
        messages: const [AiMessage(role: 'user', content: 'Bonjour')],
      ).toList(),
      throwsA(isA<AiProviderException>()),
    );
    client.close();
  });

  test('Missing key is rejected before the network request', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('data: [DONE]\n\n', 200);
    });
    final provider = OpenAiCompatibleChatProvider(client: client);
    await expectLater(
      provider.streamChat(
        const AiConfiguration(
          baseUrl: defaultAiBaseUrl,
          model: defaultAiModel,
          apiKey: '',
        ),
        messages: const [AiMessage(role: 'user', content: 'Bonjour')],
      ).toList(),
      throwsA(isA<AiProviderException>()),
    );
    expect(requests, 0);
    client.close();
  });
}
