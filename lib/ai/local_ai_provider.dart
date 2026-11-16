import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

import 'ai_provider.dart';
import 'local_model_manager.dart';
import 'local_model_catalog.dart';
import 'local_context_budget.dart';
import 'local_inference_options.dart';
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
  String? _loadedConfiguration;
  static const bool vulkanBackendBuilt =
      bool.fromEnvironment('DOMOLIA_VULKAN_BACKEND', defaultValue: false);
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
    final options = await LocalInferenceOptions.load();
    final threads = options.effectiveThreads();
    final signature = '${models.installedId}:$threads:${options.gpuMode.name}:'
        '$vulkanBackendBuilt';
    if (_loadedConfiguration == signature && _runtime != null) return;

    if (_runtime != null) {
      await _runtime!.dispose();
      _runtime = null;
      _loadedId = null;
      _loadedConfiguration = null;
    }
    var runtime = LlamaController();
    final variant = models.installedVariant!;
    var gpuLayers = 0;
    await models.markNativeStage('chargement du modèle');
    try {
      if (vulkanBackendBuilt && options.gpuMode == LocalGpuMode.automatic) {
        try {
          final gpu = await runtime.detectGpu();
          if (gpu.vulkanSupported) {
            gpuLayers = gpu.recommendedGpuLayers.clamp(0, 99).toInt();
          }
          AppLogger.info('IA locale : matériel GPU détecté',
              component: 'local_ai', details: {
                'gpu': gpu.gpuName,
                'vulkanSupported': gpu.vulkanSupported,
                'recommendedGpuLayers': gpu.recommendedGpuLayers,
                'gpuLayersRequested': gpuLayers,
              });
        } catch (failure) {
          AppLogger.info('IA locale : détection Vulkan indisponible',
              component: 'local_ai', details: {'reason': failure.toString()});
        }
      }
      AppLogger.info('IA locale : chargement natif commencé',
          component: 'local_ai', details: {
            'model': variant.id, 'contextSize': variant.contextTokens,
            'threads': threads, 'logicalProcessors': options.effectiveThreads(),
            'gpuLayers': gpuLayers, 'vulkanBackendBuilt': vulkanBackendBuilt,
          });
      await AppLogger.current.flush();
      try {
        await runtime.loadModel(
          modelPath: models.installedPath!,
          threads: threads,
          contextSize: variant.contextTokens,
          gpuLayers: gpuLayers,
        );
      } catch (failure) {
        if (gpuLayers == 0) rethrow;
        AppLogger.info('IA locale : échec GPU, tentative CPU',
            component: 'local_ai', details: {'reason': failure.toString()});
        // A failed native load may leave state behind: retry in a fresh engine.
        await runtime.dispose();
        runtime = LlamaController();
        await runtime.loadModel(
          modelPath: models.installedPath!,
          threads: threads,
          contextSize: variant.contextTokens,
          gpuLayers: 0,
        );
        gpuLayers = 0;
      }
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
        details: {'model': variant.id, 'threads': threads,
                  'gpuLayers': gpuLayers});
    _runtime = runtime;
    _loadedId = models.installedId;
    _loadedConfiguration = signature;
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
    _loadedConfiguration = null;
    if (runtime != null) await runtime.dispose();
  }

  Future<void> dispose() async {
    _closed = true;
    await unload();
  }
}
