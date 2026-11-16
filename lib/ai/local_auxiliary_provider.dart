import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

import 'ai_provider.dart';
import 'local_model_manager.dart';

/// A pure on-device AiChatProvider. No HTTP requests, API keys or telemetry.
/// The existing Jsonifier and LiveMemory validators still own all mutations.
class LocalAuxiliaryProvider implements AiChatProvider {
  LocalAuxiliaryProvider({required this.models});

  final LocalModelManager models;
  LlamaController? _runtime;
  Future<void>? _loading;
  Future<void> _serial = Future<void>.value();

  static const configuration = AiConfiguration(
    baseUrl: 'local://gguf', model: LocalModelManager.modelId,
    apiKey: 'on-device-only',
  );

  @override
  Future<List<AiModel>> listModels(AiConfiguration _) async =>
      const [AiModel(LocalModelManager.modelId)];

  Future<void> _ensureLoaded() async {
    if (_runtime != null) return;
    if (_loading != null) return _loading;
    final future = _load();
    _loading = future;
    try { await future; } finally { _loading = null; }
  }

  Future<void> _load() async {
    if (!await models.verifyInstalled()) {
      throw const AiProviderException(
          'Aucun modèle local vérifié. Téléchargez-le dans Paramètres > IA locale.');
    }
    final controller = LlamaController();
    try {
      await controller.loadModel(
        modelPath: models.verifiedPath!,
        threads: 4,
        contextSize: 4096,
        gpuLayers: 0, // Reliable CPU baseline; GPU benchmarking comes later.
      );
      _runtime = controller;
    } catch (_) {
      await controller.dispose();
      throw const AiProviderException(
          'Modèle local impossible à charger sur cet appareil.');
    }
  }

  /// A failing inference fails closed. Never silently bills the narrator
  /// or a remote JSONifier as fallback.
  @override
  Future<String> complete(AiConfiguration _, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) {
    final result = Completer<String>();
    _serial = _serial.catchError((Object _) {}).then((_) async {
      try {
        if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
          throw const AiProviderException('IA locale disponible sur Android uniquement.');
        }
        await _ensureLoaded();
        final transcript = [
          for (final m in messages)
            ChatMessage(role: m.role, content: m.content),
        ];
        final buffer = StringBuffer();
        await for (final token in _runtime!.generateChat(
          messages: transcript,
          template: 'chatml',
          maxTokens: maxTokens.clamp(64, 2048).toInt(),
          temperature: 0.15,
        )) {
          buffer.write(token);
        }
        final content = buffer.toString()
            .replaceFirst(RegExp(r'^\\s*<think>[\\s\\S]*?</think>\\s*'), '')
            .trim();
        if (content.isEmpty) {
          throw const AiProviderException('Le modèle local a répondu sans texte.');
        }
        result.complete(content);
      } catch (_) {
        result.completeError(const AiProviderException(
            'Génération locale échouée. Vérifiez le modèle et réessayez ; '
            'aucun appel payant de secours n’a été effectué.'));
      }
    });
    return result.future;
  }

  Future<void> dispose() async {
    await _serial.catchError((Object _) {});
    final runtime = _runtime;
    _runtime = null;
    if (runtime != null) await runtime.dispose();
  }
}
