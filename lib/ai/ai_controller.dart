import 'package:flutter/foundation.dart';

import 'ai_provider.dart';

/// Exposes only the key's presence to widgets, never the plaintext secret.
class AiConnectionController extends ChangeNotifier {
  AiConnectionController({required this.store, required this.provider});

  final AiConfigurationStore store;
  final AiChatProvider provider;
  String baseUrl = defaultAiBaseUrl;
  String model = defaultAiModel;
  bool hasKey = false;
  bool initialized = false;
  bool busy = false;
  bool? testPassed;
  String? message;
  String? testReply;
  List<AiModel> models = const [];
  bool _closed = false;
  Future<void>? _initializing;

  void _notify() { if (!_closed) notifyListeners(); }

  Future<void> initialize() {
    if (_closed || initialized) return Future<void>.value();
    return _initializing ??= _load();
  }

  Future<void> _load() async {
    try {
      final stored = await store.read();
      if (_closed) return;
      if (stored != null) {
        baseUrl = stored.baseUrl;
        model = stored.model;
        hasKey = stored.apiKey.isNotEmpty;
      }
    } catch (_) {
      message = 'Impossible de lire les paramètres IA sécurisés.';
    } finally {
      initialized = true;
      _notify();
    }
  }

  Future<bool> save(String url, String selectedModel, String newKey) async {
    if (busy) return false;
    busy = true;
    message = null;
    testPassed = null;
    testReply = null;
    _notify();
    try {
      final validatedUrl = validatedAiBaseUrl(url);
      final validatedModel = validatedAiModel(selectedModel);
      final old = await store.read();
      final key = newKey.trim().isNotEmpty ? newKey.trim() : (old?.apiKey ?? '');
      await store.write(AiConfiguration(
        baseUrl: validatedUrl, model: validatedModel, apiKey: key,
      ));
      baseUrl = validatedUrl;
      model = validatedModel;
      hasKey = key.isNotEmpty;
      message = 'Configuration IA enregistrée de manière sécurisée.';
      return true;
    } on AiProviderException catch (error) {
      message = error.userMessage;
      return false;
    } catch (_) {
      message = 'Impossible d’enregistrer les paramètres IA sécurisés.';
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> removeKey() async {
    if (busy) return;
    busy = true;
    _notify();
    try {
      final current = await store.read();
      await store.write(AiConfiguration(
        baseUrl: current?.baseUrl ?? baseUrl,
        model: current?.model ?? model,
        apiKey: '',
      ));
      hasKey = false;
      models = const [];
      testPassed = null;
      testReply = null;
      message = 'Clé API supprimée du stockage sécurisé.';
    } catch (_) {
      message = 'Impossible de supprimer la clé API.';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> loadModels() async {
    if (busy) return;
    busy = true;
    message = null;
    _notify();
    try {
      final configuration = await store.read();
      if (configuration == null || configuration.apiKey.isEmpty) {
        throw const AiProviderException('Enregistrez une clé API pour charger les modèles.');
      }
      models = await provider.listModels(configuration);
      message = models.isEmpty
          ? 'Aucun modèle disponible. Vous pouvez saisir un identifiant manuellement.'
          : 'Catalogue de modèles chargé.';
    } on AiProviderException catch (error) {
      message = error.userMessage;
    } catch (_) {
      message = 'Impossible de charger les modèles.';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> testConnection() async {
    if (busy) return;
    busy = true;
    message = null;
    testPassed = null;
    testReply = null;
    _notify();
    try {
      final configuration = await store.read();
      if (configuration == null || configuration.apiKey.isEmpty) {
        throw const AiProviderException('Enregistrez une clé API avant de tester.');
      }
      final reply = await provider.complete(
        configuration,
        messages: const [
          AiMessage(
            role: 'user',
            content: 'Réponds en français, en une phrase très courte, pour confirmer la connexion.',
          ),
        ],
        maxTokens: 64,
      );
      testPassed = true;
      testReply = reply.length > 320 ? reply.substring(0, 320) + '…' : reply;
      message = 'Connexion réussie : réponse reçue du modèle.';
    } on AiProviderException catch (error) {
      testPassed = false;
      message = error.userMessage;
    } catch (_) {
      testPassed = false;
      message = 'Test impossible. Vérifiez la connexion et vos paramètres.';
    } finally {
      busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
