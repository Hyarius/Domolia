import 'dart:convert';

import 'package:domolia/ai/ai_controller.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/ai_task_routing.dart';
import 'package:domolia/ai/openuncensored_api.dart';
import 'package:domolia/ai/openuncensored_controller.dart';
import 'package:domolia/ai/openuncensored_credits_page.dart';
import 'package:domolia/ai/openuncensored_vault.dart';
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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    requests = 0;
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
}
