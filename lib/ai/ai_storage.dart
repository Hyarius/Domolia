import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ai_provider.dart';

/// Entire profile collection, including all secrets, is stored in encrypted
/// Android storage backed by Android Keystore. No profile keys are persisted
/// in unencrypted preferences, logs or crash reports.
class SecureAiProfileStore implements AiProfileStore {
  SecureAiProfileStore({FlutterSecureStorage? storage})
      : _storage = storage ?? FlutterSecureStorage();

  static const _profilesKey = 'domolia.ai.profiles.v2';
  static const _legacyKey = 'domolia.ai.connection.v1';
  final FlutterSecureStorage _storage;

  @override
  Future<AiProfilesState?> read() async {
    final raw = await _storage.read(key: _profilesKey);
    if (raw != null) return _decode(raw);

    // One-time migration from the single connection used by earlier PR03
    // builds. Write the new encrypted record before deleting the old one,
    // so a failed migration never destroys the existing credentials.
    final legacy = await _storage.read(key: _legacyKey);
    if (legacy == null) return null;
    final value = jsonDecode(legacy);
    if (value is! Map<String, dynamic> ||
        value['baseUrl'] is! String ||
        value['model'] is! String ||
        value['apiKey'] is! String) {
      throw const FormatException('Ancienne configuration IA illisible.');
    }

    final migrated = AiProfilesState(
      selectedId: 'migrated-default',
      profiles: [
        AiProfile(
          id: 'migrated-default',
          name: 'OpenUncensored',
          baseUrl: value['baseUrl'] as String,
          model: value['model'] as String,
          apiKey: value['apiKey'] as String,
        kind: AiProviderKind.customAi,
        ),
      ],
    );
    await write(migrated);
    await _storage.delete(key: _legacyKey);
    return migrated;
  }

  AiProfilesState _decode(String raw) {
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic> ||
        data['selectedId'] is! String ||
        data['profiles'] is! List) {
      throw const FormatException('Profils IA illisibles.');
    }
    final profiles = <AiProfile>[];
    final ids = <String>{};
    for (final item in data['profiles'] as List) {
      if (item is! Map<String, dynamic> ||
          item['id'] is! String ||
          item['name'] is! String ||
          item['baseUrl'] is! String ||
          item['model'] is! String ||
          item['apiKey'] is! String) {
        throw const FormatException('Profil IA illisible.');
      }
      final id = item['id'] as String;
      if (id.isEmpty || !ids.add(id)) {
        throw const FormatException('Identifiants de profils IA invalides.');
      }
      profiles.add(AiProfile(
        id: id,
        name: item['name'] as String,
        baseUrl: item['baseUrl'] as String,
        model: item['model'] as String,
        apiKey: item['apiKey'] as String,
        kind: item['providerType'] == 'chatgpt'
            ? AiProviderKind.chatGpt
            : AiProviderKind.customAi,
      ));
    }
    final selectedId = data['selectedId'] as String;
    if (profiles.isEmpty || !ids.contains(selectedId)) {
      throw const FormatException('Sélection du profil IA invalide.');
    }
    return AiProfilesState(profiles: profiles, selectedId: selectedId);
  }

  @override
  Future<void> write(AiProfilesState state) async {
    if (state.profiles.isEmpty ||
        !state.profiles.any((profile) => profile.id == state.selectedId) ||
        state.profiles.map((profile) => profile.id).toSet().length !=
            state.profiles.length) {
      throw const FormatException('Collection de profils IA invalide.');
    }
    await _storage.write(
      key: _profilesKey,
      value: jsonEncode({
        'selectedId': state.selectedId,
        'profiles': [
          for (final profile in state.profiles)
            {
              'id': profile.id,
              'name': profile.name,
              'providerType': profile.kind == AiProviderKind.chatGpt
                  ? 'chatgpt' : 'customai',
              'baseUrl': profile.baseUrl,
              'model': profile.model,
              'apiKey': profile.apiKey,
            },
        ],
      }),
    );
  }
}
