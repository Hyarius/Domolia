import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tasks are routed to existing named AI profiles, never to raw credentials.
enum AiNarrativeTask { narrator, jsonifier }

/// Optional application-wide defaults. A null task profile preserves the
/// previous routing behavior (selected AI for the narrator, same AI for JSON).
///
/// Settings are local to this installation and excluded from Book exports.
class AiTaskRouting extends ChangeNotifier {
  AiTaskRouting({Future<SharedPreferences> Function()? preferences})
      : _preferences = preferences ?? SharedPreferences.getInstance;

  static const _narratorKey = 'aiTaskNarratorProfileId';
  static const _jsonifierKey = 'aiTaskJsonifierProfileId';
  final Future<SharedPreferences> Function() _preferences;
  Future<void>? _loading;
  String? _narratorId;
  String? _jsonifierId;
  bool initialized = false;

  String? profileFor(AiNarrativeTask task) => switch (task) {
    AiNarrativeTask.narrator => _narratorId,
    AiNarrativeTask.jsonifier => _jsonifierId,
  };

  Future<void> initialize() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await _preferences();
      _narratorId = prefs.getString(_narratorKey);
      _jsonifierId = prefs.getString(_jsonifierKey);
      initialized = true;
      notifyListeners();
    } catch (_) {
      _loading = null;
      rethrow;
    }
  }

  Future<void> setProfile(AiNarrativeTask task, String? profileId) async {
    await initialize();
    final key = switch (task) {
      AiNarrativeTask.narrator => _narratorKey,
      AiNarrativeTask.jsonifier => _jsonifierKey,
    };
    final prefs = await _preferences();
    final successful = profileId == null
        ? await prefs.remove(key)
        : await prefs.setString(key, profileId);
    if (!successful) throw StateError('Enregistrement des tâches IA échoué.');
    switch (task) {
      case AiNarrativeTask.narrator:
        _narratorId = profileId;
      case AiNarrativeTask.jsonifier:
        _jsonifierId = profileId;
    }
    notifyListeners();
  }
}
