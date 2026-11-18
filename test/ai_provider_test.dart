import 'dart:async';
import 'dart:convert';

import 'package:domolia/ai/ai_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const settings = AiConfiguration(
  baseUrl: defaultAiBaseUrl,
  model: defaultAiModel,
  apiKey: 'ou-private-test-key',
);

void main() {
  test('OpenAI transport uses TLS, bearer auth and a short non-streamed chat', () async {
    final provider = OpenAiCompatibleChatProvider(client: MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.toString(),
          'https://api.openuncensored.com/v1/chat/completions');
      expect(request.headers['Authorization'], 'Bearer ou-private-test-key');
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      expect(payload['model'], defaultAiModel);
      expect(payload['stream'], false);
      expect(payload['max_tokens'], 64);
      expect((payload['messages'] as List).single['role'], 'user');
      return http.Response(
        '{"choices":[{"message":{"role":"assistant","content":"Bonjour !"}}]}',
        200,
      );
    }));
    expect(
      await provider.complete(settings,
          messages: const [AiMessage(role: 'user', content: 'Dis bonjour.')]),
      'Bonjour !',
    );
  });

  test('Catalogue supports text models and ignores unavailable or image models', () async {
    final provider = OpenAiCompatibleChatProvider(client: MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/v1/models');
      return http.Response(jsonEncode({
        'data': [
          {'id': 'b', 'modality': 'text'},
          {'id': 'a', 'modality': 'text'},
          {'id': 'z', 'modality': 'image'},
          {'id': 'x', 'modality': 'text', 'available': false},
          {'id': 'a', 'modality': 'text'},
        ],
      }), 200);
    }));
    expect(
      (await provider.listModels(settings)).map((item) => item.id).toList(),
      ['a', 'b'],
    );
  });

  for (final pair in <int, String>{
    401: 'Clé API refusée',
    402: 'Crédits',
    404: 'introuvable',
    429: 'Limite de débit',
    503: 'HTTP 503',
  }.entries) {
    test('HTTP status ${pair.key} is safe and actionable', () async {
      final provider = OpenAiCompatibleChatProvider(client: MockClient(
        (_) async => http.Response(
          '{"error":{"message":"SECRET ou-private-test-key"}}',
          pair.key,
        ),
      ));
      await expectLater(
        provider.listModels(settings),
        throwsA(isA<AiProviderException>().having(
          (e) => e.userMessage, 'safe message', allOf(
            contains(pair.value),
            isNot(contains('SECRET')),
            isNot(contains(settings.apiKey)),
          ),
        )),
      );
    });
  }

  test('No key never makes a network call', () async {
    var called = false;
    final provider = OpenAiCompatibleChatProvider(client: MockClient((_) async {
      called = true;
      return http.Response('{}', 200);
    }));
    await expectLater(
      provider.listModels(const AiConfiguration(
        baseUrl: defaultAiBaseUrl, model: defaultAiModel, apiKey: '',
      )),
      throwsA(isA<AiProviderException>()),
    );
    expect(called, false);
  });

  test('TLS and URL validation prevents accidental disclosure', () async {
    for (final url in [
      'http://api.openuncensored.com/v1',
      'https://user:pass@api.openuncensored.com/v1',
      'https://api.openuncensored.com/v1?key=secret',
    ]) {
      expect(() => validatedAiBaseUrl(url),
          throwsA(isA<AiProviderException>()));
    }
    expect(validatedAiBaseUrl(' https://api.openuncensored.com/v1/ '),
        defaultAiBaseUrl);
  });

  test('A redirect cannot forward Authorization to another host', () async {
    var calls = 0;
    final provider = OpenAiCompatibleChatProvider(client: MockClient((request) async {
      calls++;
      expect(request.followRedirects, false);
      return http.Response('', 307, headers: {
        'location': 'https://attacker.example/collect',
      });
    }));
    await expectLater(provider.listModels(settings),
        throwsA(isA<AiProviderException>()));
    expect(calls, 1);
  });

  test('Offline transport errors do not leak network details', () async {
    final provider = OpenAiCompatibleChatProvider(client: MockClient((_) async {
      throw http.ClientException('ou-private-test-key in private exception');
    }));
    await expectLater(provider.listModels(settings),
        throwsA(isA<AiProviderException>().having(
          (e) => e.userMessage, 'safe error',
          isNot(contains('ou-private-test-key')),
        )));
  });

  test('Malformed JSON and empty model response are handled', () async {
    final provider = OpenAiCompatibleChatProvider(
      client: MockClient((_) async => http.Response('not json', 200)),
    );
    await expectLater(provider.listModels(settings),
        throwsA(isA<AiProviderException>()));
    final empty = OpenAiCompatibleChatProvider(
      client: MockClient((_) async => http.Response('{"choices":[]}', 200)),
    );
    await expectLater(
      empty.complete(settings,
          messages: const [AiMessage(role: 'user', content: 'bonjour')]),
      throwsA(isA<AiProviderException>()),
    );
  });

  test('Model IDs and chat messages are validated locally', () async {
    expect(() => validatedAiModel('  '), throwsA(isA<AiProviderException>()));
    final provider = OpenAiCompatibleChatProvider(
        client: MockClient((_) async => http.Response('{}', 200)));
    await expectLater(provider.complete(settings, messages: const []),
        throwsA(isA<AiProviderException>()));
    await expectLater(
      provider.complete(settings,
          messages: const [AiMessage(role: 'intruder', content: 'hello')]),
      throwsA(isA<AiProviderException>()),
    );
  });

  test('HTTP 403 means access denied, not an inferred content refusal', () async {
    final provider = OpenAiCompatibleChatProvider(client: MockClient(
      (_) async => http.Response('{"error":{"message":"denied"}}', 403),
    ));
    await expectLater(provider.listModels(settings), throwsA(
      isA<AiProviderException>()
        .having((e) => e.kind, 'kind', AiProviderErrorKind.access)
        .having((e) => e.userMessage, 'message', contains('HTTP 403')),
    ));
  });

  test('Only explicit machine-readable refusal is classified as refused', () async {
    for (final status in [400, 403, 422]) {
      final provider = OpenAiCompatibleChatProvider(client: MockClient(
        (_) async => http.Response(jsonEncode({
          'error': {
            'code': 'content_policy_violation',
            'message': 'private key ou-private-test-key',
          },
        }), status),
      ));
      await expectLater(provider.listModels(settings), throwsA(
        isA<AiProviderException>()
          .having((e) => e.kind, 'kind', AiProviderErrorKind.refused)
          .having((e) => e.userMessage, 'sanitized',
            isNot(contains(settings.apiKey))),
      ));
    }
  });

  test('Streaming distinguishes a filtered response from a truncated one', () async {
    for (final finish in ['content_filter', 'length']) {
      final body = 'data: ${jsonEncode({
        'choices': [{'finish_reason': finish, 'delta': {'content': ''}}],
      })}\n\ndata: [DONE]\n\n';
      final provider = OpenAiCompatibleChatProvider(
        client: MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(provider.streamChat(settings, messages: const [
        AiMessage(role: 'user', content: 'Bonjour'),
      ]).toList(), throwsA(isA<AiProviderException>()
          .having((e) => e.kind, 'kind', finish == 'content_filter'
              ? AiProviderErrorKind.refused : AiProviderErrorKind.provider)));
    }
  });

  test('Tool streams classify HTTP timeout and explicit refusal', () async {
    for (final status in [504, 422]) {
      final body = status == 422
          ? '{"error":{"type":"content_filter"}}' : '{"error":"timeout"}';
      final provider = OpenAiCompatibleChatProvider(
        client: MockClient((_) async => http.Response(body, status)),
      );
      await expectLater(provider.streamToolChat(settings,
        messages: const [AiToolMessage(role: 'user', content: 'Bonjour')],
        tools: const [],
      ).toList(), throwsA(isA<AiProviderException>()
          .having((e) => e.kind, 'kind', status == 504
              ? AiProviderErrorKind.timeout : AiProviderErrorKind.refused)));
    }
  });

  test('Connection and 25-second header timeout have different kinds', () async {
    for (final network in [true, false]) {
      final provider = OpenAiCompatibleChatProvider(client: MockClient((_) async {
        if (network) throw http.ClientException('private key ou-private-test-key');
        throw TimeoutException('private key ou-private-test-key');
      }));
      await expectLater(provider.streamChat(settings, messages: const [
        AiMessage(role: 'user', content: 'Bonjour'),
      ]).toList(), throwsA(isA<AiProviderException>()
          .having((e) => e.kind, 'kind', network
              ? AiProviderErrorKind.network : AiProviderErrorKind.timeout)
          .having((e) => e.userMessage, 'safe message',
              isNot(contains(settings.apiKey)))));
    }
  });
}
