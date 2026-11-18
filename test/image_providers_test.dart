// ignore_for_file: prefer_interpolation_to_compose_strings, curly_braces_in_flow_control_structures
import 'dart:convert';
import 'dart:typed_data';

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
}
