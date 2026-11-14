import 'package:flutter/foundation.dart';

import 'ai_provider.dart';

enum AiConnectionStatus { untested, testing, connected, invalid }

/// Keeps per-profile connection status only for the running session.
/// A green state never claims continued connectivity after app restart.
class AiConnectionController extends ChangeNotifier {
  AiConnectionController({required this.store, required this.provider});

  final AiProfileStore store;
  final AiChatProvider provider;

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
      final configuration = selectedProfile.configuration;
      if (configuration.apiKey.isEmpty) {
        throw const AiProviderException('Enregistrez une clé API avant de tester.');
      }
      final reply = await provider.complete(
        configuration,
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
