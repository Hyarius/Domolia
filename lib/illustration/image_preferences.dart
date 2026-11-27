import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/ai_provider.dart';

/// A scene director must support text generation. A dedicated image-only
/// OpenAI API profile cannot be used for scene interpretation.
bool canDirectImages(AiProfile profile) {
  if (profile.kind == AiProviderKind.chatGpt) {
    return profile.model.trim().isNotEmpty;
  }
  return profile.kind == AiProviderKind.customAi &&
      profile.apiKey.trim().isNotEmpty &&
      profile.model.trim().isNotEmpty &&
      !profile.model.startsWith('gpt-image-') &&
      profile.model != 'chatgpt-image-latest';
}

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

  /// Empty fields mean automatic routing. Resolve only when making a
  /// request; never overwrite explicit per-Party choices.
  ImageGenerationOptions resolveProfiles(Iterable<AiProfile> profiles, {bool nsfw = false}) {
    final all = profiles.toList();
    bool imageCapable(AiProfile profile) {
      final uri = Uri.tryParse(profile.baseUrl);
      return profile.kind == AiProviderKind.customAi &&
          profile.apiKey.trim().isNotEmpty &&
          uri?.scheme == 'https' &&
          const {
            'api.openuncensored.com', 'openuncensored.com',
            'api.openai.com',
          }.contains(uri?.host);
    }
    final ready = all.where(imageCapable).toList();
    // An explicit image profile must never silently fall back to another
    // provider when its API key is missing or its connection fails.
    final selected = profileId.isEmpty ? null :
        all.where((profile) => profile.id == profileId).firstOrNull;
    AiProfile? imageProfile = selected;
    if (profileId.isEmpty) {
      const priorities = ['openuncensored-managed-narrator', 'default'];
      for (final id in priorities) {
        for (final profile in ready) {
          if (profile.id == id &&
              profile.baseUrl.contains('openuncensored.com')) {
            imageProfile = profile;
            break;
          }
        }
        if (imageProfile != null) break;
      }
    }
    imageProfile ??= ready.where((profile) =>
      profile.baseUrl.contains('openuncensored.com')).firstOrNull ??
        ready.firstOrNull;

    var director = directorProfileId;
    if (!all.any((profile) =>
        profile.id == director && canDirectImages(profile))) {
      final candidates = all.where(canDirectImages).toList();
      final preferred = candidates.where((profile) =>
          profile.id == 'openuncensored-managed-narrator').firstOrNull;
      // A ChatGPT conversation profile is a valid art director and is
      // preferable to sending a text completion through an image-only key.
      final chatGpt = candidates.where((profile) =>
          profile.kind == AiProviderKind.chatGpt).firstOrNull;
      final sameImageProvider = candidates.where((profile) =>
          profile.id == imageProfile?.id).firstOrNull;
      final adultDirector = nsfw ? candidates.where((profile) =>
          profile.nsfwCompatibility == AiNsfwCompatibility.supported).firstOrNull : null;
      director = (adultDirector ?? preferred ?? chatGpt ??
          sameImageProvider ?? candidates.firstOrNull)?.id ?? '';
    }
    return ImageGenerationOptions(
      profileId: profileId.isNotEmpty ? profileId : imageProfile?.id ?? '',
      directorProfileId: director,
      model: model,
    );
  }

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
