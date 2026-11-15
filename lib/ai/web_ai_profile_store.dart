import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'ai_provider.dart';

/// Browser profile metadata is durable; API credentials are session-only.
///
/// Never serialize apiKey into SharedPreferences, which is backed by browser
/// storage readable by same-origin scripts. On refresh users must re-enter keys.
/// A future encrypted design must be reviewed independently before replacing
/// this conservative default.
class WebAiProfileStore implements AiProfileStore {
  static const storageKey = 'domolia.web.ai.profiles.v1';
  AiProfilesState? _currentSession;

  @override
  Future<AiProfilesState?> read() async {
    if (_currentSession != null) return _currentSession;

    final json = (await SharedPreferences.getInstance()).getString(storageKey);
    if (json == null) return null;

    final dynamic data = jsonDecode(json);
    if (data is! Map<String, dynamic> ||
        data['version'] != 1 ||
        data['selectedId'] is! String ||
        data['profiles'] is! List) {
      throw const FormatException('Métadonnées de profils IA invalides.');
    }
    final profiles = <AiProfile>[];
    for (final item in data['profiles'] as List) {
      if (item is! Map<String, dynamic> ||
          item['id'] is! String || item['name'] is! String ||
          item['baseUrl'] is! String || item['model'] is! String ||
          item['providerType'] is! String ||
          item['nsfwCompatibility'] is! String) {
        throw const FormatException('Profil IA Web illisible.');
      }
      final kind = AiProviderKind.values
          .where((value) => value.name == item['providerType'])
          .firstOrNull;
      final compatibility = AiNsfwCompatibility.values
          .where((value) => value.name == item['nsfwCompatibility'])
          .firstOrNull;
      if (kind == null || compatibility == null) {
        throw const FormatException('Fournisseur IA Web inconnu.');
      }
      profiles.add(AiProfile(
        id: item['id'] as String,
        name: item['name'] as String,
        kind: kind,
        nsfwCompatibility: compatibility,
        baseUrl: item['baseUrl'] as String,
        model: item['model'] as String,
        apiKey: '', // Explicitly not restored from IndexedDB/localStorage.
      ));
    }
    final result = AiProfilesState(
      profiles: List<AiProfile>.unmodifiable(profiles),
      selectedId: data['selectedId'] as String,
    );
    _validate(result);
    return _currentSession = result;
  }

  @override
  Future<void> write(AiProfilesState state) async {
    _validate(state);
    final json = jsonEncode({
      'version': 1,
      'selectedId': state.selectedId,
      'profiles': [
        for (final profile in state.profiles)
          {
            'id': profile.id,
            'name': profile.name,
            'providerType': profile.kind.name,
            'nsfwCompatibility': profile.nsfwCompatibility.name,
            'baseUrl': profile.baseUrl,
            'model': profile.model,
            // The apiKey field must NEVER be added here.
          },
      ],
    });
    final stored = await (await SharedPreferences.getInstance())
        .setString(storageKey, json);
    if (!stored) {
      throw StateError('Métadonnées des profils IA non sauvegardées.');
    }
    _currentSession = state;
  }

  static void _validate(AiProfilesState state) {
    final ids = state.profiles.map((p) => p.id).toList();
    if (ids.isEmpty || ids.toSet().length != ids.length ||
        !ids.contains(state.selectedId) ||
        state.profiles.any((profile) =>
            profile.id.trim().isEmpty || profile.name.trim().isEmpty)) {
      throw const FormatException('Profils IA Web incohérents.');
    }
  }
}
