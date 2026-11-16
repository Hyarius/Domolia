import 'dart:convert';

import 'package:domolia/ai/ai_controller.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/ai_task_routing.dart';
import 'package:domolia/ai/openuncensored_api.dart';
import 'package:domolia/ai/openuncensored_controller.dart';
import 'package:domolia/ai/openuncensored_credits_page.dart';
import 'package:domolia/ai/openuncensored_vault.dart';
import 'package:domolia/ai/openuncensored_simulation.dart';
import 'package:domolia/theme/domolia_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Profiles implements AiProfileStore {
  AiProfilesState? state;
  @override
  Future<AiProfilesState?> read() async => state;
  @override
  Future<void> write(AiProfilesState next) async { state = next; }
}

class _Vault implements OuVaultStore {
  OuVaultState current = const OuVaultState();
  @override
  Future<OuVaultState> read() async => OuVaultState.fromJson(current.toJson());
  @override
  Future<void> write(OuVaultState next) async {
    current = OuVaultState.fromJson(next.toJson());
  }
}

class _Ai implements AiChatProvider {
  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => [];
  @override
  Future<String> complete(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 64,
  }) async => throw StateError('No paid AI generation in widget tests');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AiConnectionController ai;
  late AiTaskRouting routing;
  late OuCreditsController credits;
  late _Vault vault;
  late int requests;
  late int probes;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    requests = 0;
    probes = 0;
    ai = AiConnectionController(store: _Profiles(), provider: _Ai());
    routing = AiTaskRouting();
    vault = _Vault();
    credits = OuCreditsController(
      vault: vault, ai: ai, routing: routing,
      api: OpenUncensoredApi(client: MockClient((request) async {
        requests++;
        if (request.url.path == '/v1/credits') {
          return http.Response(jsonEncode({'data': {
            'remaining_usd': 3.25, 'balance_usd': 3.3,
            'pending_usage_usd': 0.05, 'currency': 'usd',
          }}), 200);
        }
        if (request.url.path == '/v1/models') {
          return http.Response(jsonEncode({'data': [
            {'id': defaultAiModel, 'modality':'text',
              'available':true, 'supports_tools':true,
              'pricing':{'prompt':'0.000001','completion':'0.000002'}},
            {'id': 'unverified-rp', 'modality':'text', 'available':true},
          ]}), 200);
        }
        if (request.url.path == '/v1/chat/completions') {
          probes++;
          return http.Response(jsonEncode({'choices': [
            {'finish_reason': 'tool_calls', 'message': {'tool_calls': [
              {'type': 'function', 'function': {
                'name': 'domolia_tool_probe', 'arguments': '{"value":"ok"}',
              }},
            ]}},
          ]}), 200);
        }
        throw StateError('Unexpected HTTP endpoint in widget test');
      })),
    );
  });
  tearDown(() {
    credits.dispose();
    ai.dispose();
    routing.dispose();
  });

  Future<void> showCredits(WidgetTester tester, {Size? screen}) async {
    if (screen != null) {
      await tester.binding.setSurfaceSize(screen);
      addTearDown(() => tester.binding.setSurfaceSize(null));
    }
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: OpenUncensoredCreditsPage(
        controller: credits, onBack: () {},
      )),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('Fresh installation offers purchase or import and no secret',
      (tester) async {
    await showCredits(tester, screen: const Size(360, 640));
    expect(find.textContaining('Aucune clé active'), findsOneWidget);
    expect(find.byKey(const ValueKey('ouImport')), findsOneWidget);
    expect(find.byKey(const ValueKey('ouCheckout')), findsOneWidget);
    expect(find.textContaining('ou-cus'), findsNothing);
    expect(requests, 0);
    expect(tester.takeException(), null);
  });

  testWidgets('History shows masked keys, current cached balances, and reload',
      (tester) async {
    await credits.initialize();
    expect(await credits.importKey('ou-cus_ALPHA_TEST_123456'), true);
    expect(await credits.importKey('ou-cus_BRAVO_TEST_654321'), true);
    await showCredits(tester, screen: const Size(360, 640));
    await tester.scrollUntilVisible(
      find.text('Mes clés'), 200,
      scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(credits.keys, hasLength(2));
    expect(credits.keys.every((entry) => entry.lastBalance!.remainingUsd == 3.25), true);
    expect(find.textContaining('ou-••••'), findsWidgets);
    expect(find.textContaining('3.25 USD'), findsWidgets);
    expect(find.textContaining('ou-cus_ALPHA_TEST_123456'), findsNothing);
    expect(tester.takeException(), null);
  });

  testWidgets('Sandbox UI completes a fake payment without network traffic',
      (tester) async {
    final sandbox = OpenUncensoredSandbox(vault: _Vault());
    addTearDown(sandbox.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: OpenUncensoredCreditsPage(
        controller: sandbox.controller,
        sandbox: sandbox,
        onBack: () {},
      )),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('SIMULATION'), findsOneWidget);
    expect(requests, 0);
    await tester.ensureVisible(find.byKey(const ValueKey('ouCheckout')));
    await tester.tap(find.byKey(const ValueKey('ouCheckout')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('ouSimulatePaid')), 180,
      scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ouSimulatePaid')));
    await tester.pumpAndSettle();
    expect(sandbox.controller.pending, isNull);
    expect(sandbox.controller.keys, hasLength(1));
    expect(sandbox.controller.active!.secret, startsWith('ou-demo-'));
    expect(sandbox.controller.active!.lastBalance!.remainingUsd, 10);
    expect(requests, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Narrative token fields have consistent vertical spacing',
      (tester) async {
    await showCredits(tester, screen: const Size(480, 2200));
    final narrator = find.byKey(const ValueKey('ouTokens-narrator'));
    final jsonifier = find.byKey(const ValueKey('ouTokens-jsonifier'));
    final optimizer = find.byKey(const ValueKey('ouTokens-optimizer'));
    expect(narrator, findsOneWidget);
    expect(jsonifier, findsOneWidget);
    expect(optimizer, findsOneWidget);
    final firstGap = tester.getTopLeft(jsonifier).dy -
        tester.getBottomLeft(narrator).dy;
    final secondGap = tester.getTopLeft(optimizer).dy -
        tester.getBottomLeft(jsonifier).dy;
    expect(firstGap, greaterThanOrEqualTo(DomoliaSpacing.field - 1));
    expect(secondGap, greaterThanOrEqualTo(DomoliaSpacing.field - 1));
    expect(tester.takeException(), isNull);
  });
  testWidgets('Unknown narrator is shown and paid test needs confirmation',
      (tester) async {
    await credits.importKey('ou-cus_ALPHA_TEST_123456');
    await credits.loadModels();
    await showCredits(tester, screen: const Size(480, 2400));
    await tester.ensureVisible(find.text('Modèles avancés'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Modèles avancés'));
    await tester.pumpAndSettle();

    // No paid generation happens during catalogue loading or selection.
    expect(probes, 0);
    await tester.ensureVisible(
      find.byKey(const ValueKey('ouToolProbe')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ouAdvanced-narrator-$defaultAiModel')), findsOneWidget);
    expect(find.byKey(const ValueKey('ouToolProbe')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ouToolProbe')));
    await tester.pumpAndSettle();
    expect(find.text('Tester le Tool Calling ?'), findsOneWidget);
    expect(find.textContaining('pourra consommer des crédits'), findsOneWidget);
    expect(probes, 0);
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(probes, 0);

    await tester.tap(find.byKey(const ValueKey('ouToolProbe')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirmer'));
    await tester.pumpAndSettle();
    expect(probes, 1);
    expect(find.textContaining('test réel'), findsOneWidget);
    expect(tester.takeException(), null);
  });

}
