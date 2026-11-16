import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

import 'ai_provider.dart';
import 'ministral_model_manager.dart';
import '../logging/app_logger.dart';

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
    // A small context is safer on phones with 6 GB RAM. Keep the GPU off
    // until the CPU baseline is demonstrated on the device.
    await models.markNativeStage('chargement du modèle');
    AppLogger.info('Ministral : chargement natif commencé',
        component: 'local_ai',
        details: {'contextSize': 2048, 'threads': 2, 'gpuLayers': 0});
    await AppLogger.current.flush();
    try {
      await runtime.loadModel(
        modelPath: models.installedPath!,
        threads: 2,
        contextSize: 2048,
        gpuLayers: 0,
      );
    } catch (failure, trace) {
      AppLogger.error('Ministral : échec de chargement natif',
          component: 'local_ai', error: failure, stackTrace: trace);
      await AppLogger.current.flush();
      await models.clearNativeStage();
      await runtime.dispose();
      throw const AiProviderException(
          'Ministral ne peut pas être chargé sur cet appareil '
          '(mémoire ou compatibilité du moteur).');
    }
    await models.clearNativeStage();
    AppLogger.info('Ministral : modèle natif chargé', component: 'local_ai');
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
      final limit = maxTokens.clamp(8, 1200).toInt();
      final watch = Stopwatch()..start();
      var fragments = 0;
      await models.markNativeStage('génération du texte');
      AppLogger.info('Ministral : génération native commencée',
          component: 'local_ai',
          details: {'promptCharacters': prompt.length, 'outputLimit': limit});
      await AppLogger.current.flush();
      await for (final token in _runtime!.generate(
        prompt: prompt,
        maxTokens: limit,
        temperature: 0.55,
        topP: 0.9,
      )) {
        fragments++;
        if (fragments == 1) {
          AppLogger.info('Ministral : premier fragment reçu',
              component: 'local_ai',
              details: {'firstFragmentMs': watch.elapsedMilliseconds});
          await AppLogger.current.flush();
        }
        yield AiStreamChunk(text: token);
      }
      completed = true;
      AppLogger.info('Ministral : génération native terminée',
          component: 'local_ai',
          details: {'durationMs': watch.elapsedMilliseconds,
                    'fragments': fragments});
    } catch (failure, trace) {
      AppLogger.error('Ministral : échec pendant la génération',
          component: 'local_ai', error: failure, stackTrace: trace);
      rethrow;
    } finally {
      try {
        if (!completed && _runtime != null) await _runtime!.stop();
      } finally {
        await models.clearNativeStage();
        done.complete();
      }
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
