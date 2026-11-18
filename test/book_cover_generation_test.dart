import 'dart:convert';
import 'dart:typed_data';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/books/book_cover_generation.dart';
import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_lore.dart';
import 'package:domolia/illustration/image_preferences.dart';
import 'package:domolia/illustration/image_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

class _FakeCoverProvider implements ImageGenerationProvider {
  int generations = 0;
  int catalogs = 0;
  ImageGenerationRequest? request;
  @override
  String get id => 'openuncensored';
  @override
  Future<List<ImageModelCapability>> listModels(String apiKey) async {
    expect(apiKey, 'test-key');
    catalogs++;
    return const [
      ImageModelCapability(
        id: 'visual-model',
        sizes: ['1024x1536', '1024x1024'],
        qualities: ['medium', 'high'],
      ),
    ];
  }
  @override
  Future<ImageGenerationResult> generate(ImageGenerationRequest req,
      {required String apiKey}) async {
    expect(apiKey, 'test-key');
    generations++;
    request = req;
    final png = Uint8List.fromList(
        img.encodePng(img.Image(width: 32, height: 48)));
    return ImageGenerationResult(
      provider: id, model: req.model, costUsd: 0.02,
      images: [GeneratedImage(png, 'image/png')]);
  }
}

void main() {
  const profile = AiProfile(
    id: 'image', name: 'Images OpenUncensored',
    baseUrl: 'https://api.openuncensored.com/v1',
    model: 'unused', apiKey: 'test-key',
  );
  const book = BookDefinition(
    id: 'b', title: 'Le Registre de Sel',
    illustrationSettings: BookIllustrationSettings(
      style: 'gravure au fusain',
      negativePrompt: 'texte, bulles, filigranes',
      quality: 'medium',
    ),
    lore: BookLore(global: LoreGlobal(
      universe: 'Port des Brumes', genre: 'Mystère',
      era: 'Industriel', overview: 'Un quai enveloppé de brume.',
      secrets: 'Le meurtrier est le gardien du fanal.',
    )),
  );

  test('Cover uses Book art and safe public Lore, not secret text', () async {
    final fake = _FakeCoverProvider();
    final generator = BookCoverGenerator(providerFactory: (_) => fake);
    final generated = await generator.generate(
      book: book,
      connection: const ImageGenerationOptions(
        profileId: 'image', model: 'visual-model'),
      profiles: [profile],
    );
    expect(fake.generations, 1);
    expect(fake.catalogs, 1);
    expect(fake.request!.size, '1024x1536');
    expect(fake.request!.count, 1);
    expect(fake.request!.quality, isNull); // OpenUncensored has no quality field.
    expect(fake.request!.prompt, contains('texte, bulles, filigranes'));
    expect(fake.request!.prompt, contains('gravure au fusain'));
    expect(fake.request!.prompt, isNot(contains('meurtrier')));
    expect(generated.costUsd, 0.02);
    expect(generated.cover.mime, 'image/jpeg');
    final jpg = base64Decode(generated.cover.base64);
    expect(jpg.length, lessThan(BookDefinition.maxCoverBytes));
    final withCover = book.copyWith(
      coverMime: generated.cover.mime, coverBase64: generated.cover.base64);
    withCover.validate();
    expect(BookDefinition.importJson(withCover.exportJson()).coverMime,
      'image/jpeg');
  });

  test('Missing API configuration refuses before any paid call', () async {
    final fake = _FakeCoverProvider();
    final generator = BookCoverGenerator(providerFactory: (_) => fake);
    await expectLater(generator.generate(
      book: book,
      connection: const ImageGenerationOptions(),
      profiles: const [],
    ), throwsA(isA<ImageGenerationFailure>()));
    expect(fake.generations, 0);
    expect(fake.catalogs, 0);
  });

  test('Unknown spending cap blocks cover before paid POST', () async {
    final fake = _FakeCoverProvider();
    final generator = BookCoverGenerator(providerFactory: (_) => fake);
    await expectLater(generator.generate(
      book: book.copyWith(illustrationSettings:
        book.illustrationSettings.copyWith(maximumCostUsd: 0.01)),
      connection: const ImageGenerationOptions(
        profileId: 'image', model: 'visual-model'),
      profiles: [profile],
    ), throwsA(isA<ImageGenerationFailure>()));
    expect(fake.generations, 0);
    expect(fake.catalogs, 1);
  });

  test('Corrupted cover input is rejected without attaching to Book', () {
    expect(() => BookCoverGenerator.convertToPortableCover(
      Uint8List.fromList([0, 1, 2, 3])), throwsFormatException);
  });

  test('Book settings serialize and validate independently of API config', () {
    final imported = BookDefinition.importJson(book.exportJson());
    expect(imported.illustrationSettings.negativePrompt,
      'texte, bulles, filigranes');
    expect(imported.illustrationSettings.count, 1);
    expect(() => book.copyWith(illustrationSettings:
      book.illustrationSettings.copyWith(count: 5)).validate(),
      throwsFormatException);
  });
}
