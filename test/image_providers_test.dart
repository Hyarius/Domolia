// ignore_for_file: prefer_interpolation_to_compose_strings, curly_braces_in_flow_control_structures
import 'dart:convert';
import 'dart:typed_data';

import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:domolia/chat/chat_exports.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/illustration/image_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _png = Uint8List.fromList([
  137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,
  0,0,0,1,0,0,0,1,8,6,0,0,0,31,21,196,137,
  0,0,0,11,73,68,65,84,120,156,99,0,1,0,0,5,0,1,
  13,10,45,180,0,0,0,0,73,69,78,68,174,66,96,130,
]);

void main() {
  test('Auto model prefers a documented OpenUncensored default', () {
    const catalogue = [
      ImageModelCapability(id:'other', sizes:['1024x1024']),
      ImageModelCapability(id:'z-image-turbo', sizes:['1024x1024']),
    ];
    expect(selectImageModel(catalogue, '').id, 'z-image-turbo');
    expect(selectImageModel(catalogue, 'other').id, 'other');
    expect(() => selectImageModel(catalogue, 'no-such-model'),
        throwsA(isA<ImageGenerationFailure>()));
    expect(() => selectImageModel(const [], ''),
        throwsA(isA<ImageGenerationFailure>()));
  });

  test('OpenAI API key and GPT Image request are distinct from ChatGPT OAuth',
      () async {
    final provider = OpenAiImageGenerationProvider(client: MockClient(
      (request) async {
        expect(request.url.toString(),
            'https://api.openai.com/v1/images/generations');
        expect(request.headers['Authorization'], 'Bearer personal-api-key');
        final body = jsonDecode(request.body) as Map<String,dynamic>;
        expect(body['model'], 'gpt-image-2');
        expect(body['n'], 1);
        expect(body['size'], '1024x1024');
        expect(body['quality'], 'medium');
        return http.Response(jsonEncode({'data': [
          {'b64_json': base64Encode(_png)},
        ]}), 200);
      },
    ));
    final result = await provider.generate(
      const ImageGenerationRequest(
        model:'gpt-image-2', prompt:'An old wooden drawer',
        quality:'medium',
      ),
      apiKey:'personal-api-key',
    );
    expect(result.images.single.mimeType, 'image/png');
    expect(result.costUsd, isNull);
  });

  test('OpenUncensored model catalog and generation reuse same bearer', () async {
    final paths = <String>[];
    final provider = OpenUncensoredImageGenerationProvider(client: MockClient(
      (req) async {
        paths.add(req.url.path);
        expect(req.headers['Authorization'], 'Bearer ou-existing-key');
        if (req.method == 'GET') {
          return http.Response(jsonEncode({'data': [
            {'id':'visual-model', 'operations':['generate']},
            {'id':'edit-only', 'operations':['edit']},
          ]}), 200);
        }
        final body = jsonDecode(req.body) as Map<String,dynamic>;
        expect(body['response_format'], 'b64_json');
        expect(body['model'], 'visual-model');
        return http.Response(jsonEncode({'data': [
          {'b64_json':base64Encode(_png)}
        ], 'ou':{'cost_usd':0.03}}),200);
      },
    ));
    final catalog = await provider.listModels('ou-existing-key');
    expect(catalog.map((e)=>e.id), ['visual-model']);
    final result = await provider.generate(const ImageGenerationRequest(
      model:'visual-model', prompt:'Harbor at dawn'),apiKey:'ou-existing-key');
    expect(result.images.single.bytes, _png);
    expect(result.costUsd, 0.03);
    expect(paths, ['/v1/images/models','/v1/images/models',
      '/v1/images/generations']);
  });

  test('Temporary HTTPS URL is downloaded to local bytes', () async {
    final provider=OpenAiImageGenerationProvider(client:MockClient((req) async {
      if (req.url.host=='cdn.example.org') {
        return http.Response.bytes(_png,200);
      }
      return http.Response('{"data":[{"url":"https://cdn.example.org/a.png"}]}',
          200);
    }));
    final result=await provider.generate(
      const ImageGenerationRequest(model:'gpt-image-2',prompt:'Sea'),
      apiKey:'key');
    expect(result.images.single.bytes,_png);
  });

  for (final item in <int,ImageFailureKind>{
    401:ImageFailureKind.authentication,
    402:ImageFailureKind.credits,
    422:ImageFailureKind.refused,
    429:ImageFailureKind.unavailable,
  }.entries) {
    test('HTTP error ' + item.key.toString() + ' redacts secrets', () async {
      final provider=OpenAiImageGenerationProvider(
        client:MockClient((_) async => http.Response(
            '{"error":"secret-personal-api-key"}',item.key)));
      await expectLater(provider.generate(
        const ImageGenerationRequest(model:'gpt-image-2',prompt:'Harbor'),
        apiKey:'secret-personal-api-key',
      ), throwsA(isA<ImageGenerationFailure>().having(
        (e)=>e.kind,'error kind',item.value)));
    });
  }

  test('No key prevents paid network attempt', () async {
    var networkCalls=0;
    final provider=OpenAiImageGenerationProvider(
      client:MockClient((_) async {networkCalls++;return http.Response('',200);}));
    await expectLater(provider.generate(
      const ImageGenerationRequest(model:'gpt-image-2',prompt:'Harbor'),
      apiKey:'',
    ),throwsA(isA<ImageGenerationFailure>()));
    expect(networkCalls,0);
  });

  test('Malformed image and unsupported format fail closed', () async {
    final provider=OpenAiImageGenerationProvider(client:MockClient(
      (_) async => http.Response('{"data":[{"b64_json":"AAECAwQ="}]}',200)));
    await expectLater(provider.generate(
      const ImageGenerationRequest(model:'gpt-image-2',prompt:'Harbor'),
      apiKey:'key',
    ),throwsA(isA<ImageGenerationFailure>()));
  });

  test('Unknown OpenUncensored model is rejected before paid POST', () async {
    var postCalls=0;
    final provider=OpenUncensoredImageGenerationProvider(client:MockClient(
      (req) async {
        if(req.method=='POST')postCalls++;
        return http.Response('{"data":[{"id":"another"}]}',200);
      }));
    await expectLater(provider.generate(
      const ImageGenerationRequest(model:'not-available',prompt:'Harbor'),
      apiKey:'key',
    ),throwsA(isA<ImageGenerationFailure>()));
    expect(postCalls,0);
  });

  test('Oversized response rejected', () async {
    final provider=OpenAiImageGenerationProvider(client:MockClient(
      (_) async => http.Response('{"data":[{"b64_json":"' +
        List.filled(23*1024*1024, 'A').join() + '"}]}',200)));
    await expectLater(provider.generate(
      const ImageGenerationRequest(model:'gpt-image-2',prompt:'Harbor'),
      apiKey:'key',
    ),throwsA(isA<ImageGenerationFailure>().having(
      (e)=>e.kind,'kind',ImageFailureKind.tooLarge)));
  });

  test('Image HTTP catalog and generation appear in redacted Party diagnostics',
      () async {
    const key = 'private-image-key';
    const prompt = 'A sea cliff at dawn';
    final encoded = base64Encode(_png);
    final exchanges = <AiExchange>[];
    final recorder = AiExchangeRecorder();
    final provider = OpenUncensoredImageGenerationProvider(
      diagnostics: recorder,
      playerEventId: 4,
      onExchangeCaptured: exchanges.add,
      client: MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(jsonEncode({'data': [
            {'id':'z-image-turbo', 'operations':['generate']},
          ]}), 200);
        }
        return http.Response(jsonEncode({
          'data': [
            {'b64_json': encoded, 'revised_prompt': 'private-upstream-note'},
          ],
          'ou': {'cost_usd': 0.015},
        }), 200);
      }),
    );
    final result = await provider.generate(
      const ImageGenerationRequest(model:'z-image-turbo', prompt:prompt),
      apiKey:key,
    );
    expect(result.images, hasLength(1));
    expect(exchanges.map((entry) => entry.stage),
        ['image_catalog', 'image_generation']);
    expect(exchanges.map((entry) => entry.playerEventId), [4, 4]);
    expect(exchanges.map((entry) => entry.statusCode), [200, 200]);
    expect(exchanges.every((entry) => entry.completedAtUtc != null), isTrue);
    final generated = exchanges.last.toJson();
    expect(generated['request']['body']['prompt'], prompt);
    expect(generated['request']['body']['model'], 'z-image-turbo');
    expect(generated['response']['truncated'], isTrue);
    final metadata = jsonDecode(generated['response']['rawBody'] as String);
    expect(metadata['imagePayloadRedacted'], true);
    expect(metadata['imageCount'], 1);
    expect(metadata['ou']['cost_usd'], 0.015);
    expect(metadata['actualResponseBytes'], greaterThan(0));
    final serialized = jsonEncode(exchanges.map((e) => e.toJson()).toList());
    expect(serialized, isNot(contains(encoded)));
    expect(serialized, isNot(contains('private-upstream-note')));
    expect(serialized, isNot(contains(key)));

    final trace = exportAiPipelineTrace(const [
      ChatEntry(id:4, speaker:ChatSpeaker.player,
        name:'Vous', text:'Je regarde la falaise.'),
    ], const [], [
      for (final entry in exchanges)
        StoredAiDiagnostic(id:'image-${entry.createdAtUtc.microsecondsSinceEpoch}',
          sessionId:'s', createdAtUtc:entry.createdAtUtc,
          content:entry.exportJson()),
    ]);
    final turn = (trace['turns'] as List).single;
    expect((turn['phases'] as List).map((e) => e['stage']),
      ['image_catalog','image_generation']);
    expect(turn['usage']['imageCatalogRequests'], 1);
    expect(turn['usage']['imageGenerationRequests'], 1);
    expect(turn['usage']['knownImageCostUsd'], 0.015);
    expect(turn['usage']['requestsWithoutTokenUsage'], 0);
  });

  test('Image error HTTP status, duration and sanitized cause are persisted',
      () async {
    const key = 'secret-image-credential';
    final exchanges = <AiExchange>[];
    final provider = OpenAiImageGenerationProvider(
      diagnostics: AiExchangeRecorder(),
      playerEventId: 9,
      onExchangeCaptured: exchanges.add,
      client: MockClient((_) async => http.Response(
        '{"error":{"message":"secret-image-credential sensitive text"}}', 403)),
    );
    await expectLater(provider.generate(
      const ImageGenerationRequest(model:'gpt-image-2', prompt:'Harbor'),
      apiKey:key,
    ), throwsA(isA<ImageGenerationFailure>()));
    expect(exchanges, hasLength(1));
    final trace = exchanges.single.toJson();
    expect(trace['stage'], 'image_generation');
    expect(trace['playerEventId'], 9);
    expect(trace['response']['statusCode'], 403);
    expect(trace['interpretation']['error'], contains('Clé API'));
    expect(jsonEncode(trace), isNot(contains(key)));
    expect(jsonEncode(trace), isNot(contains('sensitive text')));
    expect(trace['completedAtUtc'], isNotNull);
  });
}
