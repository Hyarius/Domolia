import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

import 'ai_provider.dart';
import 'local_model_manager.dart';
import 'local_model_catalog.dart';
import 'local_context_budget.dart';
import 'local_prompt.dart';

export 'local_prompt.dart';
import '../logging/app_logger.dart';

/// Multi-model local text-only provider: no network, no API token, no paid fallback.
/// A shared engine is serialized across narrator, JSONifier, and memory.
class LocalAiProvider implements AiChatProvider, AiStreamingChatProvider {
  LocalAiProvider(this.models);
  final LocalModelManager models;
  final LocalTokenEstimator tokenEstimator = LocalTokenEstimator();

  LocalContextBudget budgetFor(LocalModelVariant model, int outputTokens) =>
      LocalContextBudget(model: model, estimator: tokenEstimator,
          outputTokens: outputTokens.clamp(8, 1200));
  LlamaController? _runtime;
  String? _loadedId;
  Future<void> _queue = Future<void>.value();
  bool _closed = false;

  static AiConfiguration configurationFor(LocalModelVariant variant) =>
      AiConfiguration(
        baseUrl: 'local://on-device',
        model: variant.modelId,
        apiKey: 'local-inference',
      );

  @override
  Future<List<AiModel>> listModels(AiConfiguration _) async {
    await models.initialize();
    return [if (models.installedVariant case final installed?)
      AiModel(installed.modelId)];
  }

  Future<void> _load() async {
    await models.initialize();
    if (!models.ready) {
      throw const AiProviderException(
          'Modèle local non installé. Ouvrez Paramètres > IA locale.');
    }
    if (_loadedId == models.installedId && _runtime != null) return;
    if (_runtime != null) {
      await _runtime!.dispose();
      _runtime = null;
      _loadedId = null;
    }
    final runtime = LlamaController();
    final variant = models.installedVariant!;
    // A small context is safer on phones with 6 GB RAM. Keep the GPU off
    // until the CPU baseline is demonstrated on the device.
    await models.markNativeStage('chargement du modèle');
    AppLogger.info('IA locale : chargement natif commencé',
        component: 'local_ai',
        details: {'model': variant.id, 'contextSize': variant.contextTokens,
                  'threads': 2, 'gpuLayers': 0});
    await AppLogger.current.flush();
    try {
      await runtime.loadModel(
        modelPath: models.installedPath!,
        threads: 2,
        contextSize: variant.contextTokens,
        gpuLayers: 0,
      );
    } catch (failure, trace) {
      AppLogger.error('IA locale : échec de chargement natif',
          component: 'local_ai', error: failure, stackTrace: trace);
      await AppLogger.current.flush();
      await models.clearNativeStage();
      await runtime.dispose();
      throw const AiProviderException(
          'Le modèle local ne peut pas être chargé sur cet appareil '
          '(mémoire ou compatibilité du moteur).');
    }
    await models.clearNativeStage();
    AppLogger.info('IA locale : modèle natif chargé', component: 'local_ai',
        details: {'model': variant.id});
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
    var fragments = 0;
    try {
      if (_closed || kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
        throw const AiProviderException('L’IA locale nécessite Android.');
      }
      await _load();
      final variant = models.installedVariant!;
      final prompt = LocalPrompt.format(variant, messages);
      final limit = maxTokens.clamp(8, 1200).toInt();
      final budget = budgetFor(variant, limit);
      budget.requireFit(messages);
      // Native KV tokens otherwise accumulate although each request includes
      // its own history, which invalidates our context accounting.
      await _runtime!.clearContext();
      final watch = Stopwatch()..start();
      await models.markNativeStage('génération du texte');
      AppLogger.info('IA locale : génération native commencée',
          component: 'local_ai',
          details: {'model': variant.id, 'promptCharacters': prompt.length,
                    'promptTokensEstimated': budget.estimate(messages),
                    'contextTokens': variant.contextTokens,
                    'outputLimit': limit});
      await AppLogger.current.flush();
      // A stuck native decode must not wait forever. On timeout the
      // controller receives stop() in the finally block below.
      await for (final token in _runtime!.generate(
        prompt: prompt,
        maxTokens: limit,
        temperature: 0.55,
        topP: 0.9,
      ).timeout(const Duration(seconds: 90))) {
        fragments++;
        if (fragments == 1) {
          AppLogger.info('IA locale : premier fragment reçu',
              component: 'local_ai',
              details: {'firstFragmentMs': watch.elapsedMilliseconds});
          await AppLogger.current.flush();
        }
        yield AiStreamChunk(text: token);
      }
      completed = true;
      // This plugin emits one fragment per decoded non-EOS token.
      // Empty native KV plus decoded count yields real prompt token usage.
      int? nativePromptTokens;
      try {
        final usage = await _runtime!.getContextInfo();
        if (usage.tokensUsed >= fragments) {
          nativePromptTokens = usage.tokensUsed - fragments;
          tokenEstimator.observe(variant, prompt, nativePromptTokens);
        }
      } catch (_) {
        // Diagnostics must not turn a successful answer into an error.
      }
      AppLogger.info('IA locale : génération native terminée',
          component: 'local_ai',
          details: {'durationMs': watch.elapsedMilliseconds,
                    'fragments': fragments,
                    'promptTokensNative': nativePromptTokens});
    } on TimeoutException catch (failure, trace) {
      AppLogger.error('IA locale : aucun fragment reçu dans les délais',
          component: 'local_ai', error: failure, stackTrace: trace,
          details: {'firstFragmentReceived': fragments > 0});
      throw const AiProviderException('Le modèle local ne répond pas après 90 secondes. '
          'La génération locale est interrompue. Consultez les journaux.');
    } catch (failure, trace) {
      AppLogger.error('IA locale : échec pendant la génération',
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
