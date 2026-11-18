import 'package:shared_preferences/shared_preferences.dart';

import '../ai/ai_provider.dart';
import '../ai/ai_storage.dart';
import '../ai/openuncensored_vault.dart';

/// Restores application preferences without deleting any user content.
///
/// Books, Parties, memory, illustrations, diagnostics, logs and downloads are
/// deliberately untouched. API credentials remain in encrypted storage.
/// This operation does not make billable calls or modify remote balances.
class AppResetService {
  AppResetService({
    AiProfileStore? profiles,
    OuVaultStore? vault,
    Future<SharedPreferences> Function()? preferences,
  }) : _profiles = profiles ?? SecureAiProfileStore(),
       _vault = vault ?? SecureOuVaultStore(),
       _preferences = preferences ?? SharedPreferences.getInstance;

  final AiProfileStore _profiles;
  final OuVaultStore _vault;
  final Future<SharedPreferences> Function() _preferences;

  static const _preferenceKeys = <String>{
    'domolia.narrator.settings.v1',
    'domolia.image.settings.v1',
    'aiTaskNarratorProfileId',
    'aiTaskJsonifierProfileId',
    'aiTaskOptimizerProfileId',
    'aiTaskMemoryProfileId',
    'aiDiagnosticsRetentionPerSession',
    'automaticUpdates',
    'updateChannel',
    'aiTaskGeneration-narrator',
    'aiTaskGeneration-jsonifier',
    'aiTaskGeneration-optimizer',
    'aiTaskGeneration-memory',
  };

  static bool _isAppSetting(String key) =>
      _preferenceKeys.contains(key) ||
      key.startsWith('domolia.image.party.');

  static bool _isOpenUncensored(AiProfile profile) {
    final uri = Uri.tryParse(profile.baseUrl);
    return profile.kind == AiProviderKind.customAi &&
        uri?.scheme == 'https' &&
        const {'api.openuncensored.com', 'openuncensored.com'}
            .contains(uri?.host);
  }

  /// Read and validate everything before writing. Never wipe a secure store,
  /// directory or database; preserving keys cannot depend on a later restore.
  Future<void> reset() async {
    final previousVault = await _vault.read();
    if (previousVault.pending != null) {
      throw StateError('Un paiement OpenUncensored est en attente. '
          'Terminez sa vérification avant de réinitialiser les réglages.');
    }
    final previousProfiles = await _profiles.read();
    final prefs = await _preferences();
    final keysToRemove = prefs.getKeys().where(_isAppSetting).toList();

    final oldProfiles = previousProfiles?.profiles ?? const <AiProfile>[];
    final active = previousVault.find(previousVault.activeKeyId) ??
        previousVault.keys.firstOrNull;
    final key = active?.secret ??
        oldProfiles.where((p) => _isOpenUncensored(p) &&
            p.apiKey.trim().isNotEmpty)
            .map((p) => p.apiKey).firstOrNull ?? '';

    final retained = <AiProfile>[];
    var index = 0;
    for (final profile in oldProfiles) {
      if (profile.id != 'default') {
        retained.add(profile);
        continue;
      }
      // Replacing the default must not erase a different API credential.
      if (profile.apiKey.trim().isEmpty ||
          (_isOpenUncensored(profile) && profile.apiKey == key)) {
        continue;
      }
      String newId;
      do {
        newId = 'retained-default-${index++}';
      } while (oldProfiles.any((p) => p.id == newId) ||
          retained.any((p) => p.id == newId));
      retained.add(AiProfile(
        id: newId, name: profile.name, baseUrl: profile.baseUrl,
        model: profile.model, apiKey: profile.apiKey,
        kind: profile.kind,
        nsfwCompatibility: profile.nsfwCompatibility,
        toolCallingCompatibility: profile.toolCallingCompatibility,
      ));
    }

    final nextProfiles = AiProfilesState(
      selectedId: 'default',
      profiles: [
        AiProfile(
          id: 'default', name: 'OpenUncensored',
          baseUrl: defaultAiBaseUrl, model: defaultAiModel,
          apiKey: key,
        ),
        ...retained,
      ],
    );

    // The key history, balances, pending-payment metadata and active key
    // are preserved. Only model presets and cached compatibility reset.
    await _profiles.write(nextProfiles);
    await _vault.write(previousVault.copyWith(
      mode: 'balanced', models: const {}, toolChecks: const {},
    ));

    // Exact allowlist: never clear SharedPreferences wholesale. Future
    // persistent user data must not become collateral damage.
    for (final setting in keysToRemove) {
      if (!await prefs.remove(setting)) {
        throw StateError('Impossible de réinitialiser le réglage $setting.');
      }
    }
  }
}
