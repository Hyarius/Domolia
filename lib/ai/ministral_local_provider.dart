import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

import 'ai_provider.dart';
import 'ministral_model_manager.dart';

/// Formats text-only turns according to Ministral 3's published chat template.
/// Do not use the plugin's ChatML default; Ministral expects [INST] markers.
class MinistralPrompt {
  static String format(List<AiMessage> messages) {
    final system = messages.where((m) => m.role == 'system')
        .map((m) => m.content).join('\n\n');
    final buffer = StringBuffer('<s>');
    if (system.isNotEmpty) {
      buffer.write('[SYSTEM_PROMPT]');
      buffer.write(system);
      buffer.write('[/SYSTEM_PROMPT]');
    }
    var hasUser = false;
    for (final message in messages) {
      if (message.role == 'system') continue;
      if (message.role == 'user') {
        buffer.write('[INST]');
        buffer.write(message.content);
        buffer.write('[/INST]');
        hasUser = true;
      } else if (message.role == 'assistant') {
        buffer.write(message.content);
        buffer.write('</s>');
      }
    }
    if (!hasUser) throw const FormatException('Aucun message utilisateur.');
    return buffer.toString();
  }
}

/// Local text-only provider: no network, no API token, no paid fallback.
/// A shared engine is serialized across narrator, JSONifier, and memory.
class MinistralLocalProvider implements AiChatProvider, AiStreamingChatProvider {
  MinistralLocalProvider(this.models);
  final MinistralModelManager models;
  LlamaController? _runtime;
  String? _loadedId;
  Future<void> _queue = Future<void>.value();
  bool _closed = false;

  static const configuration = AiConfiguration(
    baseUrl: 'local://ministral',
    model: 'ministral-3-3b-instruct-2512',
    apiKey: 'local-inference',
  );

  @override
  Future<List<AiModel>> listModels(AiConfiguration _) async =>
      const [AiModel('ministral-3-3b-instruct-2512')];

  Future<void> _load() async {
    await models.initialize();
    if (!models.ready) {
      throw const AiProviderException(
          'Modèle Ministral non installé. Ouvrez Paramètres > IA locale.');
    }
    if (_loadedId == models.installedId && _runtime != null) return;
    if (_runtime != null) {
      await _runtime!.dispose();
      _runtime = null;
      _loadedId = null;
    }
    final runtime = LlamaController();
    try {
      await runtime.loadModel(
        modelPath: models.installedPath!,
        threads: 4,
        contextSize: 4096,
        gpuLayers: 0, // CPU baseline; benchmark Vulkan separately.
      );
    } catch (_) {
      await runtime.dispose();
      throw const AiProviderException(
          'Ministral ne peut pas être chargé sur cet appareil '
          '(mémoire ou compatibilité du moteur).');
    }
    _runtime = runtime;
    _loadedId = models.installedId;
  }

  @override
  Stream<AiStreamChunk> streamChat(AiConfiguration _, {
    required List<AiMessage> messages,
    int maxTokens = 512,
  }) async* {
    final previous = _queue;
    final done = Completer<void>();
    _queue = done.future;
    await previous;
    var completed = false;
    try {
      if (_closed || kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
        throw const AiProviderException('Ministral local nécessite Android.');
      }
      await _load();
      final prompt = MinistralPrompt.format(messages);
      // A hard ceiling prevents accidental multi-minute generations.
      final limit = maxTokens.clamp(64, 1200).toInt();
      await for (final token in _runtime!.generate(
        prompt: prompt,
        maxTokens: limit,
        temperature: 0.55,
        topP: 0.9,
      )) {
        yield AiStreamChunk(text: token);
      }
      completed = true;
    } finally {
      if (!completed && _runtime != null) {
        await _runtime!.stop();
      }
      done.complete();
    }
  }

  @override
  Future<String> complete(AiConfiguration config, {
    required List<AiMessage> messages,
    int maxTokens = 512,
  }) async {
    final result = StringBuffer();
    await for (final chunk in streamChat(config,
        messages: messages, maxTokens: maxTokens)) {
      result.write(chunk.text);
    }
    return result.toString();
  }

  Future<void> unload() async {
    await _queue;
    final runtime = _runtime;
    _runtime = null;
    _loadedId = null;
    if (runtime != null) await runtime.dispose();
  }

  Future<void> dispose() async {
    _closed = true;
    await unload();
  }
}
