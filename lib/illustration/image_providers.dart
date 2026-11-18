// ignore_for_file: prefer_interpolation_to_compose_strings, curly_braces_in_flow_control_structures
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../ai/ai_diagnostics.dart';

/// Images are intentionally separate from text completions and ChatGPT OAuth.
/// The caller supplies a personal API key from an existing encrypted profile.
abstract interface class ImageGenerationProvider {
  String get id;
  Future<List<ImageModelCapability>> listModels(String apiKey);
  Future<ImageGenerationResult> generate(ImageGenerationRequest request,
      {required String apiKey});
}

class ImageModelCapability {
  const ImageModelCapability({
    required this.id,
    required this.sizes,
    this.qualities = const [],
    this.maximumImages = 1,
    this.estimatedUnitCostUsd,
  });
  final String id;
  final List<String> sizes;
  final List<String> qualities;
  final int maximumImages;
  /// Null when a precise, provider-backed upper bound cannot be guaranteed.
  final double? estimatedUnitCostUsd;
}

/// Automatic default is selected from the live provider catalogue.
ImageModelCapability selectImageModel(
    List<ImageModelCapability> models, String requestedId) {
  if (requestedId.isNotEmpty) {
    for (final model in models) {
      if (model.id == requestedId) return model;
    }
    throw const ImageGenerationFailure(ImageFailureKind.unsupported,
        'Modèle graphique indisponible. Choisissez un autre modèle.');
  }
  for (final preferred in const [
    'z-image-turbo', 'lustify-v8', 'qwen-image-3-uncensored',
  ]) {
    for (final model in models) {
      if (model.id == preferred) return model;
    }
  }
  if (models.isNotEmpty) return models.first;
  throw const ImageGenerationFailure(ImageFailureKind.unavailable,
      'Aucun modèle graphique disponible actuellement.');
}

class ImageGenerationRequest {
  const ImageGenerationRequest({
    required this.model,
    required this.prompt,
    this.size = '1024x1024',
    this.quality,
    this.count = 1,
  });
  final String model, prompt, size;
  final String? quality;
  final int count;
}

class GeneratedImage {
  const GeneratedImage(this.bytes, this.mimeType);
  final Uint8List bytes;
  final String mimeType;
}

class ImageGenerationResult {
  const ImageGenerationResult({
    required this.images, required this.provider, required this.model,
    this.costUsd,
  });
  final List<GeneratedImage> images;
  final String provider, model;
  /// Reported by the provider, never inferred from a promotional price.
  final double? costUsd;
}

enum ImageFailureKind {
  authentication, credits, refused, unavailable, timeout, invalidResponse,
  unsupported, tooLarge,
}

class ImageGenerationFailure implements Exception {
  const ImageGenerationFailure(this.kind, this.message);
  final ImageFailureKind kind;
  final String message;
  @override
  String toString() => message;
}

abstract class _HttpImageProvider implements ImageGenerationProvider {
  _HttpImageProvider(this._client, this._origin, {
    this.diagnostics, this.onExchangeCaptured, this.playerEventId,
  });
  final http.Client _client;
  final Uri _origin;
  final AiExchangeRecorder? diagnostics;
  final void Function(AiExchange)? onExchangeCaptured;
  final int? playerEventId;

  /// Never persist response-embedded base64 images, temporary URLs or
  /// upstream free-form error text. Keep only bounded metadata needed to
  /// diagnose the exchange and its billing.
  Map<String, dynamic> _safeResponseMetadata(
      Map<String, dynamic>? data, String path, int bytes) {
    final images = data?['data'];
    final models = data?['models'] ?? images;
    final ou = data?['ou'];
    final usage = data?['usage'];
    final error = data?['error'];
    final code = error is Map ? error['code'] : null;
    final safeCode = code is String &&
            RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(code)
        ? code : null;
    return {
      'imagePayloadRedacted': true,
      'actualResponseBytes': bytes,
      if (path == 'images/generations' && images is List)
        'imageCount': images.length,
      if (path == 'images/models' && models is List)
        'modelCount': models.length,
      if (ou is Map && ou['cost_usd'] is num)
        'ou': {'cost_usd': ou['cost_usd']},
      if (usage is Map && usage['prompt_tokens'] is int &&
          usage['completion_tokens'] is int)
        'usage': {
          'prompt_tokens': usage['prompt_tokens'],
          'completion_tokens': usage['completion_tokens'],
        },
      if (safeCode != null) 'errorCode': safeCode,
    };
  }

  Future<Map<String, dynamic>> _json(
    String method, String path, String key, [Map<String, dynamic>? body]
  ) async {
    if (key.trim().isEmpty) {
      throw const ImageGenerationFailure(
          ImageFailureKind.authentication, 'Clé API absente.');
    }
    final request = http.Request(method, _origin.resolve(path));
    request.headers['Authorization'] = 'Bearer $key';
    request.headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final exchange = diagnostics?.begin(
      provider: id,
      method: request.method,
      url: request.url.toString(),
      requestBody: request.body,
      secret: key.trim(),
      accept: 'application/json',
    );
    if (exchange != null) {
      exchange.stage = path == 'images/models'
          ? 'image_catalog' : 'image_generation';
      exchange.playerEventId = playerEventId;
    }

    Object? failure;
    try {
      http.StreamedResponse response;
      try {
        response = await _client.send(request).timeout(
            const Duration(minutes: 5));
        exchange?.statusCode = response.statusCode;
      } on ImageGenerationFailure {
        rethrow;
      } catch (_) {
        throw const ImageGenerationFailure(
            ImageFailureKind.timeout, 'Connexion interrompue ou délai dépassé.');
      }
      // A large JSON response is expected for base64 images, but not unlimited.
      const maxResponseBytes = 48 * 1024 * 1024;
      final buffer = BytesBuilder(copy: false);
      try {
        await for (final chunk in response.stream.timeout(
            const Duration(minutes: 5))) {
          if (buffer.length + chunk.length > maxResponseBytes) {
            throw const ImageGenerationFailure(
                ImageFailureKind.tooLarge, 'Réponse image trop volumineuse.');
          }
          buffer.add(chunk);
        }
      } on ImageGenerationFailure {
        rethrow;
      } catch (_) {
        throw const ImageGenerationFailure(
            ImageFailureKind.timeout, 'Téléchargement image interrompu.');
      }
      final bytes = buffer.takeBytes();
      Map<String, dynamic>? parsed;
      try {
        final data = jsonDecode(utf8.decode(bytes));
        if (data is Map<String, dynamic>) parsed = data;
      } catch (_) {
        // Do not export malformed or private upstream response data.
      }
      exchange?.addRedactedResponseSummary(
        _safeResponseMetadata(parsed, path, bytes.length),
        actualBytes: bytes.length,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final code = response.statusCode;
        final kind = switch (code) {
          401 || 403 => ImageFailureKind.authentication,
          402 => ImageFailureKind.credits,
          400 || 422 || 451 => ImageFailureKind.refused,
          _ => ImageFailureKind.unavailable,
        };
        throw ImageGenerationFailure(kind, switch (kind) {
          ImageFailureKind.authentication => 'Clé API invalide ou non autorisée.',
          ImageFailureKind.credits => 'Crédits insuffisants.',
          ImageFailureKind.refused => 'Image refusée par le fournisseur.',
          _ => 'Fournisseur d’images indisponible (HTTP $code).',
        });
      }
      if (parsed != null) return parsed;
      throw const ImageGenerationFailure(
          ImageFailureKind.invalidResponse, 'Réponse du fournisseur invalide.');
    } catch (error) {
      failure = error;
      rethrow;
    } finally {
      if (exchange != null) {
        exchange.complete(error: failure?.toString());
        try {
          onExchangeCaptured?.call(exchange);
        } catch (_) {
          // Diagnostic storage never changes a billed image outcome.
        }
      }
    }
  }

  Future<List<GeneratedImage>> _decodeImages(Map<String, dynamic> data) async {
    final entries = data['data'];
    if (entries is! List || entries.isEmpty || entries.length > 10) {
      throw const ImageGenerationFailure(
          ImageFailureKind.invalidResponse, 'Aucune image dans la réponse.');
    }
    final images = <GeneratedImage>[];
    for (final entry in entries) {
      if (entry is! Map<String, dynamic>) {
        throw const ImageGenerationFailure(
            ImageFailureKind.invalidResponse, 'Format d’image invalide.');
      }
      final base64Text = entry['b64_json'];
      if (base64Text is String) {
        images.add(_decodeBase64(base64Text));
        continue;
      }
      final url = entry['url'];
      if (url is! String || url.length > 8192) {
        throw const ImageGenerationFailure(
            ImageFailureKind.invalidResponse, 'Image absente ou URL invalide.');
      }
      if (url.startsWith('data:image/')) {
        final separator = url.indexOf(',');
        if (separator < 0 || !url.substring(0, separator).endsWith(';base64')) {
          throw const ImageGenerationFailure(
              ImageFailureKind.invalidResponse, 'URL data invalide.');
        }
        images.add(_decodeBase64(url.substring(separator + 1)));
        continue;
      }
      final uri = Uri.tryParse(url);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty ||
          uri.userInfo.isNotEmpty || _privateHost(uri.host)) {
        throw const ImageGenerationFailure(
            ImageFailureKind.invalidResponse, 'URL image non sécurisée.');
      }
      http.StreamedResponse downloaded;
      try {
        downloaded = await _client.send(http.Request('GET', uri))
            .timeout(const Duration(minutes: 5));
      } catch (_) {
        throw const ImageGenerationFailure(
            ImageFailureKind.timeout, 'Téléchargement image impossible.');
      }
      if (downloaded.statusCode != 200) {
        throw const ImageGenerationFailure(
            ImageFailureKind.unavailable, 'Image distante expirée.');
      }
      final buffer = BytesBuilder(copy: false);
      try {
        await for (final chunk in downloaded.stream.timeout(
            const Duration(minutes: 5))) {
          if (buffer.length + chunk.length > 16 * 1024 * 1024) {
            throw const ImageGenerationFailure(
                ImageFailureKind.tooLarge, 'Image distante trop volumineuse.');
          }
          buffer.add(chunk);
        }
      } on ImageGenerationFailure {
        rethrow;
      } catch (_) {
        throw const ImageGenerationFailure(
            ImageFailureKind.timeout, 'Téléchargement image interrompu.');
      }
      images.add(_checkedImage(buffer.takeBytes()));
    }
    return images;
  }

  static bool _privateHost(String host) {
    final lower = host.toLowerCase();
    if (lower == 'localhost' || lower.endsWith('.local') ||
        lower.endsWith('.internal')) return true;
    final address = Uri.tryParse('https://$lower');
    if (address == null) return true;
    if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(lower) ||
        lower.contains(':')) return true;
    return false;
  }

  static GeneratedImage _decodeBase64(String raw) {
    if (raw.length > 22 * 1024 * 1024) {
      throw const ImageGenerationFailure(
          ImageFailureKind.tooLarge, 'Image encodée trop volumineuse.');
    }
    try {
      return _checkedImage(base64Decode(raw));
    } catch (error) {
      if (error is ImageGenerationFailure) rethrow;
      throw const ImageGenerationFailure(
          ImageFailureKind.invalidResponse, 'Image base64 corrompue.');
    }
  }

  static GeneratedImage _checkedImage(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > 16 * 1024 * 1024) {
      throw const ImageGenerationFailure(
          ImageFailureKind.tooLarge, 'Taille d’image invalide.');
    }
    if (bytes.length >= 8 &&
        bytes[0] == 137 && bytes[1] == 80 && bytes[2] == 78 &&
        bytes[3] == 71) {
      return GeneratedImage(bytes, 'image/png');
    }
    if (bytes.length >= 3 && bytes[0] == 255 && bytes[1] == 216 &&
        bytes[2] == 255) return GeneratedImage(bytes, 'image/jpeg');
    if (bytes.length >= 12 && ascii.decode(bytes.sublist(0, 4)) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12)) == 'WEBP') {
      return GeneratedImage(bytes, 'image/webp');
    }
    throw const ImageGenerationFailure(
        ImageFailureKind.unsupported, 'Format d’image non pris en charge.');
  }

  void _validate(ImageGenerationRequest request, ImageModelCapability model) {
    if (request.model != model.id ||
        !model.sizes.contains(request.size) ||
        request.count < 1 || request.count > model.maximumImages ||
        (request.quality != null &&
         !model.qualities.contains(request.quality)) ||
        request.prompt.trim().isEmpty || request.prompt.length > 8000) {
      throw const ImageGenerationFailure(
          ImageFailureKind.unsupported, 'Options graphiques incompatibles.');
    }
  }
}

class OpenAiImageGenerationProvider extends _HttpImageProvider {
  OpenAiImageGenerationProvider({
    http.Client? client,
    AiExchangeRecorder? diagnostics,
    void Function(AiExchange)? onExchangeCaptured,
    int? playerEventId,
  }) : super(client ?? http.Client(), Uri.parse('https://api.openai.com/v1/'),
          diagnostics: diagnostics, onExchangeCaptured: onExchangeCaptured,
          playerEventId: playerEventId);
  @override
  String get id => 'openai';

  static const modelIds = [
    'gpt-image-2', 'gpt-image-2.5-sunburst', 'gpt-image-2.5-flare',
    'gpt-image-2.6-sunburst', 'gpt-image-2.6-flare',
  ];
  @override
  Future<List<ImageModelCapability>> listModels(String apiKey) async =>
      [for (final id in modelIds) _capability(id)];

  static ImageModelCapability _capability(String id) => ImageModelCapability(
    id: id,
    sizes: const ['1024x1024', '1536x1024', '1024x1536'],
    qualities: id.startsWith('gpt-image-2.5-')
        ? const ['low','medium','high','xhigh','max']
        : const ['low','medium','high'],
    maximumImages: 4,
  );

  @override
  Future<ImageGenerationResult> generate(ImageGenerationRequest request,
      {required String apiKey}) async {
    if (!modelIds.contains(request.model)) {
      throw const ImageGenerationFailure(
          ImageFailureKind.unsupported, 'Modèle GPT Image inconnu.');
    }
    _validate(request, _capability(request.model));
    final data = await _json('POST', 'images/generations', apiKey, {
      'model': request.model,
      'prompt': request.prompt,
      'size': request.size,
      'n': request.count,
      if (request.quality != null) 'quality': request.quality,
      'output_format': 'png',
    });
    return ImageGenerationResult(
      images: await _decodeImages(data), provider: id, model: request.model,
    );
  }
}

class OpenUncensoredImageGenerationProvider extends _HttpImageProvider {
  OpenUncensoredImageGenerationProvider({
    http.Client? client,
    AiExchangeRecorder? diagnostics,
    void Function(AiExchange)? onExchangeCaptured,
    int? playerEventId,
  }) : super(client ?? http.Client(),
          Uri.parse('https://api.openuncensored.com/v1/'),
          diagnostics: diagnostics, onExchangeCaptured: onExchangeCaptured,
          playerEventId: playerEventId);
  @override
  String get id => 'openuncensored';

  @override
  Future<List<ImageModelCapability>> listModels(String apiKey) async {
    final body = await _json('GET', 'images/models', apiKey);
    final raw = body['data'] ?? body['models'];
    if (raw is! List) {
      throw const ImageGenerationFailure(
          ImageFailureKind.invalidResponse, 'Catalogue graphique invalide.');
    }
    return [
      for (final entry in raw)
        if (entry is Map<String, dynamic> && entry['id'] is String &&
            (entry['operations'] is! List ||
                (entry['operations'] as List).contains('generate')))
          ImageModelCapability(
            id: entry['id'] as String,
            sizes: const [
              '1024x1024','1024x1536','1536x1024',
              '1024x1792','1792x1024','512x512','auto',
            ],
            maximumImages: 4,
            // Cheapest-route prices are NOT spending caps.
          ),
    ];
  }

  @override
  Future<ImageGenerationResult> generate(ImageGenerationRequest request,
      {required String apiKey}) async {
    // The live catalogue is queried before any paid image operation.
    final catalogue = await listModels(apiKey);
    final models = catalogue.where((m) => m.id == request.model);
    if (models.isEmpty) {
      throw const ImageGenerationFailure(
          ImageFailureKind.unsupported, 'Modèle graphique indisponible.');
    }
    _validate(request, models.first);
    final data = await _json('POST', 'images/generations', apiKey, {
      'model': request.model,
      'prompt': request.prompt,
      'size': request.size,
      'n': request.count,
      'response_format': 'b64_json',
    });
    final ou = data['ou'];
    final cost = ou is Map<String, dynamic> ? ou['cost_usd'] : null;
    return ImageGenerationResult(
      images: await _decodeImages(data), provider: id, model: request.model,
      costUsd: cost is num && cost >= 0 ? cost.toDouble() : null,
    );
  }
}
