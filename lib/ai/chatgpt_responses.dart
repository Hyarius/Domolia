import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_provider.dart';

/// ChatGPT plan sessions must use the public Responses API, not
/// /chat/completions and never ChatGPT's internal backend-api endpoints.
class ChatGptResponsesProvider implements AiChatProvider, AiStreamingChatProvider {
  ChatGptResponsesProvider({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;
  static final _responses =
      Uri.parse('https://api.openai.com/v1/responses');

  @override
  Stream<AiStreamChunk> streamChat(
    AiConfiguration configuration, {
    required List<AiMessage> messages,
    int maxTokens = 1200,
  }) async* {
    if (configuration.apiKey.isEmpty) {
      throw const AiProviderException('Connectez d’abord votre compte ChatGPT.');
    }
    validatedAiModel(configuration.model);
    if (messages.isEmpty ||
        messages.any((message) =>
            !{'user', 'assistant', 'system'}.contains(message.role) ||
            message.content.trim().isEmpty)) {
      throw const AiProviderException('Messages IA invalides.');
    }
    final request = http.Request('POST', _responses)
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer ${configuration.apiKey}'
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'text/event-stream'
      ..body = jsonEncode({
        'model': configuration.model,
        'input': [
          for (final message in messages)
            {'role': message.role, 'content': message.content},
        ],
        'store': false,
        'stream': true,
        'max_output_tokens': maxTokens,
      });

    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(const Duration(seconds: 25));
    } catch (_) {
      throw const AiProviderException('Connexion à ChatGPT impossible.');
    }
    if (response.statusCode != 200) {
      switch (response.statusCode) {
        case 401:
        case 403:
          throw const AiProviderException(
            'Session ChatGPT expirée ou non autorisée. Reconnectez votre compte.',
          );
        case 429:
          throw const AiProviderException(
            'Limite d’utilisation de l’abonnement atteinte.',
          );
        default:
          throw AiProviderException(
            'ChatGPT a répondu HTTP ${response.statusCode}.',
          );
      }
    }
    var completed = false;
    var size = 0;
    try {
      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(seconds: 90))) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty || data == '[DONE]') continue;
        if (data.length > 131072) {
          throw const AiProviderException('Réponse ChatGPT trop volumineuse.');
        }
        dynamic body;
        try {
          body = jsonDecode(data);
        } catch (_) {
          throw const AiProviderException('Réponse ChatGPT malformée.');
        }
        if (body is! Map<String, dynamic>) continue;
        final event = body['type'];
        if (event == 'response.output_text.delta') {
          final text = body['delta'];
          if (text is String && text.isNotEmpty) {
            size += text.length;
            if (size > 131072) {
              throw const AiProviderException('Réponse ChatGPT trop longue.');
            }
            yield AiStreamChunk(text: text);
          }
        } else if (event == 'response.completed') {
          completed = true;
          final complete = body['response'];
          if (complete is Map<String, dynamic>) {
            final usage = complete['usage'];
            if (usage is Map<String, dynamic>) {
              yield AiStreamChunk(
                promptTokens: usage['input_tokens'] is int
                    ? usage['input_tokens'] as int : null,
                completionTokens: usage['output_tokens'] is int
                    ? usage['output_tokens'] as int : null,
              );
            }
          }
        } else if (event == 'response.failed' ||
                   event == 'response.incomplete' ||
                   event == 'error') {
          throw const AiProviderException(
            'ChatGPT a interrompu la génération. Vérifiez les limites de votre compte.',
          );
        }
      }
      if (!completed) {
        throw const AiProviderException('Le flux ChatGPT s’est interrompu.');
      }
    } on AiProviderException {
      rethrow;
    } on TimeoutException {
      throw const AiProviderException('ChatGPT ne répond pas à temps.');
    } catch (_) {
      throw const AiProviderException('Flux ChatGPT interrompu.');
    }
  }

  @override
  Future<String> complete(
    AiConfiguration configuration, {
    required List<AiMessage> messages,
    int maxTokens = 64,
  }) async {
    final result = StringBuffer();
    await for (final chunk in streamChat(
      configuration,
      messages: messages,
      maxTokens: maxTokens,
    )) {
      result.write(chunk.text);
    }
    if (result.isEmpty) {
      throw const AiProviderException('ChatGPT n’a retourné aucune réponse.');
    }
    return result.toString();
  }

  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async =>
      throw const AiProviderException(
        'Le catalogue ChatGPT est fourni par le compte connecté.',
      );
}
