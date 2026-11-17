import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// No credentials or book canon are stored here, only profile references.
class ImageGenerationOptions {
  const ImageGenerationOptions({
    this.profileId = '',
    this.directorProfileId = '',
    this.model = '',
    this.size = '1024x1024',
    this.quality,
    this.style = 'illustration cinématographique',
    this.count = 1,
    this.maximumCostUsd,
  });
  final String profileId, directorProfileId, model, size, style;
  final String? quality;
  final int count;
  final double? maximumCostUsd;

  ImageGenerationOptions copyWith({
    String? profileId, String? directorProfileId, String? model,
    String? size, String? quality, bool clearQuality = false,
    String? style, int? count, double? maximumCostUsd,
    bool clearMaximumCost = false,
  }) => ImageGenerationOptions(
    profileId: profileId ?? this.profileId,
    directorProfileId: directorProfileId ?? this.directorProfileId,
    model: model ?? this.model,
    size: size ?? this.size,
    quality: clearQuality ? null : quality ?? this.quality,
    style: style ?? this.style,
    count: count ?? this.count,
    maximumCostUsd: clearMaximumCost ? null
        : maximumCostUsd ?? this.maximumCostUsd,
  );

  Map<String, dynamic> toJson() => {
    'profileId': profileId, 'directorProfileId': directorProfileId,
    'model': model, 'size': size, 'quality': quality, 'style': style,
    'count': count, 'maximumCostUsd': maximumCostUsd,
  };

  factory ImageGenerationOptions.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Options d’illustration invalides.');
    }
    final cost = value['maximumCostUsd'];
    final result = ImageGenerationOptions(
      profileId: value['profileId'] as String? ?? '',
      directorProfileId: value['directorProfileId'] as String? ?? '',
      model: value['model'] as String? ?? '',
      size: value['size'] as String? ?? '1024x1024',
      quality: value['quality'] as String?,
      style: value['style'] as String? ?? 'illustration cinématographique',
      count: value['count'] as int? ?? 1,
      maximumCostUsd: cost is num ? cost.toDouble() : null,
    );
    result.validate();
    return result;
  }

  void validate() {
    if (profileId.length > 150 || directorProfileId.length > 150 ||
        model.length > 100 || size.length > 30 ||
        style.trim().isEmpty || style.length > 160 ||
        count < 1 || count > 4 ||
        (quality != null && quality!.length > 30) ||
        (maximumCostUsd != null &&
            (maximumCostUsd! <= 0 || maximumCostUsd! > 100))) {
      throw const FormatException('Options de génération d’images invalides.');
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
