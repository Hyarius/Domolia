import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_task_generation.dart';
export 'ai_task_generation.dart';

/// Tasks are routed to existing named AI profiles, never to raw credentials.

/// Optional application-wide defaults. A null task profile preserves the
/// previous routing behavior (selected AI for the narrator, same AI for JSON).
///
/// Settings are local to this installation and excluded from Book exports.
class AiTaskRouting extends ChangeNotifier {
  AiTaskRouting({Future<SharedPreferences> Function()? preferences})
      : _preferences = preferences ?? SharedPreferences.getInstance;

  static const _narratorKey = 'aiTaskNarratorProfileId';
  static const _jsonifierKey = 'aiTaskJsonifierProfileId';
  static const _optimizerKey = 'aiTaskOptimizerProfileId';
  static const _memoryKey = 'aiTaskMemoryProfileId';
  final Future<SharedPreferences> Function() _preferences;
  Future<void>? _loading;
  String? _narratorId;
  String? _jsonifierId;
  String? _optimizerId;
  String? _memoryId;
  bool initialized = false;
  final Map<AiNarrativeTask, AiTaskGenerationSettings> _generation = {};

  AiTaskGenerationSettings generationFor(AiNarrativeTask task) =>
      _generation[task] ?? AiTaskGenerationSettings.defaults(task);

  String? profileFor(AiNarrativeTask task) => switch (task) {
    AiNarrativeTask.narrator => _narratorId,
    AiNarrativeTask.jsonifier => _jsonifierId,
    AiNarrativeTask.optimizer => _optimizerId,
    AiNarrativeTask.memory => _memoryId,
  };

  Future<void> initialize() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await _preferences();
      _narratorId = prefs.getString(_narratorKey);
      _jsonifierId = prefs.getString(_jsonifierKey);
      _optimizerId = prefs.getString(_optimizerKey);
      _memoryId = prefs.getString(_memoryKey);
      for (final task in AiNarrativeTask.values) {
        final raw = prefs.getString('aiTaskGeneration-${task.name}');
        if (raw != null) {
          try {
            _generation[task] = AiTaskGenerationSettings.fromJson(
                jsonDecode(raw));
          } on FormatException {
            // A corrupt setting does not prevent editing AI profiles.
            _generation.remove(task);
          }
        }
      }
      initialized = true;
      notifyListeners();
    } catch (_) {
      _loading = null;
      rethrow;
    }
  }

  Future<void> setGeneration(AiNarrativeTask task,
      AiTaskGenerationSettings settings) async {
    settings.validate();
    await initialize();
    final preferences = await _preferences();
    final saved = await preferences.setString(
      'aiTaskGeneration-${task.name}', jsonEncode(settings.toJson()));
    if (!saved) throw StateError('Enregistrement des paramètres IA échoué.');
    _generation[task] = settings;
    notifyListeners();
  }

  Future<void> setProfile(AiNarrativeTask task, String? profileId) async {
    await initialize();
    final key = switch (task) {
      AiNarrativeTask.narrator => _narratorKey,
      AiNarrativeTask.jsonifier => _jsonifierKey,
      AiNarrativeTask.optimizer => _optimizerKey,
      AiNarrativeTask.memory => _memoryKey,
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
      case AiNarrativeTask.optimizer:
        _optimizerId = profileId;
      case AiNarrativeTask.memory:
        _memoryId = profileId;
    }
    notifyListeners();
  }
}
