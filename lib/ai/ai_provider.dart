import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

const defaultAiBaseUrl = 'https://api.openuncensored.com/v1';
const defaultAiModel = 'deepseek-v4.1-flash-1017-uncensored';

/// A transport-independent configuration. It must never be logged or included
/// in exception messages because it contains the user's private API key.
class AiConfiguration {
  const AiConfiguration({
    required this.baseUrl,
    required this.model,
    required this.apiKey,
  });

  final String baseUrl;
  final String model;
  final String apiKey;
}

/// A named, locally stored connection. Each profile owns its API key.
class AiProfile {
  const AiProfile({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    required this.apiKey,
  });

  final String id;
  final String name;
  final String baseUrl;
  final String model;
  final String apiKey;

  AiConfiguration get configuration => AiConfiguration(
        baseUrl: baseUrl,
        model: model,
        apiKey: apiKey,
      );

  AiProfile copyWith({
    String? name,
    String? baseUrl,
    String? model,
    String? apiKey,
  }) => AiProfile(
        id: id,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        model: model ?? this.model,
        apiKey: apiKey ?? this.apiKey,
      );
}

/// The selected profile ID and all credentials are committed atomically.
/// The production store persists this entire state in encrypted Android storage.
class AiProfilesState {
  const AiProfilesState({required this.profiles, required this.selectedId});

  final List<AiProfile> profiles;
  final String selectedId;
}

abstract interface class AiProfileStore {
  Future<AiProfilesState?> read();
  Future<void> write(AiProfilesState state);
}

class AiMessage {
  const AiMessage({required this.role, required this.content});
  final String role;
  final String content;
}

class AiModel {
  const AiModel(this.id);
  final String id;
}

/// The future RP layer depends on this contract, not on OpenUncensored or HTTP.
abstract interface class AiChatProvider {
  Future<List<AiModel>> listModels(AiConfiguration configuration);
  Future<String> complete(
    AiConfiguration configuration, {
    required List<AiMessage> messages,
    int maxTokens,
  });
}

class AiProviderException implements Exception {
  const AiProviderException(this.userMessage);
  final String userMessage;

  @override
  String toString() => userMessage;
}

/// Accept only TLS endpoints; never send a bearer token over HTTP.
String validatedAiBaseUrl(String value) {
  final normalized = value.trim().replaceFirst(RegExp(r'/+$'), '');
  final uri = Uri.tryParse(normalized);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const AiProviderException(
      'Indiquez une URL HTTPS valide, sans paramètres ni identifiants.',
    );
  }
  return normalized;
}

String validatedAiModel(String value) {
  final model = value.trim();
  if (model.isEmpty || model.length > 160 || model.contains(RegExp(r'[\r\n]'))) {
    throw const AiProviderException('Indiquez un identifiant de modèle valide.');
  }
  return model;
}

class OpenAiCompatibleChatProvider implements AiChatProvider {
  OpenAiCompatibleChatProvider({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;

  Future<dynamic> _request(
    AiConfiguration configuration,
    String path, {
    Object? payload,
  }) async {
    if (configuration.apiKey.trim().isEmpty) {
      throw const AiProviderException('Renseignez votre clé API avant de continuer.');
    }
    final base = validatedAiBaseUrl(configuration.baseUrl);
    final endpoint = Uri.parse('$base/$path');
    final request = http.Request(payload == null ? 'GET' : 'POST', endpoint)
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer ${configuration.apiKey.trim()}'
      ..headers['Accept'] = 'application/json';
    if (payload != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(payload);
    }

    http.Response response;
    try {
      final streamed = await _client.send(request).timeout(const Duration(seconds: 25));
      response = await http.Response.fromStream(streamed).timeout(
        const Duration(seconds: 65),
      );
    } on TimeoutException {
      throw const AiProviderException('Le fournisseur IA ne répond pas à temps.');
    } catch (_) {
      // Never surface HTTP exception bodies, URLs or Authorization headers.
      throw const AiProviderException(
        'Connexion au fournisseur impossible. Vérifiez votre réseau et l’URL.',
      );
    }

    if (response.statusCode != 200) {
      switch (response.statusCode) {
        case 401:
        case 403:
          throw const AiProviderException('Clé API refusée. Vérifiez votre clé.');
        case 402:
          throw const AiProviderException('Crédits du fournisseur insuffisants.');
        case 404:
          throw const AiProviderException('Modèle ou point d’accès introuvable.');
        case 408:
        case 504:
          throw const AiProviderException('Délai de réponse du fournisseur dépassé.');
        case 429:
          throw const AiProviderException('Limite de débit atteinte. Réessayez plus tard.');
        default:
          throw AiProviderException(
            'Le fournisseur IA a retourné une erreur HTTP ${response.statusCode}.',
          );
      }
    }
    if (response.bodyBytes.length > 2 * 1024 * 1024) {
      throw const AiProviderException('Réponse du fournisseur trop volumineuse.');
    }
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw const AiProviderException('Réponse JSON invalide du fournisseur IA.');
    }
  }

  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async {
    final result = await _request(configuration, 'models');
    if (result is! Map<String, dynamic> || result['data'] is! List) {
      throw const AiProviderException('Catalogue de modèles invalide.');
    }
    final ids = <String>{};
    for (final item in result['data'] as List) {
      if (item is Map<String, dynamic> &&
          item['id'] is String &&
          item['available'] != false &&
          (item['modality'] == null || item['modality'] == 'text')) {
        final id = item['id'] as String;
        if (id.isNotEmpty) ids.add(id);
      }
    }
    return (ids.toList()..sort()).map(AiModel.new).toList();
  }

  @override
  Future<String> complete(
    AiConfiguration configuration, {
    required List<AiMessage> messages,
    int maxTokens = 64,
  }) async {
    validatedAiModel(configuration.model);
    if (messages.isEmpty ||
        messages.any((message) =>
            !{'system', 'user', 'assistant'}.contains(message.role) ||
            message.content.trim().isEmpty)) {
      throw const AiProviderException('Messages de chat invalides.');
    }
    if (maxTokens < 1 || maxTokens > 8192) {
      throw const AiProviderException('Limite de tokens invalide.');
    }
    final response = await _request(configuration, 'chat/completions', payload: {
      'model': configuration.model.trim(),
      'stream': false,
      'max_tokens': maxTokens,
      'messages': [
        for (final message in messages)
          {'role': message.role, 'content': message.content},
      ],
    });
    if (response is! Map<String, dynamic> ||
        response['choices'] is! List ||
        (response['choices'] as List).isEmpty) {
      throw const AiProviderException('Réponse de chat vide ou invalide.');
    }
    final choice = (response['choices'] as List).first;
    if (choice is! Map<String, dynamic> ||
        choice['message'] is! Map<String, dynamic> ||
        (choice['message'] as Map<String, dynamic>)['content'] is! String) {
      throw const AiProviderException('Réponse de chat invalide.');
    }
    final content = ((choice['message'] as Map<String, dynamic>)['content'] as String).trim();
    if (content.isEmpty) {
      throw const AiProviderException('Le modèle a retourné une réponse vide.');
    }
    return content;
  }
}
