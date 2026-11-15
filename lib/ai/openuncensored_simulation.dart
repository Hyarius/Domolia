import 'package:flutter/foundation.dart';

import 'ai_controller.dart';
import 'ai_provider.dart';
import 'ai_task_routing.dart';
import 'openuncensored_api.dart';
import 'openuncensored_controller.dart';
import 'openuncensored_vault.dart';

/// Only debug APKs and explicitly flagged preview branches expose this.
/// Main and production tags never receive DOMOLIA_PAYMENT_SANDBOX=true.
const bool openUncensoredSimulationEnabled =
    !kIsWeb && (kDebugMode ||
        bool.fromEnvironment('DOMOLIA_PAYMENT_SANDBOX', defaultValue: false));

/// No HTTP client method is invoked in this fake API. It explicitly rejects
/// real OpenUncensored keys and never opens a Stripe page.
class SimulatedOpenUncensoredApi extends OpenUncensoredApi {
  SimulatedOpenUncensoredApi(this.vault);
  final OuVaultStore vault;
  final Map<String, double> _balances = {};
  String? _session;
  String? _claim;
  String? _topUpKey;
  int _cents = 0;
  int _sequence = 0;
  bool _settled = false;
  OuCheckoutStatus outcome = OuCheckoutStatus.pending;

  @override
  Future<OuBalance> balance(String key) async {
    if (!key.startsWith('ou-demo-')) {
      throw const OpenUncensoredFailure(
          'Simulation : seules les clés fictives sont acceptées.');
    }
    final cached = (await vault.read()).find(ouKeyId(key))?.lastBalance;
    final usd = _balances[key] ?? cached?.remainingUsd ?? 0.0;
    return OuBalance(remainingUsd: usd, balanceUsd: usd, pendingUsd: 0);
  }

  @override
  Future<List<OuModel>> models() async => const [
    OuModel(
      id: 'domolia-demo-narrator',
      available: true,
      toolCompatible: true,
      inputPerTokenUsd: 0,
      outputPerTokenUsd: 0,
    ),
    OuModel(
      id: 'domolia-demo-jsonifier',
      available: true,
      toolCompatible: false,
      inputPerTokenUsd: 0,
      outputPerTokenUsd: 0,
    ),
  ];

  @override
  Future<OuCheckout> checkout({required int cents, String? topUpKey}) async {
    if (cents < 500 || cents > 100000 ||
        (topUpKey != null && !topUpKey.startsWith('ou-demo-'))) {
      throw const OpenUncensoredFailure('Montant ou clé fictive invalide.');
    }
    _sequence++;
    _session = 'cs_test_domolia_' +
        DateTime.now().microsecondsSinceEpoch.toString() + '_$_sequence';
    _claim = 'domolia-sandbox-claim-$_sequence';
    _topUpKey = topUpKey;
    _cents = cents;
    _settled = false;
    outcome = OuCheckoutStatus.pending;
    // This URL is never launched: the UI handles sandbox sessions in place.
    return OuCheckout(_session!, _claim!,
        Uri.parse('https://checkout.stripe.com/c/pay/simulation-only'));
  }

  /// Called when reopening the sandbox after an app restart. The claim token
  /// and target are read exclusively from the separate simulation vault.
  Future<void> recover(PendingOuCheckout? pending) async {
    if (pending == null) return;
    _session = pending.sessionId;
    _claim = pending.claimToken;
    _cents = pending.cents;
    _topUpKey = (await vault.read()).find(pending.targetKeyId)?.secret;
    _settled = false;
    outcome = OuCheckoutStatus.pending;
  }

  void selectOutcome(OuCheckoutStatus next) {
    if (next == OuCheckoutStatus.pending) {
      throw ArgumentError('Select a terminal outcome.');
    }
    outcome = next;
  }

  @override
  Future<OuCheckoutResult> check(String sessionId, String claimToken) async {
    if (_session != sessionId || _claim != claimToken) {
      throw const OpenUncensoredFailure('Session fictive introuvable.');
    }
    if (outcome != OuCheckoutStatus.paid) {
      return OuCheckoutResult(outcome);
    }
    if (!_settled) {
      final key = _topUpKey ?? _issuedKey();
      final old = await balance(key);
      _balances[key] = old.remainingUsd + _cents / 100;
      _settled = true;
    }
    return OuCheckoutResult(
      OuCheckoutStatus.paid,
      apiKey: _topUpKey == null ? _issuedKey() : null,
      balanceCents: _cents,
    );
  }

  String _issuedKey() => 'ou-demo-' + _session!.replaceFirst('cs_test_', '');
}

class _SandboxProfiles implements AiProfileStore {
  AiProfilesState? state;
  @override
  Future<AiProfilesState?> read() async => state;
  @override
  Future<void> write(AiProfilesState next) async { state = next; }
}

class _NoNetworkProvider implements AiChatProvider {
  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async => [];

  @override
  Future<String> complete(AiConfiguration configuration, {
    required List<AiMessage> messages, int maxTokens = 512,
  }) async => throw const AiProviderException(
    'Les clés fictives ne peuvent générer aucun texte.');
}

/// Never reads or updates the production SharedPreferences task routing.
class _SandboxRouting extends AiTaskRouting {
  final Map<AiNarrativeTask, String?> _profiles = {};
  final Map<AiNarrativeTask, AiTaskGenerationSettings> _settings = {};

  @override
  Future<void> initialize() async { initialized = true; }

  @override
  String? profileFor(AiNarrativeTask task) => _profiles[task];

  @override
  Future<void> setProfile(AiNarrativeTask task, String? id) async {
    _profiles[task] = id;
    notifyListeners();
  }

  @override
  AiTaskGenerationSettings generationFor(AiNarrativeTask task) =>
      _settings[task] ?? AiTaskGenerationSettings.defaults(task);

  @override
  Future<void> setGeneration(AiNarrativeTask task,
      AiTaskGenerationSettings settings) async {
    settings.validate();
    _settings[task] = settings;
    notifyListeners();
  }
}

/// The complete demo environment is isolated from both real AI profiles and
/// real API credentials. Only fake history uses a separate encrypted key.
class OpenUncensoredSandbox {
  OpenUncensoredSandbox({OuVaultStore? vault})
      : vault = vault ?? SecureOuVaultStore(
          storageKey: 'domolia.openuncensored.sandbox.v1') {
    api = SimulatedOpenUncensoredApi(this.vault);
    ai = AiConnectionController(
        store: _SandboxProfiles(), provider: _NoNetworkProvider());
    routing = _SandboxRouting();
    controller = OuCreditsController(
      api: api, vault: this.vault, ai: ai, routing: routing);
  }

  final OuVaultStore vault;
  late final SimulatedOpenUncensoredApi api;
  late final AiConnectionController ai;
  late final AiTaskRouting routing;
  late final OuCreditsController controller;

  Future<void> initialize() async {
    await controller.initialize();
    await api.recover(controller.pending);
  }

  void dispose() {
    controller.dispose();
    ai.dispose();
    routing.dispose();
  }
}
