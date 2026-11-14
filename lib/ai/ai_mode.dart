import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AiConnectionMode { chatgpt, customAi }

abstract interface class AiModeStore {
  Future<AiConnectionMode> read();
  Future<void> write(AiConnectionMode mode);
}

class PreferencesAiModeStore implements AiModeStore {
  static const _key = 'domolia.ai.connection_mode.v1';

  @override
  Future<AiConnectionMode> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key) == 'chatgpt'
        ? AiConnectionMode.chatgpt
        : AiConnectionMode.customAi;
  }

  @override
  Future<void> write(AiConnectionMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_key, mode.name)) {
      throw StateError('Impossible de mémoriser le type de connexion IA.');
    }
  }
}

/// Mode selection contains no credentials. Existing CustomAI profiles are never
/// migrated, deleted, or overwritten by switching modes.
class AiModeController extends ChangeNotifier {
  AiModeController(this.store);
  final AiModeStore store;

  AiConnectionMode mode = AiConnectionMode.customAi;
  bool initialized = false;
  bool busy = false;
  String? error;
  bool _disposed = false;
  Future<void>? _loading;

  Future<void> initialize() => _loading ??= _load();

  Future<void> _load() async {
    try {
      mode = await store.read();
    } catch (_) {
      error = 'Impossible de lire le choix du fournisseur.';
    } finally {
      initialized = true;
      _notify();
    }
  }

  Future<bool> select(AiConnectionMode value) async {
    if (!initialized) await initialize();
    if (busy) return false;
    if (mode == value) return true;
    busy = true;
    error = null;
    _notify();
    try {
      await store.write(value);
      mode = value;
      return true;
    } catch (_) {
      error = 'Impossible de mémoriser le choix du fournisseur.';
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
