import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_provider.dart';
import 'ai_diagnostics.dart';

/// ChatGPT plan inference uses the public Responses endpoint. The common
/// Domolia chat/tool contracts are independent from the wire protocol.
class ChatGptResponsesProvider
    implements AiChatProvider, AiStreamingChatProvider, AiToolCallingChatProvider {
  ChatGptResponsesProvider({http.Client? client, this.diagnostics})
      : _client = client ?? http.Client();

  final http.Client _client;
  final AiExchangeRecorder? diagnostics;
  static final _responses = Uri.parse('https://api.openai.com/v1/responses');

  /// OSS token sharing currently forbids max_output_tokens: retain the local
  /// validation of the task setting but do not forward this unsupported field.
  void _validate(AiConfiguration configuration, int maxTokens) {
    if (configuration.apiKey.isEmpty) {
      throw const AiProviderException('Connectez d’abord votre compte ChatGPT.');
    }
    validatedAiModel(configuration.model);
    if (maxTokens < 1 || maxTokens > 32768) {
      throw const AiProviderException('Budget de sortie IA invalide.');
    }
    if (configuration.reasoningEffort != null &&
        !const ['none', 'low', 'medium', 'high', 'xhigh', 'max']
            .contains(configuration.reasoningEffort)) {
      throw const AiProviderException('Niveau de raisonnement invalide.');
    }
  }

  /// The OSS Responses contract requires system guidance in instructions,
  /// rather than as input items with role=system.
  String? _instructions(Iterable<String> systems) {
    final parts = systems.where((text) => text.trim().isNotEmpty).toList();
    return parts.isEmpty ? null : parts.join('\n\n');
  }

  @override
  Stream<AiStreamChunk> streamChat(AiConfiguration configuration, {
    required List<AiMessage> messages,
    int maxTokens = 1200,
  }) async* {
    if (messages.isEmpty || messages.any((message) =>
        !{'system', 'user', 'assistant'}.contains(message.role) ||
        message.content.trim().isEmpty)) {
      throw const AiProviderException('Messages IA invalides.');
    }
    final instructions = _instructions(messages.where((m) =>
        m.role == 'system').map((m) => m.content));
    final input = <Map<String, dynamic>>[
      for (final message in messages)
        if (message.role != 'system')
          {'role': message.role, 'content': message.content},
    ];
    var length = 0;
    await for (final event in _events(configuration, input: input,
        instructions: instructions, maxTokens: maxTokens)) {
      switch (event['type']) {
        case 'response.output_text.delta':
          final text = event['delta'];
          if (text is String && text.isNotEmpty) {
            length += text.length;
            if (length > 131072) {
              throw const AiProviderException('Réponse ChatGPT trop longue.');
            }
            yield AiStreamChunk(text: text);
          }
        case 'response.completed':
          final usage = _usage(event);
          if (usage != null) {
            yield AiStreamChunk(
              promptTokens: usage['input_tokens'] as int?,
              completionTokens: usage['output_tokens'] as int?,
            );
          }
      }
    }
  }

  String _plainName(String name) {
    // Calls from the namespaced Responses tools must match the neutral
    // function names registered in Domolia's local tool executor.
    return name.startsWith('domolia.') ? name.substring(8) : name;
  }

  /// Adapt streamed Responses function calls to the exact same chunks emitted
  /// by OpenUncensored's Chat Completions transport.
  @override
  Stream<AiToolStreamChunk> streamToolChat(AiConfiguration configuration, {
    required List<AiToolMessage> messages,
    required List<AiToolDefinition> tools,
    int maxTokens = 1200,
  }) async* {
    if (messages.isEmpty) {
      throw const AiProviderException('Messages IA invalides.');
    }
    final input = <Map<String, dynamic>>[];
    final systemGuidance = <String>[];
    for (final message in messages) {
      switch (message.role) {
        case 'system':
          if (message.content.trim().isEmpty) {
            throw const AiProviderException('Instructions IA invalides.');
          }
          systemGuidance.add(message.content);
        case 'user':
          if (message.content.trim().isEmpty || message.calls.isNotEmpty) {
            throw const AiProviderException('Message utilisateur IA invalide.');
          }
          input.add({'role': 'user', 'content': message.content});
        case 'assistant':
          if (message.content.isNotEmpty) {
            input.add({'role': 'assistant', 'content': message.content});
          }
          for (final call in message.calls) {
            input.add({
              'type': 'function_call',
              'call_id': call.id,
              'name': call.name,
              'namespace': 'domolia',
              'arguments': call.arguments,
            });
          }
        case 'tool':
          if (message.toolCallId == null) {
            throw const AiProviderException('Identifiant de fonction manquant.');
          }
          input.add({
            'type': 'function_call_output',
            'call_id': message.toolCallId,
            'output': message.content,
          });
        default:
          throw const AiProviderException('Rôle de message IA invalide.');
      }
    }
    final toolSchemas = <Map<String, dynamic>>[
      if (tools.isNotEmpty)
        {
          'type': 'namespace',
          'name': 'domolia',
          'description': 'Read-only tools for narrative context, lore and memory.',
          'tools': [
            for (final tool in tools)
              {
                'type': 'function',
                'name': tool.name,
                'description': tool.description,
                'parameters': tool.parameters,
                'strict': false,
              },
          ],
        },
    ];

    final indices = <int, int>{};
    final argumentsSeen = <int, bool>{};
    final completedCalls = <int>{};
    var outputLength = 0;
    int indexOf(Map<String, dynamic> event) {
      final outputIndex = event['output_index'];
      if (outputIndex is! int || outputIndex < 0) {
        throw const AiProviderException('Index de fonction ChatGPT invalide.');
      }
      return indices.putIfAbsent(outputIndex, () => indices.length);
    }

    await for (final event in _events(configuration, input: input,
        instructions: _instructions(systemGuidance),
        tools: toolSchemas, maxTokens: maxTokens)) {
      switch (event['type']) {
        case 'response.output_text.delta':
          final text = event['delta'];
          if (text is String && text.isNotEmpty) {
            outputLength += text.length;
            if (outputLength > 131072) {
              throw const AiProviderException('Réponse ChatGPT trop longue.');
            }
            yield AiToolStreamChunk(text: text);
          }
        case 'response.output_item.added':
          final item = event['item'];
          if (item is Map<String, dynamic> &&
              item['type'] == 'function_call') {
            final idx = indexOf(event);
            completedCalls.add(idx);
            yield AiToolStreamChunk(
              callIndex: idx,
              callId: item['call_id'] is String
                  ? item['call_id'] as String : null,
              callName: item['name'] is String
                  ? _plainName(item['name'] as String) : null,
            );
          }
        case 'response.function_call_arguments.delta':
          final idx = indexOf(event);
          final delta = event['delta'];
          if (delta is String) {
            argumentsSeen[idx] = true;
            yield AiToolStreamChunk(
              callIndex: idx, argumentsDelta: delta);
          }
        case 'response.output_item.done':
          final item = event['item'];
          if (item is Map<String, dynamic> &&
              item['type'] == 'function_call') {
            final idx = indexOf(event);
            completedCalls.add(idx);
            yield AiToolStreamChunk(
              callIndex: idx,
              callId: item['call_id'] is String
                  ? item['call_id'] as String : null,
              callName: item['name'] is String
                  ? _plainName(item['name'] as String) : null,
              argumentsDelta: argumentsSeen[idx] == true
                  ? null : item['arguments'] is String
                      ? item['arguments'] as String : null,
            );
          }
        case 'response.completed':
          final usage = _usage(event);
          yield AiToolStreamChunk(
            finishReason: completedCalls.isNotEmpty ? 'tool_calls' : 'stop',
            promptTokens: usage?['input_tokens'] as int?,
            completionTokens: usage?['output_tokens'] as int?,
          );
      }
    }
  }

  Map<String, dynamic>? _usage(Map<String, dynamic> event) {
    final response = event['response'];
    if (response is! Map<String, dynamic>) return null;
    final usage = response['usage'];
    return usage is Map<String, dynamic> ? usage : null;
  }

  /// Shared and fully diagnostics-aware HTTP/SSE transport for both APIs.
  Stream<Map<String, dynamic>> _events(AiConfiguration configuration, {
    required List<Map<String, dynamic>> input,
    String? instructions,
    List<Map<String, dynamic>> tools = const [],
    required int maxTokens,
  }) async* {
    _validate(configuration, maxTokens);
    if (input.isEmpty) {
      throw const AiProviderException('Contexte IA vide.');
    }
    final request = http.Request('POST', _responses)
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer ' + configuration.apiKey
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'text/event-stream'
      ..body = jsonEncode({
        'model': configuration.model,
        'input': input,
        if (instructions != null) 'instructions': instructions,
        if (tools.isNotEmpty) 'tools': tools,
        'store': false,
        'stream': true,
        // max_output_tokens is not supported by SIWC plan sharing.
        if (configuration.reasoningEffort != null)
          'reasoning': {'effort': configuration.reasoningEffort},
      });
    final exchange = diagnostics?.begin(
      provider: 'chatgpt-responses',
      method: request.method,
      url: request.url.toString(),
      requestBody: request.body,
      secret: configuration.apiKey,
      accept: request.headers['Accept'] ?? 'text/event-stream',
    );

    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(const Duration(seconds: 25));
      exchange?.statusCode = response.statusCode;
    } catch (_) {
      throw const AiProviderException('Connexion à ChatGPT impossible.');
    }
    if (response.statusCode != 200) {
      if (exchange != null) {
        try {
          await for (final bytes in response.stream.timeout(
              const Duration(seconds: 8))) {
            exchange.addRawResponse(bytes);
            if (exchange.truncated) break;
          }
        } catch (_) {
          // Preserve the HTTP code if the upstream error stream is broken.
        }
      }
      switch (response.statusCode) {
        case 400:
          throw const AiProviderException(
            'Requête ChatGPT refusée : vérifiez le modèle et ses capacités.');
        case 401:
        case 403:
          throw const AiProviderException(
            'Session ChatGPT expirée ou non autorisée. Reconnectez votre compte.');
        case 429:
          throw const AiProviderException(
            'Limite d’utilisation de l’abonnement atteinte.');
        default:
          throw AiProviderException(
            'ChatGPT a répondu HTTP ' + response.statusCode.toString() + '.');
      }
    }
    var completed = false;
    try {
      await for (final line in response.stream.map((bytes) {
            exchange?.addRawResponse(bytes);
            return bytes;
          }).transform(utf8.decoder)
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
        final eventType = body['type'];
        if (eventType == 'response.incomplete') {
          final result = body['response'];
          final details = result is Map<String, dynamic>
              ? result['incomplete_details'] : null;
          final reason = details is Map<String, dynamic>
              ? details['reason'] : null;
          if (reason == 'max_output_tokens') {
            throw const AiProviderException(
              'Budget de sortie épuisé (raisonnement compris).');
          }
          throw const AiProviderException(
            'ChatGPT a interrompu la réponse avant sa fin.');
        }
        if (eventType == 'response.failed' || eventType == 'error') {
          throw const AiProviderException(
            'ChatGPT a interrompu la génération. Vérifiez les limites du compte.');
        }
        if (eventType == 'response.completed') completed = true;
        yield body;
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
  Future<String> complete(AiConfiguration configuration, {
    required List<AiMessage> messages,
    int maxTokens = 64,
  }) async {
    final output = StringBuffer();
    await for (final chunk in streamChat(configuration,
        messages: messages, maxTokens: maxTokens)) {
      output.write(chunk.text);
    }
    if (output.isEmpty) {
      throw const AiProviderException('ChatGPT n’a retourné aucune réponse.');
    }
    return output.toString();
  }

  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async =>
      throw const AiProviderException(
        'Le catalogue ChatGPT est fourni par le compte connecté.');
}
