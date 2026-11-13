import 'package:domolia/ai/ai_controller.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/ai_settings_panel.dart';
import 'package:domolia/theme/domolia_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class MemoryStore implements AiConfigurationStore {
  AiConfiguration? config;
  @override
  Future<AiConfiguration?> read() async => config;
  @override
  Future<void> write(AiConfiguration value) async { config = value; }
}

class FakeProvider implements AiChatProvider {
  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async =>
      [const AiModel('a-model'), const AiModel('b-model')];

  @override
  Future<String> complete(AiConfiguration configuration, {
    required List<AiMessage> messages,
    int maxTokens = 64,
  }) async => 'Bonjour de la simulation.';
}

void main() {
  testWidgets('Provider configuration, masked key and test from settings',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final store = MemoryStore();
    final controller = AiConnectionController(store: store, provider: FakeProvider());
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: AiSettingsPanel(
        controller: controller,
        onBack: () {},
      )),
    ));
    await tester.pumpAndSettle();

    final keyField = tester.widget<TextField>(find.byKey(
      const ValueKey('aiApiKeyField'),
    ));
    expect(keyField.obscureText, true);
    await tester.enterText(find.byKey(const ValueKey('aiApiKeyField')), 'ou-my-key');
    await tester.tap(find.text('Enregistrer la configuration'));
    await tester.pumpAndSettle();
    expect((await store.read())!.apiKey, 'ou-my-key');
    expect(find.text('Clé API supprimée du stockage sécurisé.'), findsNothing);

    await tester.tap(find.text('Charger les modèles'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('aiModelSelector')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('aiModelSelector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('b-model').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tester la connexion'));
    await tester.pumpAndSettle();
    expect(controller.testPassed, true);
    expect(store.config!.model, 'b-model');
    expect(find.textContaining('Bonjour de la simulation.'), findsOneWidget);

    await tester.tap(find.text('Supprimer la clé API'));
    await tester.pumpAndSettle();
    expect(store.config!.apiKey, '');
  });
}
