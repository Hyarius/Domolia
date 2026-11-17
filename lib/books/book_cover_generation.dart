// ignore_for_file: prefer_interpolation_to_compose_strings
import 'dart:convert';
import 'dart:math';

import 'package:image/image.dart' as img;

import '../ai/ai_controller.dart';
import '../ai/ai_provider.dart';
import '../illustration/image_preferences.dart';
import '../illustration/image_providers.dart';
import 'book_cover_loader.dart';
import 'book_definition.dart';

typedef CoverImageProviderFactory = ImageGenerationProvider Function(String id);

class GeneratedBookCover {
  const GeneratedBookCover({
    required this.cover,
    required this.provider,
    required this.model,
    this.costUsd,
  });
  final BookCoverData cover;
  final String provider, model;
  final double? costUsd;
}

/// One explicit paid image call; the generated image is converted to a
/// portable, bounded JPEG before it is attached to the Book.
class BookCoverGenerator {
  const BookCoverGenerator({this.providerFactory});
  final CoverImageProviderFactory? providerFactory;

  static String _providerId(AiProfile profile) {
    if (profile.kind != AiProviderKind.customAi ||
        profile.apiKey.trim().isEmpty) {
      throw const ImageGenerationFailure(ImageFailureKind.authentication,
          'Configurez une clé API graphique dans les réglages IA.');
    }
    final uri = Uri.tryParse(profile.baseUrl);
    if (uri?.scheme != 'https') {
      throw const ImageGenerationFailure(ImageFailureKind.unsupported,
          'Adresse du fournisseur d’images invalide.');
    }
    if (uri!.host == 'api.openai.com') return 'openai';
    if (uri.host == 'api.openuncensored.com' ||
        uri.host == 'openuncensored.com') return 'openuncensored';
    throw const ImageGenerationFailure(ImageFailureKind.unsupported,
        'Utilisez un profil API OpenAI ou OpenUncensored.');
  }

  static String buildPrompt(BookDefinition book) {
    final art = book.illustrationSettings;
    art.validate();
    String excerpt(String text, [int max = 650]) =>
        text.length <= max ? text : text.substring(0, max);
    final global = book.lore.global;
    return [
      'Créer une illustration originale pour la couverture d’un livre '
          'de fiction. Composition verticale, une seule image, '
          'scène visuelle cohérente et attrayante. '
          'Aucune typographie, ni titre, ni texte sur l’image.',
      'Titre du Livre (contexte uniquement, NE PAS dessiner les mots) : ' +
          book.title,
      'Univers : ' + excerpt(global.universe),
      'Genre : ' + excerpt(global.genre),
      'Époque : ' + excerpt(global.era),
      'Atmosphère et contexte initial : ' + excerpt(global.overview),
      'Style artistique : ' + art.style,
      if (art.negativePrompt.trim().isNotEmpty)
        'EXCLUSIONS VISUELLES : ' + art.negativePrompt.trim(),
      'Ne pas représenter les secrets, révélations futures ou événements '
          'non établis par le Livre. Aucun logo ni filigrane.',
    ].join('\n');
  }

  Future<GeneratedBookCover> generate({
    required BookDefinition book,
    required ImageGenerationOptions connection,
    required Iterable<AiProfile> profiles,
  }) async {
    connection.validate();
    book.validate();
    if (connection.profileId.isEmpty || connection.model.isEmpty) {
      throw const ImageGenerationFailure(ImageFailureKind.unsupported,
          'Génération d’image non configurée : choisissez un profil '
          'graphique et un modèle dans les réglages IA.');
    }
    final matches = profiles.where((p) => p.id == connection.profileId);
    if (matches.isEmpty) {
      throw const ImageGenerationFailure(ImageFailureKind.unsupported,
          'Profil graphique introuvable. Ouvrez les réglages IA.');
    }
    final profile = matches.first;
    final providerId = _providerId(profile);
    final provider = providerFactory?.call(providerId) ??
        (providerId == 'openai'
          ? OpenAiImageGenerationProvider()
          : OpenUncensoredImageGenerationProvider());
    final catalog = await provider.listModels(profile.apiKey);
    final available = catalog.where((m) => m.id == connection.model);
    if (available.isEmpty) {
      throw const ImageGenerationFailure(ImageFailureKind.unsupported,
          'Modèle graphique indisponible pour cette couverture.');
    }
    final capability = available.first;
    // Portrait first; fall back only to a supported format, never silently
    // send an invalid size or quality to a paid API.
    const portrait = ['1024x1536', '1024x1792', 'auto', '1024x1024'];
    final sizes = portrait.where((size) =>
        capability.sizes.contains(size)).toList();
    if (sizes.isEmpty) {
      throw const ImageGenerationFailure(ImageFailureKind.unsupported,
          'Ce modèle ne fournit pas de format pour les couvertures.');
    }
    final quality = book.illustrationSettings.quality;
    if (quality != null && !capability.qualities.contains(quality)) {
      throw const ImageGenerationFailure(ImageFailureKind.unsupported,
          'Qualité de couverture non prise en charge par ce modèle.');
    }
    final result = await provider.generate(ImageGenerationRequest(
      model: connection.model,
      prompt: buildPrompt(book),
      size: sizes.first,
      quality: quality,
      count: 1,
    ), apiKey: profile.apiKey);
    if (result.images.isEmpty) {
      throw const ImageGenerationFailure(ImageFailureKind.invalidResponse,
          'Le fournisseur n’a renvoyé aucune couverture.');
    }
    final cover = convertToPortableCover(result.images.first.bytes);
    return GeneratedBookCover(
      cover: cover, provider: providerId, model: connection.model,
      costUsd: result.costUsd);
  }

  /// Generated 1–10 MB images are converted to JPEG under the Book's 1 MB
  /// limit. Decode and reencode so the portable file never contains
  /// provider-specific metadata, and prevent oversized pixel buffers.
  static BookCoverData convertToPortableCover(List<int> input) {
    if (input.isEmpty || input.length > 16 * 1024 * 1024) {
      throw const FormatException('Couverture générée trop volumineuse.');
    }
    final original = img.decodeImage(input);
    if (original == null || original.width < 1 || original.height < 1 ||
        original.width * original.height > 40 * 1024 * 1024) {
      throw const FormatException('Image de couverture illisible.');
    }
    var maxWidth = 1024;
    var maxHeight = 1536;
    for (var attempt = 0; attempt < 4; attempt++) {
      final scale = min(1.0, min(maxWidth / original.width,
          maxHeight / original.height));
      final sized = scale >= 1
          ? original
          : img.copyResize(original,
              width: max(1, (original.width * scale).round()),
              height: max(1, (original.height * scale).round()));
      for (final quality in const [88, 78, 68, 56]) {
        final data = img.encodeJpg(sized, quality: quality);
        if (data.isNotEmpty && data.length <= BookDefinition.maxCoverBytes) {
          return BookCoverData('image/jpeg', base64Encode(data));
        }
      }
      maxWidth = max(320, (maxWidth * 0.75).round());
      maxHeight = max(480, (maxHeight * 0.75).round());
    }
    throw const FormatException('Impossible de compresser la couverture sous 1 Mo.');
  }
}
