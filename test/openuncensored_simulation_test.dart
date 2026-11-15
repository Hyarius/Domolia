import 'package:domolia/ai/openuncensored_api.dart';
import 'package:domolia/ai/openuncensored_simulation.dart';
import 'package:domolia/ai/openuncensored_vault.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestVault implements OuVaultStore {
  OuVaultState state = const OuVaultState();
  @override
  Future<OuVaultState> read() async => OuVaultState.fromJson(state.toJson());
  @override
  Future<void> write(OuVaultState next) async {
    state = OuVaultState.fromJson(next.toJson());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Fake payment issues a key without network or a real Stripe session', () async {
    final vault = _TestVault();
    final sandbox = OpenUncensoredSandbox(vault: vault);
    await sandbox.initialize();
    expect(sandbox.controller.keys, isEmpty);
    final url = await sandbox.controller.startCheckout(1000);
    expect(url!.host, 'checkout.stripe.com');
    expect(sandbox.controller.pending, isNotNull);
    expect(await sandbox.controller.checkPending(), OuCheckoutStatus.pending);
    sandbox.api.selectOutcome(OuCheckoutStatus.paid);
    expect(await sandbox.controller.checkPending(), OuCheckoutStatus.paid);
    expect(sandbox.controller.keys, hasLength(1));
    expect(sandbox.controller.active!.secret, startsWith('ou-demo-'));
    expect(sandbox.controller.active!.lastBalance!.remainingUsd, 10);
    expect(sandbox.controller.pending, isNull);
    sandbox.dispose();

    final restarted = OpenUncensoredSandbox(vault: vault);
    await restarted.initialize();
    expect(restarted.controller.keys, hasLength(1));
    expect(restarted.controller.active!.lastBalance!.remainingUsd, 10);
    expect(await restarted.controller.activate(restarted.controller.keys.single.id), true);
    restarted.dispose();
  });

  test('Refused and expired fake sessions cannot create keys', () async {
    final sandbox = OpenUncensoredSandbox(vault: _TestVault());
    await sandbox.initialize();
    await sandbox.controller.startCheckout(500);
    sandbox.api.selectOutcome(OuCheckoutStatus.refused);
    expect(await sandbox.controller.checkPending(), OuCheckoutStatus.refused);
    expect(sandbox.controller.pending, isNull);
    expect(sandbox.controller.keys, isEmpty);
    await sandbox.controller.startCheckout(1000);
    sandbox.api.selectOutcome(OuCheckoutStatus.expired);
    expect(await sandbox.controller.checkPending(), OuCheckoutStatus.expired);
    expect(sandbox.controller.pending, isNull);
    expect(sandbox.controller.keys, isEmpty);
    sandbox.dispose();
  });

  test('Top-ups stay on selected fake key after changing active history', () async {
    final sandbox = OpenUncensoredSandbox(vault: _TestVault());
    await sandbox.initialize();
    await sandbox.controller.startCheckout(500);
    sandbox.api.selectOutcome(OuCheckoutStatus.paid);
    await sandbox.controller.checkPending();
    final first = sandbox.controller.active!;
    await sandbox.controller.startCheckout(1000);
    sandbox.api.selectOutcome(OuCheckoutStatus.paid);
    await sandbox.controller.checkPending();
    final second = sandbox.controller.active!;
    expect(sandbox.controller.keys, hasLength(2));
    await sandbox.controller.startCheckout(2500, topUpKeyId: first.id);
    sandbox.api.selectOutcome(OuCheckoutStatus.paid);
    expect(await sandbox.controller.checkPending(), OuCheckoutStatus.paid);
    expect(sandbox.controller.keys.firstWhere((k) => k.id == first.id)
        .lastBalance!.remainingUsd, 30);
    expect(sandbox.controller.keys.firstWhere((k) => k.id == second.id)
        .lastBalance!.remainingUsd, 10);
    expect(sandbox.controller.active!.id, second.id);
    expect(await sandbox.controller.activate(first.id), true);
    expect(sandbox.controller.active!.lastBalance!.remainingUsd, 30);
    sandbox.dispose();
  });

  test('Pending fake checkout resumes after restart without real keys', () async {
    final vault = _TestVault();
    final first = OpenUncensoredSandbox(vault: vault);
    await first.initialize();
    await first.controller.startCheckout(500);
    first.dispose();
    final second = OpenUncensoredSandbox(vault: vault);
    await second.initialize();
    expect(second.controller.pending, isNotNull);
    expect(await second.controller.checkPending(), OuCheckoutStatus.pending);
    second.api.selectOutcome(OuCheckoutStatus.paid);
    expect(await second.controller.checkPending(), OuCheckoutStatus.paid);
    expect(second.controller.active!.secret, startsWith('ou-demo-'));
    second.dispose();
  });

  test('Sandbox does not accept or import real key strings', () async {
    final sandbox = OpenUncensoredSandbox(vault: _TestVault());
    await sandbox.initialize();
    expect(await sandbox.controller.importKey('ou-cus_REAL_ACCOUNT_12345'), false);
    expect(sandbox.controller.keys, isEmpty);
    expect(sandbox.controller.error, contains('fictives'));
    sandbox.dispose();
  });
}
