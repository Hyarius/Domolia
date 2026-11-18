import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_diagnostics.dart';

const defaultAiBaseUrl = 'https://api.openuncensored.com/v1';
const defaultAiModel = 'deepseek-v4.1-flash-1017-uncensored';

/// A transport-independent configuration. It must never be logged or included
/// in exception messages because it contains the user's private API key.
class AiConfiguration {
  const AiConfiguration({
    required this.baseUrl,
    required this.model,
    required this.apiKey,
    this.reasoningEffort,
  });

  final String baseUrl;
  final String model;
  final String apiKey;
  /// Optional Responses API knob; ignored by generic Chat Completions.
  final String? reasoningEffort;

  AiConfiguration withReasoning(String? effort) => AiConfiguration(
    baseUrl: baseUrl, model: model, apiKey: apiKey, reasoningEffort: effort,
  );
}

/// A named, locally stored connection. Each profile owns its API key.
enum AiProviderKind { chatGpt, customAi }

/// Declared provider capability; never inferred from a model name.
enum AiNsfwCompatibility { supported, unsupported, unknown }

/// Explicit declaration for this *profile/model*, not its API provider.
enum AiToolCallingCompatibility { supported, unsupported, unknown }

class AiProfile {
  const AiProfile({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    required this.apiKey,
    this.kind = AiProviderKind.customAi,
    this.nsfwCompatibility = AiNsfwCompatibility.unknown,
    this.toolCallingCompatibility = AiToolCallingCompatibility.unknown,
  });

  final AiProviderKind kind;
  final AiNsfwCompatibility nsfwCompatibility;
  final AiToolCallingCompatibility toolCallingCompatibility;
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
    AiProviderKind? kind,
    AiNsfwCompatibility? nsfwCompatibility,
    AiToolCallingCompatibility? toolCallingCompatibility,
    String? name,
    String? baseUrl,
    String? model,
    String? apiKey,
  }) => AiProfile(
        kind: kind ?? this.kind,
        nsfwCompatibility: nsfwCompatibility ?? this.nsfwCompatibility,
        toolCallingCompatibility: toolCallingCompatibility ?? this.toolCallingCompatibility,
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


class AiStreamChunk {
  const AiStreamChunk({
    this.text = '',
    this.promptTokens,
    this.completionTokens,
  });

  final String text;
  final int? promptTokens;
  final int? completionTokens;
}

/// Optional capability: providers without streaming can still use complete().
abstract interface class AiStreamingChatProvider {
  Stream<AiStreamChunk> streamChat(
    AiConfiguration configuration, {
    required List<AiMessage> messages,
    int maxTokens,
  });
}

/// Native Chat Completions tool protocol. Results never become narrative text.
class AiToolDefinition {
  const AiToolDefinition(this.name, this.description, this.parameters);
  final String name;
  final String description;
  final Map<String, dynamic> parameters;
  Map<String, dynamic> toJson() => {
    'type': 'function',
    'function': {
      'name': name, 'description': description, 'parameters': parameters,
    },
  };
}

class AiToolInvocation {
  const AiToolInvocation({
    required this.id, required this.name, required this.arguments,
  });
  final String id;
  final String name;
  final String arguments;

  Map<String, dynamic> toJson() => {
    'id': id, 'type': 'function',
    'function': {'name': name, 'arguments': arguments},
  };
}

class AiToolMessage {
  const AiToolMessage({
    required this.role, this.content = '', this.calls = const [],
    this.toolCallId,
  });
  final String role;
  final String content;
  final List<AiToolInvocation> calls;
  final String? toolCallId;

  Map<String, dynamic> toJson() {
    if (role == 'tool') {
      if (toolCallId == null) throw const FormatException('Tool ID missing.');
      return {'role': 'tool', 'tool_call_id': toolCallId, 'content': content};
    }
    if (calls.isNotEmpty) {
      if (role != 'assistant') throw const FormatException('Invalid tool role.');
      return {'role': role, 'content': content.isEmpty ? null : content,
        'tool_calls': calls.map((call) => call.toJson()).toList()};
    }
    if (!{'system', 'user', 'assistant'}.contains(role)) {
      throw const FormatException('Invalid role.');
    }
    return {'role': role, 'content': content};
  }
}

class AiToolStreamChunk {
  const AiToolStreamChunk({
    this.text = '', this.callIndex, this.callId,
    this.callName, this.argumentsDelta, this.finishReason,
    this.promptTokens, this.completionTokens,
  });
  final String text;
  final int? callIndex;
  final String? callId;
  final String? callName;
  final String? argumentsDelta;
  final String? finishReason;
  final int? promptTokens;
  final int? completionTokens;
}

/// Implemented only by transports supporting native streamed Chat Completions.
abstract interface class AiToolCallingChatProvider {
  Stream<AiToolStreamChunk> streamToolChat(
    AiConfiguration configuration, {
    required List<AiToolMessage> messages,
    required List<AiToolDefinition> tools,
    int maxTokens,
  });
}

class AiToolsUnsupportedException extends AiProviderException {
  const AiToolsUnsupportedException()
      : super('Ce modèle refuse les paramètres de Tool Calling.');
}

enum AiProviderErrorKind { network, timeout, access, credits, rateLimit, refused, provider }

extension AiProviderErrorDescription on AiProviderErrorKind {
  String get label => switch (this) {
    AiProviderErrorKind.network => 'Connexion réseau',
    AiProviderErrorKind.timeout => 'Délai d’attente',
    AiProviderErrorKind.access => 'Accès au fournisseur',
    AiProviderErrorKind.credits => 'Crédits insuffisants',
    AiProviderErrorKind.rateLimit => 'Limite de débit',
    AiProviderErrorKind.refused => 'Demande refusée',
    AiProviderErrorKind.provider => 'Erreur du fournisseur',
  };
}

class AiProviderException implements Exception {
  const AiProviderException(this.userMessage, {
    this.kind = AiProviderErrorKind.provider,
  });

  final String userMessage;
  final AiProviderErrorKind kind;

  @override
  String toString() => userMessage;
}

/// A refusal is explicit only when the server sends a structured policy code.
/// Neither HTTP 403, network timeouts, nor the user's words prove moderation.
bool _isExplicitRefusal(Object? payload) {
  if (payload is! Map || payload['error'] is! Map) return false;
  final error = payload['error'] as Map;
  const codes = {
    'content_filter', 'content_policy_violation', 'policy_violation',
    'safety_violation', 'content_blocked', 'moderation_block',
  };
  return codes.contains(error['code']?.toString().toLowerCase()) ||
      codes.contains(error['type']?.toString().toLowerCase());
}

bool _isExplicitRefusalBody(List<int> bytes) {
  try {
    return bytes.isNotEmpty &&
        _isExplicitRefusal(jsonDecode(utf8.decode(bytes)));
  } catch (_) {
    return false;
  }
}

/// User-facing errors never contain upstream response bodies or credentials.
AiProviderException _httpFailure(int status, List<int> body) {
  if (_isExplicitRefusalBody(body)) {
    return const AiProviderException(
      'Le fournisseur a explicitement refusé la demande.',
      kind: AiProviderErrorKind.refused,
    );
  }
  switch (status) {
    case 401:
      return const AiProviderException(
        'Clé API refusée (HTTP 401). Vérifiez votre clé.',
        kind: AiProviderErrorKind.access,
      );
    case 403:
      return const AiProviderException(
        'Accès refusé (HTTP 403). Vérifiez les permissions du compte ou du modèle.',
        kind: AiProviderErrorKind.access,
      );
    case 402:
      return const AiProviderException(
        'Crédits insuffisants chez le fournisseur.',
        kind: AiProviderErrorKind.credits,
      );
    case 404:
      return const AiProviderException(
        'Modèle ou point d’accès introuvable (HTTP 404).',
        kind: AiProviderErrorKind.access,
      );
    case 408:
    case 504:
      return const AiProviderException(
        'Le fournisseur a signalé un délai dépassé (HTTP 408/504).',
        kind: AiProviderErrorKind.timeout,
      );
    case 429:
      return const AiProviderException(
        'Limite de débit atteinte (HTTP 429). Réessayez plus tard.',
        kind: AiProviderErrorKind.rateLimit,
      );
    case 451:
      return const AiProviderException(
        'Demande refusée par le fournisseur (HTTP 451).',
        kind: AiProviderErrorKind.refused,
      );
    default:
      return AiProviderException(
        'Le fournisseur IA a retourné une erreur HTTP $status.',
      );
  }
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

class OpenAiCompatibleChatProvider implements AiChatProvider, AiStreamingChatProvider, AiToolCallingChatProvider {
  OpenAiCompatibleChatProvider({http.Client? client, this.diagnostics})
      : _client = client ?? http.Client();

  final http.Client _client;
  final AiExchangeRecorder? diagnostics;

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

    final exchange = payload == null ? null : diagnostics?.begin(
      provider: 'openai-compatible',
      method: request.method,
      url: request.url.toString(),
      requestBody: request.body,
      secret: configuration.apiKey.trim(),
      accept: request.headers['Accept'] ?? 'application/json',
    );
    http.Response response;
    try {
      final streamed = await _client.send(request).timeout(const Duration(seconds: 25));
      response = await http.Response.fromStream(streamed).timeout(
        const Duration(seconds: 65),
      );
      exchange?.statusCode = response.statusCode;
      exchange?.addRawResponse(response.bodyBytes);
    } on TimeoutException {
      throw const AiProviderException(
        'Aucune réponse du fournisseur sous 25 s. Vérifiez le réseau ou réessayez.',
        kind: AiProviderErrorKind.timeout,
      );
    } catch (_) {
      // Never surface HTTP exception bodies, URLs or Authorization headers.
      throw const AiProviderException(
        'Connexion au fournisseur impossible. Vérifiez le réseau et l’URL.',
        kind: AiProviderErrorKind.network,
      );
    }

    if (response.statusCode != 200) {
      // Inspect at most 16 KB of structured upstream error data.
      final body = <int>[];
      try {
        await for (final bytes in response.stream.timeout(
            const Duration(seconds: 8))) {
          exchange?.addRawResponse(bytes);
          if (body.length < 16384) {
            body.addAll(bytes.take(16384 - body.length));
          }
          if (body.length >= 16384) break;
        }
      } catch (_) {
        // The HTTP status remains authoritative.
      }
      throw _httpFailure(response.statusCode, body);
    }

    var done = false;
    String? finishReason;
    var receivedText = 0;
    try {
      await for (final line in response.stream
          .map((bytes) {
            exchange?.addRawResponse(bytes);
            return bytes;
          })
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(seconds: 75))) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') {
          done = true;
          continue;
        }
        if (data.isEmpty || done) continue;
        if (data.length > 131072) {
          throw const AiProviderException('Flux du fournisseur trop volumineux.');
        }
        dynamic parsed;
        try {
          parsed = jsonDecode(data);
        } catch (_) {
          throw const AiProviderException('Flux IA mal formé.');
        }
        if (parsed is! Map<String, dynamic>) {
          throw const AiProviderException('Flux IA mal formé.');
        }
        if (parsed['error'] != null) {
          // HTTP 200 may still contain a structured upstream error.
          if (_isExplicitRefusal(parsed)) {
            throw const AiProviderException(
              'Le fournisseur a explicitement refusé la demande.',
              kind: AiProviderErrorKind.refused,
            );
          }
          throw const AiProviderException(
            'Le fournisseur a interrompu la génération. Réessayez.',
          );
        }
        final usage = parsed['usage'];
        if (usage is Map<String, dynamic>) {
          yield AiStreamChunk(
            promptTokens: usage['prompt_tokens'] is int
                ? usage['prompt_tokens'] as int : null,
            completionTokens: usage['completion_tokens'] is int
                ? usage['completion_tokens'] as int : null,
          );
        }
        final choices = parsed['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final first = choices.first;
        if (first is! Map<String, dynamic>) continue;
        if (first['finish_reason'] is String) {
          finishReason = first['finish_reason'] as String;
        }
        final delta = first['delta'];
        if (delta is! Map<String, dynamic>) continue;
        final text = delta['content'];
        if (text is String && text.isNotEmpty) {
          receivedText += text.length;
          if (receivedText > 131072) {
            throw const AiProviderException('Réponse du modèle trop longue.');
          }
          yield AiStreamChunk(text: text);
        }
      }
      if (!done) {
        throw const AiProviderException(
          'Le flux IA s’est interrompu avant la fin de la réponse.',
        );
      }
      if (finishReason == 'content_filter') {
        throw const AiProviderException(
          'Le fournisseur a filtré la réponse (content_filter).',
          kind: AiProviderErrorKind.refused,
        );
      }
      if (finishReason == 'length') {
        throw const AiProviderException(
          'La réponse du modèle a été tronquée par sa limite de sortie.',
        );
      }
    } on AiProviderException {
      rethrow;
    } on TimeoutException {
      throw const AiProviderException(
        'Le flux IA ne répond plus depuis 75 s.',
        kind: AiProviderErrorKind.timeout,
      );
    } catch (_) {
      throw const AiProviderException(
        'Connexion interrompue pendant la génération. Réessayez.',
        kind: AiProviderErrorKind.network,
      );
    }
  }

  /// Tool deltas are technical fragments. Only the orchestrator can validate
  /// and execute a fully received function call after a complete SSE stream.
  @override
  Stream<AiToolStreamChunk> streamToolChat(
    AiConfiguration configuration, {
    required List<AiToolMessage> messages,
    required List<AiToolDefinition> tools,
    int maxTokens = 2400,
  }) async* {
    validatedAiModel(configuration.model);
    if (configuration.apiKey.trim().isEmpty) {
      throw const AiProviderException('Renseignez une clé API.');
    }
    if (messages.isEmpty || maxTokens < 1 || maxTokens > 32768 ||
        tools.length > 8) {
      throw const AiProviderException('Requête Tool Calling invalide.');
    }
    final base = validatedAiBaseUrl(configuration.baseUrl);
    final request = http.Request('POST', Uri.parse('$base/chat/completions'))
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer ${configuration.apiKey.trim()}'
      ..headers['Accept'] = 'text/event-stream'
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'model': configuration.model.trim(),
        'stream': true,
        'stream_options': {'include_usage': true},
        'max_tokens': maxTokens,
        'messages': [for (final item in messages) item.toJson()],
        if (tools.isNotEmpty) 'tools': [
          for (final item in tools) item.toJson(),
        ],
        if (tools.isNotEmpty) 'tool_choice': 'auto',
      });
    final exchange = diagnostics?.begin(
      provider: 'openai-compatible', method: request.method,
      url: request.url.toString(), requestBody: request.body,
      secret: configuration.apiKey.trim(),
      accept: request.headers['Accept'] ?? 'text/event-stream',
    );
    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(const Duration(seconds: 25));
      exchange?.statusCode = response.statusCode;
    } on TimeoutException {
      throw const AiProviderException(
        'Aucune réponse du fournisseur sous 25 s. Vérifiez le réseau ou réessayez.',
        kind: AiProviderErrorKind.timeout,
      );
    } catch (_) {
      throw const AiProviderException(
        'Connexion au fournisseur impossible. Vérifiez le réseau et l’URL.',
        kind: AiProviderErrorKind.network,
      );
    }
    if (response.statusCode != 200) {
      // Inspect only the error classification. Never expose the upstream body.
      final body = <int>[];
      try {
        await for (final bytes in response.stream.timeout(
            const Duration(seconds: 8))) {
          exchange?.addRawResponse(bytes);
          if (body.length < 16384) {
            body.addAll(bytes.take(16384 - body.length));
          }
          if (body.length >= 16384) break;
        }
      } catch (_) { /* The status is still authoritative. */ }
      if (tools.isNotEmpty &&
          (response.statusCode == 400 || response.statusCode == 422)) {
        try {
          final parsed = jsonDecode(utf8.decode(body));
          final error = parsed is Map ? parsed['error'] : null;
          if (error is Map) {
            final param = error['param']?.toString().toLowerCase() ?? '';
            final code = error['code']?.toString().toLowerCase() ?? '';
            final message = error['message']?.toString().toLowerCase() ?? '';
            if (param == 'tools' || param == 'tool_choice' ||
                code.contains('unsupported_tool') ||
                message.contains('tool calling is not supported') ||
                message.contains('tools are not supported') ||
                message.contains('tool_choice is not supported')) {
              throw const AiToolsUnsupportedException();
            }
          }
        } on AiToolsUnsupportedException {
          rethrow;
        } catch (_) { /* Not an explicit incompatibility. */ }
      }
      throw _httpFailure(response.statusCode, body);
    }

    var done = false;
    String? finishReason;
    var totalBytes = 0;
    try {
      await for (final line in response.stream
        .map((bytes) {
          exchange?.addRawResponse(bytes);
          totalBytes += bytes.length;
          if (totalBytes > 2 * 1024 * 1024) {
            throw const AiProviderException('Flux IA trop volumineux.');
          }
          return bytes;
        })
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(const Duration(seconds: 75))) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data == '[DONE]') { done = true; continue; }
      if (done || data.isEmpty) continue;
      if (data.length > 131072) {
        throw const AiProviderException('Événement IA trop volumineux.');
      }
      dynamic parsed;
      try { parsed = jsonDecode(data); }
      catch (_) { throw const AiProviderException('Flux IA mal formé.'); }
      if (parsed is! Map<String, dynamic>) {
        throw const AiProviderException('Flux IA mal formé.');
      }
      if (parsed['error'] != null) {
        if (_isExplicitRefusal(parsed)) {
          throw const AiProviderException(
            'Le fournisseur a explicitement refusé la demande.',
            kind: AiProviderErrorKind.refused,
          );
        }
        throw const AiProviderException('Le fournisseur a interrompu la génération.');
      }
      final usage = parsed['usage'];
      if (usage is Map<String, dynamic>) {
        yield AiToolStreamChunk(
          promptTokens: usage['prompt_tokens'] is int
              ? usage['prompt_tokens'] as int : null,
          completionTokens: usage['completion_tokens'] is int
              ? usage['completion_tokens'] as int : null,
        );
      }
      final choices = parsed['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final choice = choices.first;
      if (choice is! Map<String, dynamic>) continue;
      if (choice['finish_reason'] is String) {
        finishReason = choice['finish_reason'] as String;
        yield AiToolStreamChunk(finishReason: finishReason);
      }
      final delta = choice['delta'];
      if (delta is! Map<String, dynamic>) continue;
      if (delta['content'] is String) {
        yield AiToolStreamChunk(text: delta['content'] as String);
      }
      final calls = delta['tool_calls'];
      if (calls is! List) continue;
      for (final item in calls) {
        if (item is! Map<String, dynamic> || item['index'] is! int) {
          throw const AiProviderException('Fragment de fonction invalide.');
        }
        final function = item['function'];
        yield AiToolStreamChunk(
          callIndex: item['index'] as int,
          callId: item['id'] is String ? item['id'] as String : null,
          callName: function is Map && function['name'] is String
              ? function['name'] as String : null,
          argumentsDelta: function is Map && function['arguments'] is String
              ? function['arguments'] as String : null,
        );
      }
    }
      if (!done) {
        throw const AiProviderException('Flux IA incomplet : outils non exécutés.');
      }
      if (finishReason == 'content_filter') {
        throw const AiProviderException(
          'Le fournisseur a filtré la réponse (content_filter).',
          kind: AiProviderErrorKind.refused,
        );
      }
      if (finishReason == 'length') {
        throw const AiProviderException(
          'La réponse du modèle a été tronquée par sa limite de sortie.',
        );
      }
    } on AiProviderException {
      rethrow;
    } on TimeoutException {
      throw const AiProviderException(
        'Le flux IA ne répond plus depuis 75 s.',
        kind: AiProviderErrorKind.timeout,
      );
    } catch (_) {
      throw const AiProviderException(
        'Connexion interrompue pendant la génération. Réessayez.',
        kind: AiProviderErrorKind.network,
      );
    }
  }

}
