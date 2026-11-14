import 'package:flutter/foundation.dart';

import 'ai_provider.dart';
import 'chatgpt_auth.dart';

enum AiConnectionStatus { untested, testing, connected, invalid }

class AiConnectionBinding {
  const AiConnectionBinding({required this.provider, required this.configuration});
  final AiChatProvider provider;
  final AiConfiguration configuration;
}

/// Keeps per-profile connection status only for the running session.
/// A green state never claims continued connectivity after app restart.
class AiConnectionController extends ChangeNotifier {
  AiConnectionController({
    required this.store,
    required this.provider,
    this.chatGpt,
    this.chatGptProvider,
  });

  final AiProfileStore store;
  final AiChatProvider provider;
  final ChatGptAccountService? chatGpt;
  final AiChatProvider? chatGptProvider;

  List<AiProfile> _profiles = const [];
  String _selectedId = '';
  final Map<String, AiConnectionStatus> _statuses = {};
  final Map<String, String> _errors = {};
  final Map<String, String> _replies = {};
  final Map<String, List<AiModel>> _catalogues = {};
  int _sequence = 0;

  bool initialized = false;
  bool busy = false;
  String? message;
  bool _closed = false;
  Future<void>? _initializing;

  List<AiProfile> get profiles => List.unmodifiable(_profiles);
  String get selectedProfileId => _selectedId;
  AiProfile get selectedProfile =>
      _profiles.firstWhere((entry) => entry.id == _selectedId);
  AiProviderKind get selectedKind => selectedProfile.kind;
  String get baseUrl => selectedProfile.baseUrl;
  String get model => selectedProfile.model;
  bool get hasKey => selectedProfile.apiKey.isNotEmpty;
  List<AiModel> get models => List.unmodifiable(_catalogues[_selectedId] ?? const <AiModel>[]);
  AiConnectionStatus get status =>
      _statuses[_selectedId] ?? AiConnectionStatus.untested;
  String? get statusError => _errors[_selectedId];
  String? get testReply => _replies[_selectedId];
  bool? get testPassed => switch (status) {
        AiConnectionStatus.connected => true,
        AiConnectionStatus.invalid => false,
        _ => null,
      };

  void _notify() {
    if (!_closed) notifyListeners();
  }

  static AiProfile _defaultProfile() => const AiProfile(
        id: 'default',
        name: 'OpenUncensored',
        baseUrl: defaultAiBaseUrl,
        model: defaultAiModel,
        apiKey: '',
      );

  Future<void> initialize() {
    if (_closed || initialized) return Future<void>.value();
    return _initializing ??= _load();
  }

  Future<void> _load() async {
    try {
      final state = await store.read();
      if (_closed) return;
      if (state == null) {
        final initial = AiProfilesState(
          profiles: [_defaultProfile()],
          selectedId: 'default',
        );
        await store.write(initial);
        if (_closed) return;
        _profiles = initial.profiles;
        _selectedId = initial.selectedId;
      } else {
        if (state.profiles.isEmpty ||
            !state.profiles.any((p) => p.id == state.selectedId)) {
          throw const FormatException('Aucun profil IA valide.');
        }
        _profiles = List.of(state.profiles);
        _selectedId = state.selectedId;
      }
    } catch (_) {
      // Do not report storage exceptions containing potentially sensitive
      // platform-specific values.
      _profiles = [_defaultProfile()];
      _selectedId = 'default';
      message = 'Impossible de lire les profils IA sécurisés.';
    } finally {
      initialized = true;
      _notify();
    }
  }

  String? _validName(String input) {
    final name = input.trim();
    if (name.isEmpty || name.length > 60 || name.contains(RegExp(r'[\r\n]'))) {
      message = 'Le nom du profil doit contenir entre 1 et 60 caractères.';
      _notify();
      return null;
    }
    return name;
  }

  Future<bool> selectProfile(String id) async {
    if (_closed || busy || !_profiles.any((p) => p.id == id)) return false;
    if (id == _selectedId) return true;
    busy = true;
    _notify();
    try {
      await store.write(AiProfilesState(profiles: _profiles, selectedId: id));
      _selectedId = id;
      message = null;
      return true;
    } catch (_) {
      message = 'Impossible de sélectionner ce profil IA.';
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<bool> createProfile(String input) async {
    if (_closed || busy) return false;
    final name = _validName(input);
    if (name == null) return false;
    busy = true;
    _notify();
    try {
      String id;
      do {
        id = 'profile-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
      } while (_profiles.any((profile) => profile.id == id));
      final created = AiProfile(
        id: id,
        name: name,
        baseUrl: defaultAiBaseUrl,
        model: defaultAiModel,
        apiKey: '',
      );
      final next = [..._profiles, created];
      await store.write(AiProfilesState(profiles: next, selectedId: id));
      _profiles = next;
      _selectedId = id;
      message = 'Profil « $name » créé.';
      return true;
    } catch (_) {
      message = 'Impossible de créer ce profil IA.';
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }


  /// The stable named profile is the routing handle, independent of backend.
  Future<AiConnectionBinding> connectionForProfile(String id) async {
    final profile = _profiles.firstWhere(
      (item) => item.id == id,
      orElse: () => throw const AiProviderException('Profil IA introuvable.'),
    );
    if (profile.kind == AiProviderKind.customAi) {
      return AiConnectionBinding(
        provider: provider,
        configuration: profile.configuration,
      );
    }
    if (chatGpt == null || chatGptProvider == null) {
      throw const AiProviderException('Connexion ChatGPT indisponible.');
    }
    final token = await chatGpt!.accessToken(id);
    return AiConnectionBinding(
      provider: chatGptProvider!,
      configuration: AiConfiguration(
        baseUrl: 'https://api.openai.com/v1',
        model: profile.model,
        apiKey: token,
      ),
    );
  }

  Future<AiConnectionBinding> get activeConnection =>
      connectionForProfile(_selectedId);

  Future<bool> setProviderKind(AiProviderKind kind) async {
    if (_closed || busy || selectedKind == kind) return false;
    busy = true;
    _notify();
    try {
      final next = [
        for (final item in _profiles)
          item.id == _selectedId ? item.copyWith(kind: kind) : item,
      ];
      await store.write(AiProfilesState(profiles: next, selectedId: _selectedId));
      _profiles = next;
      _invalidate(_selectedId);
      message = null;
      return true;
    } catch (_) {
      message = 'Impossible de modifier le fournisseur de ce profil.';
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> connectChatGpt() async {
    if (_closed || busy || selectedKind != AiProviderKind.chatGpt) return;
    final id = _selectedId;
    busy = true;
    message = null;
    _statuses[id] = AiConnectionStatus.testing;
    _errors.remove(id);
    _notify();
    try {
      if (chatGpt == null) {
        throw const AiProviderException('Connexion ChatGPT indisponible.');
      }
      final session = await chatGpt!.signIn(id);
      if (!session.planEnabled) {
        throw const AiProviderException(
          'Compte connecté, mais l’utilisation de votre forfait n’est pas autorisée.',
        );
      }
      final fetched = await chatGpt!.listModels(id);
      _catalogues[id] = fetched;
      if (fetched.isNotEmpty &&
          !fetched.any((model) => model.id == selectedProfile.model)) {
        final next = [
          for (final profile in _profiles)
            profile.id == id
                ? profile.copyWith(model: fetched.first.id)
                : profile,
        ];
        await store.write(AiProfilesState(profiles: next, selectedId: id));
        _profiles = next;
      }
      _statuses[id] = AiConnectionStatus.connected;
      message = 'Compte ChatGPT connecté : ${session.email}.';
    } on AiProviderException catch (failure) {
      _statuses[id] = AiConnectionStatus.invalid;
      _errors[id] = failure.userMessage;
    } catch (_) {
      _statuses[id] = AiConnectionStatus.invalid;
      _errors[id] = 'Connexion ChatGPT impossible. Réessayez.';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<ChatGptSession?> get chatGptSession async =>
      chatGpt?.session(_selectedId);

  Future<void> disconnectChatGpt() async {
    if (_closed || busy || selectedKind != AiProviderKind.chatGpt) return;
    busy = true;
    _notify();
    try {
      await chatGpt?.disconnect(_selectedId);
      _invalidate(_selectedId);
      message = 'Compte ChatGPT déconnecté.';
    } on AiProviderException catch (failure) {
      _invalidate(_selectedId);
      message = failure.userMessage;
    } catch (_) {
      _invalidate(_selectedId);
      message = 'Révocation distante non confirmée. Vérifiez ChatGPT.';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<bool> selectChatGptModel(String id) async {
    if (_closed || busy || selectedKind != AiProviderKind.chatGpt) return false;
    try {
      final value = validatedAiModel(id);
      final next = [
        for (final profile in _profiles)
          profile.id == _selectedId ? profile.copyWith(model: value) : profile,
      ];
      await store.write(AiProfilesState(profiles: next, selectedId: _selectedId));
      _profiles = next;
      _invalidate(_selectedId);
      return true;
    } catch (_) {
      message = 'Impossible de sélectionner le modèle ChatGPT.';
      return false;
    } finally {
      _notify();
    }
  }

  Future<bool> renameProfile(String input) async {
    if (_closed || busy) return false;
    final name = _validName(input);
    if (name == null) return false;
    busy = true;
    _notify();
    try {
      final next = [
        for (final profile in _profiles)
          profile.id == _selectedId ? profile.copyWith(name: name) : profile,
      ];
      await store.write(AiProfilesState(profiles: next, selectedId: _selectedId));
      _profiles = next;
      message = 'Profil renommé.';
      return true;
    } catch (_) {
      message = 'Impossible de renommer ce profil IA.';
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<bool> deleteProfile() async {
    if (_closed || busy || _profiles.length <= 1) return false;
    busy = true;
    _notify();
    try {
      final removedId = _selectedId;
      final next = _profiles.where((entry) => entry.id != removedId).toList();
      final nextId = next.first.id;
      await store.write(AiProfilesState(profiles: next, selectedId: nextId));
      if (chatGpt != null) {
        try {
          await chatGpt!.delete(removedId);
        } catch (_) {
          // Local credentials are cleared by the account service.
        }
      }
      _profiles = next;
      _selectedId = nextId;
      // The deleted key is removed from the encrypted persisted snapshot.
      _statuses.remove(removedId);
      _errors.remove(removedId);
      _replies.remove(removedId);
      _catalogues.remove(removedId);
      message = 'Profil et clé API supprimés.';
      return true;
    } catch (_) {
      message = 'Impossible de supprimer ce profil IA.';
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  void _invalidate(String id) {
    _statuses.remove(id);
    _errors.remove(id);
    _replies.remove(id);
    _catalogues.remove(id);
  }

  Future<bool> save(String url, String selectedModel, String newKey) async {
    if (_closed || busy) return false;
    busy = true;
    message = null;
    _notify();
    try {
      if (selectedKind != AiProviderKind.customAi) {
        throw const AiProviderException(
          'Les paramètres ChatGPT sont gérés par la connexion au compte.',
        );
      }
      final normalizedUrl = validatedAiBaseUrl(url);
      final normalizedModel = validatedAiModel(selectedModel);
      final current = selectedProfile;
      final key = newKey.trim().isNotEmpty ? newKey.trim() : current.apiKey;
      final nextProfile = current.copyWith(
        baseUrl: normalizedUrl,
        model: normalizedModel,
        apiKey: key,
      );
      final changed = nextProfile.baseUrl != current.baseUrl ||
          nextProfile.model != current.model ||
          nextProfile.apiKey != current.apiKey;
      if (changed) {
        final next = [
          for (final profile in _profiles)
            profile.id == _selectedId ? nextProfile : profile,
        ];
        await store.write(AiProfilesState(profiles: next, selectedId: _selectedId));
        _profiles = next;
        _invalidate(_selectedId);
      }
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
    if (_closed || busy) return;
    busy = true;
    _notify();
    try {
      final next = [
        for (final profile in _profiles)
          profile.id == _selectedId ? profile.copyWith(apiKey: '') : profile,
      ];
      await store.write(AiProfilesState(profiles: next, selectedId: _selectedId));
      _profiles = next;
      _invalidate(_selectedId);
      message = 'Clé API supprimée du stockage sécurisé.';
    } catch (_) {
      message = 'Impossible de supprimer la clé API.';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> loadModels() async {
    if (_closed || busy) return;
    busy = true;
    message = null;
    _notify();
    try {
      if (selectedKind == AiProviderKind.chatGpt) {
        if (chatGpt == null) {
          throw const AiProviderException('Connexion ChatGPT indisponible.');
        }
        final list = await chatGpt!.listModels(_selectedId);
        _catalogues[_selectedId] = list;
        message = list.isEmpty ? 'Aucun modèle ChatGPT disponible.'
            : 'Catalogue ChatGPT chargé.';
        return;
      }
      final configuration = selectedProfile.configuration;
      if (configuration.apiKey.isEmpty) {
        throw const AiProviderException(
          'Enregistrez une clé API pour charger les modèles.',
        );
      }
      final fetched = await provider.listModels(configuration);
      _catalogues[_selectedId] = fetched;
      message = fetched.isEmpty
          ? 'Aucun modèle disponible pour ce profil.'
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
    if (_closed || busy) return;
    final id = _selectedId;
    busy = true;
    message = null;
    _errors.remove(id);
    _replies.remove(id);
    _statuses[id] = AiConnectionStatus.testing;
    _notify();
    try {
      final binding = await connectionForProfile(id);
      if (binding.configuration.apiKey.isEmpty) {
        throw const AiProviderException('Enregistrez une clé API avant de tester.');
      }
      final reply = await binding.provider.complete(
        binding.configuration,
        messages: const [
          AiMessage(
            role: 'user',
            content:
                'Réponds en français, en une phrase très courte, pour confirmer la connexion.',
          ),
        ],
        maxTokens: 64,
      );
      _statuses[id] = AiConnectionStatus.connected;
      _replies[id] =
          reply.length > 320 ? '${reply.substring(0, 320)}…' : reply;
    } on AiProviderException catch (error) {
      _statuses[id] = AiConnectionStatus.invalid;
      _errors[id] = error.userMessage;
    } catch (_) {
      _statuses[id] = AiConnectionStatus.invalid;
      _errors[id] =
          'API injoignable ou réponse inattendue. Vérifiez votre réseau et les paramètres.';
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
