import 'dart:convert';

import 'package:domolia/ai/ai_controller.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/ai_task_routing.dart';
import 'package:domolia/ai/openuncensored_api.dart';
import 'package:domolia/ai/openuncensored_controller.dart';
import 'package:domolia/ai/openuncensored_vault.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const keyA = 'ou-cus_TEST_ALPHA_123456';
const keyB = 'ou-cus_TEST_BRAVO_654321';

http.Response jsonOk(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status);

class FakeVault implements OuVaultStore {
  OuVaultState state = const OuVaultState();
  bool rejectWrites = false;
  @override
  Future<OuVaultState> read() async => OuVaultState.fromJson(state.toJson());
  @override
  Future<void> write(OuVaultState next) async {
    if (rejectWrites) throw StateError('secret failure detail');
    state = OuVaultState.fromJson(next.toJson());
  }
}

class FakeProfiles implements AiProfileStore {
  AiProfilesState? state;
  @override
  Future<AiProfilesState?> read() async => state;
  @override
  Future<void> write(AiProfilesState value) async => state = value;
}

class NoopProvider implements AiChatProvider {
  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => [];
  @override
  Future<String> complete(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 64,
  }) async => 'No paid traffic allowed';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeVault vault;
  late FakeProfiles profiles;
  late AiConnectionController ai;
  late AiTaskRouting routing;
  late OuCreditsController controller;
  late Map<String, double> balances;
  late int paymentsCreated;
  late int checks;
  bool paid = false;
  bool expired = false;
  bool missClaimedKey = false;
  bool offline = false;
  String? checkoutTarget;

  void attach() {
    final api = OpenUncensoredApi(client: MockClient((request) async {
      if (offline) throw http.ClientException('offline: secret');
      final uri = request.url;
      if (uri.path == '/v1/credits') {
        final key = request.headers['Authorization']!.substring(7);
        if (!balances.containsKey(key)) return jsonOk({'error': 'invalid'}, 401);
        final value = balances[key]!;
        return jsonOk({'object':'credits', 'data': {
          'remaining_usd': value,
          'balance_usd': value,
          'pending_usage_usd': 0, 'currency': 'usd',
        }});
      }
      if (uri.path == '/v1/models') {
        return jsonOk({'data': [
          {'id': defaultAiModel, 'modality': 'text', 'available': true,
            'supports_tools': true,
            'pricing': {'prompt':'0.000001','completion':'0.000002'}},
          {'id': 'cheap-json-model', 'modality': 'text', 'available': true,
            'pricing': {'prompt':'0.0000001','completion':'0.0000002'}},
        ]});
      }
      if (uri.path == '/api/agent/checkout' && request.method == 'POST') {
        paymentsCreated++;
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        checkoutTarget = payload['key'] as String?;
        return jsonOk({
          'session_id':'cs_test_123',
          'claim_token':'claim-token-never-log',
          'payment_url':'https://checkout.stripe.com/c/pay/test',
        });
      }
      if (uri.path == '/api/agent/checkout/cs_test_123') {
        checks++;
        if (expired) return jsonOk({'status': 'expired'});
        if (!paid) return jsonOk({'status': 'pending'});
        return jsonOk({
          'status': 'paid',
          if (checkoutTarget == null && !missClaimedKey) 'api_key': keyB,
          'balance_cents': 1000,
        });
      }
      return jsonOk({}, 404);
    }));
    controller = OuCreditsController(
      api: api, vault: vault, ai: ai, routing: routing);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    vault = FakeVault();
    profiles = FakeProfiles();
    ai = AiConnectionController(store: profiles, provider: NoopProvider());
    routing = AiTaskRouting();
    balances = {keyA: 5, keyB: 10};
    paymentsCreated = 0;
    checks = 0;
    paid = false;
    expired = false;
    missClaimedKey = false;
    offline = false;
    checkoutTarget = null;
    attach();
  });
  tearDown(() {
    controller.dispose();
    ai.dispose();
    routing.dispose();
  });

  test('Empty first launch and import creates encrypted history and task profiles', () async {
    await controller.initialize();
    expect(controller.active, null);
    expect(await controller.importKey(keyA), true);
    expect(controller.active!.secret, keyA);
    expect(controller.active!.lastBalance!.remainingUsd, 5);
    expect(ai.selectedProfileId, AiConnectionController.ouNarratorProfileId);
    expect(profiles.state!.profiles.where(
      (item) => item.id.startsWith('openuncensored-managed-')), hasLength(3));
    expect(routing.profileFor(AiNarrativeTask.jsonifier),
        AiConnectionController.ouJsonifierProfileId);
  });

  test('Managed narrator uses explicit catalogue tool capability', () async {
    await controller.importKey(keyA);
    AiProfile narrator() => ai.profiles.firstWhere(
      (p) => p.id == AiConnectionController.ouNarratorProfileId);
    expect(narrator().model, defaultAiModel);
    expect(narrator().toolCallingCompatibility,
        AiToolCallingCompatibility.supported);

    await controller.importKey(keyB);
    expect(narrator().toolCallingCompatibility,
        AiToolCallingCompatibility.supported);

    // Switching to a model not advertised as tool-compatible must disable
    // native tool calls, even if the prior model supported them.
    expect(await ai.configureOpenUncensored(keyB,
      narratorModel: 'cheap-json-model',
      jsonifierModel: 'cheap-json-model',
      optimizerModel: 'cheap-json-model',
      narratorToolsSupported: false,
    ), true);
    expect(narrator().toolCallingCompatibility,
        AiToolCallingCompatibility.unknown);

    // An unavailable catalogue must not erase a previously verified
    // declaration when the exact same model remains selected.
    expect(await ai.configureOpenUncensored(keyB,
      narratorModel: defaultAiModel,
      jsonifierModel: 'cheap-json-model',
      optimizerModel: 'cheap-json-model',
      narratorToolsSupported: true,
    ), true);
    expect(await ai.configureOpenUncensored(keyB,
      narratorModel: defaultAiModel,
      jsonifierModel: 'cheap-json-model',
      optimizerModel: 'cheap-json-model',
    ), true);
    expect(narrator().toolCallingCompatibility,
        AiToolCallingCompatibility.supported);
  });

  test('Replacements keep all keys and allow activation from history', () async {
    await controller.importKey(keyA);
    await controller.importKey(keyB);
    expect(controller.keys, hasLength(2));
    expect(controller.active!.secret, keyB);
    expect(await controller.activate(ouKeyId(keyA)), true);
    expect(controller.active!.secret, keyA);
    expect(controller.keys.firstWhere((k) => k.id == ouKeyId(keyB))
      .lastBalance!.remainingUsd, 10);
  });

  test('Key history survives a controller restart without revealing details in UI', () async {
    await controller.importKey(keyA);
    await controller.rename(ouKeyId(keyA), 'Mon budget');
    final stored = await vault.read();
    expect(stored.keys.single.name, 'Mon budget');
    expect(stored.keys.single.masked, startsWith('ou-••••'));
    controller.dispose();
    attach();
    await controller.initialize();
    expect(controller.keys.single.secret, keyA);
    expect(controller.keys.single.name, 'Mon budget');
  });

  test('Failed activation preserves previously selected key', () async {
    await controller.importKey(keyA);
    offline = true;
    expect(await controller.importKey(keyB), false);
    expect(controller.active!.secret, keyA);
    expect(controller.keys, hasLength(1));
  });

  test('Pending payment resumes after restart, paid claim is saved once', () async {
    await controller.initialize();
    final paymentUrl = await controller.startCheckout(1000);
    expect(paymentUrl!.host, 'checkout.stripe.com');
    expect(vault.state.pending?.claimToken, 'claim-token-never-log');
    controller.dispose();
    attach();
    await controller.initialize();
    expect(controller.pending, isNotNull);
    expect(await controller.checkPending(), OuCheckoutStatus.pending);
    paid = true;
    expect(await controller.checkPending(), OuCheckoutStatus.paid);
    expect(controller.active!.secret, keyB);
    expect(controller.pending, null);
    expect(await controller.checkPending(), null);
    expect(checks, 2);
    expect(paymentsCreated, 1);
  });

  test('Payment expiry keeps key history unchanged', () async {
    await controller.startCheckout(500);
    expired = true;
    expect(await controller.checkPending(), OuCheckoutStatus.expired);
    expect(controller.keys, isEmpty);
    expect(controller.pending, null);
  });

  test('Top up keeps original target even after active key changes', () async {
    await controller.importKey(keyA);
    await controller.importKey(keyB);
    expect(await controller.startCheckout(1000, topUpKeyId: ouKeyId(keyA)),
      isNotNull);
    expect(checkoutTarget, keyA);
    expect(controller.pending!.targetKeyId, ouKeyId(keyA));
    paid = true;
    balances[keyA] = 15;
    expect(await controller.checkPending(), OuCheckoutStatus.paid);
    expect(controller.active!.secret, keyB);
    expect(controller.keys.firstWhere((item) => item.id == ouKeyId(keyA))
      .lastBalance!.remainingUsd, 15);
  });

  test('Cannot create concurrent checkouts, including after interrupted purchase', () async {
    await controller.startCheckout(1000);
    expect(await controller.startCheckout(500), null);
    expect(paymentsCreated, 1);
    expect(controller.pending, isNotNull);
    expect(await controller.abandonPending(), true);
  });

  test('Paid without one-time API key does not silently claim success', () async {
    await controller.startCheckout(1000);
    paid = true;
    missClaimedKey = true;
    expect(await controller.checkPending(), null);
    expect(controller.pending, isNotNull);
    expect(controller.active, null);
  });

  test('Storage failure on paid claim exposes emergency recovery only', () async {
    await controller.startCheckout(1000);
    paid = true;
    vault.rejectWrites = true;
    expect(await controller.checkPending(), null);
    expect(controller.hasEmergencyKey, true);
    expect(controller.emergencyKeyForManualRecovery(), keyB);
    expect(vault.state.pending, isNotNull);
    expect(controller.error, isNot(contains(keyB)));
  });

  test('Unexpected checkout status and network errors do not destroy a key', () async {
    await controller.importKey(keyA);
    offline = true;
    expect(await controller.refresh(ouKeyId(keyA)), false);
    expect(controller.active!.secret, keyA);
    expect(controller.keys.single.lastBalance!.remainingUsd, 5);
  });

  test('Preset selection follows catalogue and preserves per-task token budgets', () async {
    await controller.importKey(keyA);
    await routing.setGeneration(AiNarrativeTask.narrator,
      const AiTaskGenerationSettings(maxOutputTokens: 16384));
    expect(await controller.setPreset(OuQuality.economical), true);
    expect(controller.taskModels['jsonifier'], 'cheap-json-model');
    expect(routing.profileFor(AiNarrativeTask.optimizer), '#disabled');
    expect(routing.generationFor(AiNarrativeTask.narrator).maxOutputTokens, 16384);
    await controller.setPreset(OuQuality.balanced);
    expect(controller.taskModels['narrator'], defaultAiModel);
  });

  test('Advanced narrator requires explicit tool compatibility', () async {
    await controller.importKey(keyA);
    await controller.loadModels();
    expect(await controller.setAdvanced({
      'narrator': 'cheap-json-model',
      'jsonifier': 'cheap-json-model',
      'optimizer': 'cheap-json-model',
    }), false);
    expect(controller.error, contains('tool calling'));
  });

  test('Legacy profile is preserved during managed OpenUncensored activation', () async {
    profiles.state = const AiProfilesState(
      selectedId: 'old-profile',
      profiles: [AiProfile(
        id:'old-profile', name:'Legacy', baseUrl:'https://old.example/v1',
        model:'old-model', apiKey:'old-secret',
      )],
    );
    await controller.initialize();
    await controller.importKey(keyA);
    expect(profiles.state!.profiles.any((p) => p.id == 'old-profile'), true);
    expect(profiles.state!.profiles.first.apiKey, 'old-secret');
  });
}
