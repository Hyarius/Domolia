import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/openuncensored_api.dart';
import 'package:domolia/ai/openuncensored_vault.dart';
import 'package:domolia/settings/app_reset.dart';
import 'package:flutter_test/flutter_test.dart';

class _Profiles implements AiProfileStore {
  _Profiles(this.state, this.events);
  AiProfilesState? state;
  final List<String> events;
  @override
  Future<AiProfilesState?> read() async => state;
  @override
  Future<void> write(AiProfilesState next) async {
    events.add('profiles');
    state = next;
  }
}

class _Vault implements OuVaultStore {
  _Vault(this.state, this.events);
  OuVaultState state;
  final List<String> events;
  @override
  Future<OuVaultState> read() async => state;
  @override
  Future<void> write(OuVaultState next) async {
    events.add('vault');
    state = next;
  }
}

void main() {
  test('Reset retains all API keys but removes customization and local data',
      () async {
    final order = <String>[];
    const ouKey = 'ou-cus_KEEP_THIS_KEY_123456';
    const otherKey = 'sk-another-api-key';
    final vault = _Vault(OuVaultState(
      keys: [
        StoredOuKey(
          id: ouKeyId(ouKey), secret: ouKey,
          addedAt: DateTime.utc(2026, 11, 1), name: 'Ma clé',
          lastBalance: const OuBalance(
            remainingUsd: 9, balanceUsd: 9, pendingUsd: 0),
        ),
      ],
      activeKeyId: ouKeyId(ouKey),
      mode: 'advanced',
      models: const {'narrator': 'old-model'},
      toolChecks: const {'abc': 'supported'},
    ), order);
    final profiles = _Profiles(const AiProfilesState(
      profiles: [
        AiProfile(
          id: 'default', name: 'Ancien réglage',
          baseUrl: defaultAiBaseUrl,
          model: 'old-model', apiKey: ouKey,
        ),
        AiProfile(
          id: 'external', name: 'Autre fournisseur',
          baseUrl: 'https://api.example.org/v1',
          model: 'custom-model', apiKey: otherKey,
        ),
        AiProfile(
          id: 'chatgpt', name: 'ChatGPT',
          baseUrl: 'https://api.openai.com/v1',
          model: 'gpt', apiKey: '',
          kind: AiProviderKind.chatGpt,
        ),
      ],
      selectedId: 'external',
    ), order);
    final reset = AppResetService(
      profiles: profiles, vault: vault,
      clearOtherSecureEntries: () async => order.add('secure'),
      closeDatabase: () async => order.add('close'),
      clearLocalData: () async => order.add('local'),
      clearPreferences: () async => order.add('preferences'),
    );
    await reset.reset();
    expect(order, [
      'vault', 'profiles', 'secure', 'close', 'local', 'preferences',
    ]);
    expect(vault.state.keys.single.secret, ouKey);
    expect(vault.state.keys.single.lastBalance, isNull);
    expect(vault.state.activeKeyId, ouKeyId(ouKey));
    expect(vault.state.pending, isNull);
    expect(vault.state.mode, 'balanced');
    expect(vault.state.models, isEmpty);
    expect(vault.state.toolChecks, isEmpty);
    expect(profiles.state!.selectedId, 'default');
    final saved = profiles.state!.profiles;
    expect(saved.first.apiKey, ouKey);
    expect(saved.first.model, defaultAiModel);
    expect(saved.map((p) => p.id), ['default', 'external']);
    expect(saved.last.apiKey, otherKey);
  });

  test('Pending checkout blocks reset without modifying any storage',
      () async {
    final order = <String>[];
    final vault = _Vault(OuVaultState(
      pending: PendingOuCheckout(
        sessionId: 'checkout', claimToken: 'claim',
        paymentUrl: Uri.parse('https://example.org/checkout'),
        cents: 1000, startedAt: DateTime.utc(2026, 11, 18),
      ),
    ), order);
    final reset = AppResetService(
      vault: vault, profiles: _Profiles(null, order),
      clearOtherSecureEntries: () async => order.add('secure'),
      closeDatabase: () async => order.add('close'),
      clearLocalData: () async => order.add('local'),
      clearPreferences: () async => order.add('preferences'),
    );
    await expectLater(reset.reset(), throwsA(isA<StateError>()));
    expect(order, isEmpty);
  });

  test('No credentials yields a clean default OpenUncensored profile',
      () async {
    final order = <String>[];
    final profiles = _Profiles(null, order);
    final reset = AppResetService(
      vault: _Vault(const OuVaultState(), order),
      profiles: profiles,
      clearOtherSecureEntries: () async => order.add('secure'),
      closeDatabase: () async => order.add('close'),
      clearLocalData: () async => order.add('local'),
      clearPreferences: () async => order.add('preferences'),
    );
    await reset.reset();
    expect(profiles.state!.profiles.single.id, 'default');
    expect(profiles.state!.profiles.single.apiKey, isEmpty);
  });
}
