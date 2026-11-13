import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ai_provider.dart';

/// Android: AES-GCM for values, with the wrapping key held in Android Keystore.
/// No credentials are ever written to normal SharedPreferences or SQLite.
class SecureAiConfigurationStore implements AiConfigurationStore {
  SecureAiConfigurationStore({FlutterSecureStorage? storage})
      : _storage = storage ?? FlutterSecureStorage();

  static const _key = 'domolia.ai.connection.v1';
  final FlutterSecureStorage _storage;

  @override
  Future<AiConfiguration?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic> ||
        data['baseUrl'] is! String ||
        data['model'] is! String ||
        data['apiKey'] is! String) {
      throw const FormatException('Configuration IA illisible.');
    }
    return AiConfiguration(
      baseUrl: data['baseUrl'] as String,
      model: data['model'] as String,
      apiKey: data['apiKey'] as String,
    );
  }

  @override
  Future<void> write(AiConfiguration configuration) =>
      _storage.write(key: _key, value: jsonEncode({
        'baseUrl': configuration.baseUrl,
        'model': configuration.model,
        'apiKey': configuration.apiKey,
      }));
}
