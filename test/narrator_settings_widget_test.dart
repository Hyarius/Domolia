import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/group_chat_page.dart';
import 'package:domolia/chat/narrator.dart';
import 'package:domolia/chat/narrator_settings.dart';
import 'package:domolia/chat/narrator_settings_page.dart';
import 'package:domolia/theme/domolia_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Store implements NarratorSettingsStore {
  Narrator? value;

  @override
  Future<Narrator?> read() async => value;

  @override
  Future<void> write(Narrator narrator) async {
    value = narrator;
  }
}

class _NoNetworkProvider implements AiChatProvider {
  int calls = 0;

  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async => [];

  @override
  Future<String> complete(
    AiConfiguration configuration, {
    required List<AiMessage> messages,
    int maxTokens = 1200,
  }) async {
    calls++;
    return '{"type":"message","speaker":"narrator","name":"Narrateur",'
        '"text":"Bienvenue !"}';
  }
}

void main() {
  testWidgets('Narrator settings edits style and list of opening candidates',
      (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final store = _Store();
    final settings = NarratorSettingsController(store: store);
    addTearDown(settings.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: NarratorSettingsPage(
        controller: settings,
        onBack: () {},
      )),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Configuration du narrateur'), findsOneWidget);
    expect(find.byKey(const ValueKey('narratorStyleField')), findsOneWidget);
    expect(find.byKey(const ValueKey('narratorOpeningsField')), findsOneWidget);
    final initialStyle = tester.widget<TextField>(
      find.byKey(const ValueKey('narratorStyleField')),
    );
    expect(initialStyle.controller!.text, contains('jeu de rôle en français'));

    await tester.enterText(
      find.byKey(const ValueKey('narratorStyleField')),
      'Narration contemplative.',
    );
    await tester.enterText(
      find.byKey(const ValueKey('narratorOpeningsField')),
      'Premier début\nSecond début',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('narratorSave')),
      260,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('narratorSave')));
    await tester.pumpAndSettle();
    expect(store.value!.narrativePrompt, 'Narration contemplative.');
    expect(store.value!.openingMessages, ['Premier début', 'Second début']);
    expect(store.value!.protocolPrompt, defaultNarratorProtocolPrompt);
    expect(find.text('Configuration du narrateur enregistrée.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Opening is a narrator bubble before the player, without API',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final fake = _NoNetworkProvider();
    final chat = NarrativeChatController(
      provider: fake,
      configuration: () => const AiConfiguration(
        baseUrl: defaultAiBaseUrl,
        model: defaultAiModel,
        apiKey: 'mock-not-real',
      ),
      narrator: const Narrator(
        openingMessages: ['La salle est silencieuse.'],
      ),
      selectOpeningIndex: (_) => 0,
    );
    addTearDown(chat.dispose);
    chat.beginConversation();
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: GroupChatPage(
        controller: chat,
        onOpenSettings: () {},
      )),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Narrateur'), findsOneWidget);
    expect(find.text('La salle est silencieuse.'), findsOneWidget);
    expect(find.byKey(const ValueKey('chatNarratorAvatar')), findsOneWidget);
    expect(fake.calls, 0);
    expect(chat.timeline.whereType<ChatEntry>(), hasLength(1));

    await tester.enterText(find.byKey(const ValueKey('groupChatInput')),
        'J’ouvre la porte.');
    await tester.tap(find.byKey(const ValueKey('groupChatSend')));
    await tester.pumpAndSettle();
    expect(fake.calls, 1);
    expect(chat.messages.map((item) => item.name),
        ['Narrateur', 'Vous', 'Narrateur']);
    expect(find.text('La salle est silencieuse.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
