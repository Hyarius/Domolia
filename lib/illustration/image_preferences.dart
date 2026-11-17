import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// API-only image configuration. Art direction and output format live in a
/// portable BookDefinition instead of global or per-Party preferences.
class ImageGenerationOptions {
  const ImageGenerationOptions({
    this.profileId = '',
    this.directorProfileId = '',
    this.model = '',
  });
  final String profileId, directorProfileId, model;

  ImageGenerationOptions copyWith({
    String? profileId, String? directorProfileId, String? model,
  }) => ImageGenerationOptions(
    profileId: profileId ?? this.profileId,
    directorProfileId: directorProfileId ?? this.directorProfileId,
    model: model ?? this.model,
  );

  Map<String, Object?> toJson() => {
    'profileId': profileId,
    'directorProfileId': directorProfileId,
    'model': model,
  };

  factory ImageGenerationOptions.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        (value['profileId'] != null && value['profileId'] is! String) ||
        (value['directorProfileId'] != null &&
            value['directorProfileId'] is! String) ||
        (value['model'] != null && value['model'] is! String)) {
      throw const FormatException('Configuration API des images invalide.');
    }
    // Legacy preview installs may have style/size/quality/count keys.
    // They are intentionally ignored; those choices now belong to the Book.
    final result = ImageGenerationOptions(
      profileId: value['profileId'] as String? ?? '',
      directorProfileId: value['directorProfileId'] as String? ?? '',
      model: value['model'] as String? ?? '',
    );
    result.validate();
    return result;
  }

  void validate() {
    if (profileId.length > 150 || directorProfileId.length > 150 ||
        model.length > 100) {
      throw const FormatException('Configuration API des images invalide.');
    }
  }
}

class ImagePreferences extends ChangeNotifier {
  ImagePreferences({Future<SharedPreferences> Function()? preferences})
      : _preferences = preferences ?? SharedPreferences.getInstance;
  static const _appKey = 'domolia.image.settings.v1';
  static const _sessionPrefix = 'domolia.image.party.';
  final Future<SharedPreferences> Function() _preferences;
  final Map<String, ImageGenerationOptions?> _parties = {};
  Future<void>? _loading;
  ImageGenerationOptions _app = const ImageGenerationOptions();

  ImageGenerationOptions get application => _app;

  Future<void> initialize() => _loading ??= _load();
  Future<void> _load() async {
    try {
      final prefs = await _preferences();
      final raw = prefs.getString(_appKey);
      if (raw != null) {
        try {
          _app = ImageGenerationOptions.fromJson(jsonDecode(raw));
        } on FormatException {
          _app = const ImageGenerationOptions();
        }
      }
      notifyListeners();
    } catch (_) {
      _loading = null;
      rethrow;
    }
  }

  Future<ImageGenerationOptions?> overrideFor(String sessionId) async {
    await initialize();
    if (!_parties.containsKey(sessionId)) {
      final prefs = await _preferences();
      final raw = prefs.getString(_sessionPrefix + sessionId);
      if (raw == null) {
        _parties[sessionId] = null;
      } else {
        try {
          _parties[sessionId] =
              ImageGenerationOptions.fromJson(jsonDecode(raw));
        } on FormatException {
          _parties[sessionId] = null;
        }
      }
    }
    return _parties[sessionId];
  }

  Future<ImageGenerationOptions> forSession(String sessionId) async =>
      await overrideFor(sessionId) ?? _app;

  Future<void> saveApplication(ImageGenerationOptions options) async {
    options.validate();
    final prefs = await _preferences();
    if (!await prefs.setString(_appKey, jsonEncode(options.toJson()))) {
      throw StateError('Impossible de sauver les options graphiques.');
    }
    _app = options;
    notifyListeners();
  }

  Future<void> saveParty(
      String sessionId, ImageGenerationOptions? override) async {
    if (sessionId.isEmpty) throw ArgumentError.value(sessionId);
    override?.validate();
    final prefs = await _preferences();
    final success = override == null
        ? await prefs.remove(_sessionPrefix + sessionId)
        : await prefs.setString(
            _sessionPrefix + sessionId, jsonEncode(override.toJson()));
    if (!success) throw StateError('Options de Partie non enregistrées.');
    _parties[sessionId] = override;
    notifyListeners();
  }
}
