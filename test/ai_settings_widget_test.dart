import 'dart:async';

import 'package:domolia/ai/ai_controller.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/ai_settings_panel.dart';
import 'package:domolia/theme/domolia_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class MemoryStore implements AiProfileStore {
  AiProfilesState? state;

  @override
  Future<AiProfilesState?> read() async => state;

  @override
  Future<void> write(AiProfilesState value) async {
    state = AiProfilesState(
      profiles: List.of(value.profiles),
      selectedId: value.selectedId,
    );
  }
}

class FakeProvider implements AiChatProvider {
  Completer<String>? gate;
  AiProviderException? failure;
  AiConfiguration? lastConfiguration;

  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async {
    lastConfiguration = configuration;
    return [const AiModel('a-model'), const AiModel('b-model')];
  }

  @override
  Future<String> complete(
    AiConfiguration configuration, {
    required List<AiMessage> messages,
    int maxTokens = 64,
  }) async {
    lastConfiguration = configuration;
    if (failure != null) throw failure!;
    if (gate != null) return gate!.future;
    return 'Bonjour de la simulation.';
  }
}

void main() {
  late MemoryStore store;
  late FakeProvider provider;
  late AiConnectionController controller;

  setUp(() {
    store = MemoryStore();
    provider = FakeProvider();
    controller = AiConnectionController(store: store, provider: provider);
  });
  tearDown(() => controller.dispose());

  Future<void> showPage(WidgetTester tester, {Size size = const Size(1000, 2400)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(
        body: AiSettingsPanel(
          controller: controller,
          onBack: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('API settings keep masked key, a single model dropdown and test response',
      (tester) async {
    await showPage(tester);
    final keyField = tester.widget<TextField>(
      find.byKey(const ValueKey('aiApiKeyField')),
    );
    expect(keyField.obscureText, true);
    expect(find.text('Identifiant du modèle'), findsNothing);
    expect(find.byKey(const ValueKey('aiModelSelector')), findsOneWidget);
    expect(find.byKey(const ValueKey('aiProfileSelector')), findsOneWidget);
    expect(find.text('Non testé'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('aiApiKeyField')), 'ou-my-key',
    );
    await tester.tap(find.text('Enregistrer la configuration'));
    await tester.pumpAndSettle();
    expect(store.state!.profiles.single.apiKey, 'ou-my-key');
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
    expect(controller.status, AiConnectionStatus.connected);
    expect(store.state!.profiles.single.model, 'b-model');
    expect(find.textContaining('Bonjour de la simulation.'), findsOneWidget);
    expect(find.text('Connecté'), findsOneWidget);
    await tester.tap(find.text('Supprimer la clé API'));
    await tester.pumpAndSettle();
    expect(store.state!.profiles.single.apiKey, '');
    expect(find.text('Non testé'), findsOneWidget);
  });

  testWidgets('Creating, naming, switching, renaming and deleting profiles',
      (tester) async {
    await showPage(tester);
    await tester.enterText(
      find.byKey(const ValueKey('aiApiKeyField')), 'ou-main',
    );
    await tester.tap(find.text('Enregistrer la configuration'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('aiAddProfile')));
    await tester.pumpAndSettle();
    expect(find.text('Nouvelle configuration API'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('aiProfileNameField')), 'Compte secondaire',
    );
    await tester.tap(find.text('Valider'));
    await tester.pumpAndSettle();
    expect(controller.profiles, hasLength(2));
    expect(controller.selectedProfile.name, 'Compte secondaire');
    expect(controller.hasKey, false);
    await tester.enterText(
      find.byKey(const ValueKey('aiApiKeyField')), 'ou-second',
    );
    await tester.tap(find.text('Enregistrer la configuration'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('aiProfileActions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Renommer').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('aiProfileNameField')), 'Compte renommé',
    );
    await tester.tap(find.text('Valider'));
    await tester.pumpAndSettle();
    expect(controller.selectedProfile.name, 'Compte renommé');

    await tester.tap(find.byKey(const ValueKey('aiProfileSelector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenUncensored').last);
    await tester.pumpAndSettle();
    expect(controller.selectedProfile.name, 'OpenUncensored');
    expect(controller.selectedProfile.apiKey, 'ou-main');
    expect(find.text('Non testé'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('aiProfileSelector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compte renommé').last);
    await tester.pumpAndSettle();
    expect(controller.selectedProfile.apiKey, 'ou-second');

    await tester.tap(find.byKey(const ValueKey('aiProfileActions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Supprimer').last);
    await tester.pumpAndSettle();
    expect(find.text('Supprimer la configuration ?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Supprimer'));
    await tester.pumpAndSettle();
    expect(controller.profiles, hasLength(1));
    expect(controller.selectedProfile.apiKey, 'ou-main');
    expect(store.state!.profiles.single.name, 'OpenUncensored');
  });

  testWidgets('Status changes gray testing, green success and red error with details',
      (tester) async {
    await showPage(tester);
    await tester.enterText(
      find.byKey(const ValueKey('aiApiKeyField')), 'ou-my-key',
    );
    provider.gate = Completer<String>();
    await tester.tap(find.text('Tester la connexion'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(controller.status, AiConnectionStatus.testing);
    expect(find.text('En cours'), findsOneWidget);
    provider.gate!.complete('Connexion validée');
    await tester.pumpAndSettle();
    expect(controller.status, AiConnectionStatus.connected);
    expect(find.text('Connecté'), findsOneWidget);
    expect(find.byKey(const ValueKey('aiStatusErrorButton')), findsNothing);

    provider.gate = null;
    provider.failure = const AiProviderException(
      'Clé API refusée. Vérifiez votre clé.',
    );
    await tester.tap(find.text('Tester la connexion'));
    await tester.pumpAndSettle();
    expect(controller.status, AiConnectionStatus.invalid);
    expect(find.text('Invalide'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('aiStatusErrorButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('aiStatusErrorDialog')), findsOneWidget);
    expect(find.textContaining('Clé API refusée'), findsOneWidget);
    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('aiStatusErrorDialog')), findsNothing);
  });

  testWidgets('Compact phone layout has no RenderFlex overflow', (tester) async {
    await showPage(tester, size: const Size(360, 1760));
    expect(find.byKey(const ValueKey('aiProfilePicker')), findsOneWidget);
    expect(find.byKey(const ValueKey('aiConnectionStatus')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
