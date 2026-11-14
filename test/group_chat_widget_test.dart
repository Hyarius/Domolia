import 'dart:async';
import 'dart:convert';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/group_chat_page.dart';
import 'package:domolia/theme/domolia_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const config = AiConfiguration(
  baseUrl: defaultAiBaseUrl,
  model: defaultAiModel,
  apiKey: 'ou-test',
);

String line(String speaker, String name, String text) => jsonEncode({
  'speaker': speaker,
  'name': name,
  'text': text,
});

class ScriptedProvider implements AiChatProvider {
  String response = '';
  @override
  Future<List<AiModel>> listModels(AiConfiguration cfg) async => [];
  @override
  Future<String> complete(
    AiConfiguration cfg, {
    required List<AiMessage> messages,
    int maxTokens = 1200,
  }) async => response;
}

class PendingProvider implements AiChatProvider, AiStreamingChatProvider {
  final controller = StreamController<AiStreamChunk>.broadcast();
  @override
  Stream<AiStreamChunk> streamChat(
    AiConfiguration cfg, {
    required List<AiMessage> messages,
    int maxTokens = 1200,
  }) => controller.stream;
  @override
  Future<List<AiModel>> listModels(AiConfiguration cfg) async => [];
  @override
  Future<String> complete(
    AiConfiguration cfg, {
    required List<AiMessage> messages,
    int maxTokens = 1200,
  }) async => '';
}

void main() {
  testWidgets('Each speaker has a portrait, name and distinct chat bubble',
      (tester) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final provider = ScriptedProvider()
      ..response = [
        line('narrator', 'Narrateur', 'Les portes de l’auberge s’ouvrent.'),
        line('character', 'Lina', 'Bienvenue chez nous !'),
        line('character', 'Marc', 'Tu as fait bon voyage ?'),
      ].join('\n');
    final controller = NarrativeChatController(
      provider: provider, configuration: () => config,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: GroupChatPage(
        controller: controller, onOpenSettings: () {},
      )),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Conversation de groupe'), findsOneWidget);
    expect(find.byKey(const ValueKey('groupChatInput')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('groupChatInput')), 'Je pousse la porte.',
    );
    await tester.tap(find.byKey(const ValueKey('groupChatSend')));
    await tester.pumpAndSettle();

    expect(find.text('Vous'), findsOneWidget);
    expect(find.text('Narrateur'), findsOneWidget);
    expect(find.text('Lina'), findsOneWidget);
    expect(find.text('Marc'), findsOneWidget);
    expect(find.text('Je pousse la porte.'), findsOneWidget);
    expect(find.text('Bienvenue chez nous !'), findsOneWidget);
    expect(find.byKey(const ValueKey('chatPlayerAvatar')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatNarratorAvatar')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatCharacterAvatar')), findsNWidgets(2));
    expect(find.byKey(const ValueKey('chatBubbleText')), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Narrow Android layout stays usable with keyboard insets',
      (tester) async {
    tester.view.physicalSize = const Size(320, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final provider = ScriptedProvider()
      ..response = line('narrator', 'Narrateur', 'Une réponse courte.');
    final controller = NarrativeChatController(
      provider: provider, configuration: () => config,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(
        resizeToAvoidBottomInset: true,
        body: MediaQuery(
          data: const MediaQueryData(viewInsets: EdgeInsets.only(bottom: 280)),
          child: GroupChatPage(
            controller: controller, onOpenSettings: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('groupChatInput')), findsOneWidget);
    expect(find.byKey(const ValueKey('groupChatSend')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pending stream shows a stop button and progressive bubble',
      (tester) async {
    final provider = PendingProvider();
    addTearDown(provider.controller.close);
    final controller = NarrativeChatController(
      provider: provider, configuration: () => config,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: GroupChatPage(
        controller: controller, onOpenSettings: () {},
      )),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('groupChatInput')), 'Salut');
    await tester.tap(find.byKey(const ValueKey('groupChatSend')));
    await tester.pump();
    expect(controller.busy, true);
    expect(find.byKey(const ValueKey('groupChatStop')), findsOneWidget);
    provider.controller.add(AiStreamChunk(
      text: '{"speaker":"character","name":"Lina","text":"Bon',
    ));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('Bon'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('groupChatStop')));
    await tester.pump();
    expect(find.byKey(const ValueKey('chatRetry')), findsOneWidget);
    expect(find.byKey(const ValueKey('groupChatSend')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Scene change renders as an unlabeled gray full-width divider',
      (tester) async {
    tester.view.physicalSize = const Size(420, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final mock = ScriptedProvider()
      ..response = [
        line('character', 'Lina', 'Suis-moi.'),
        '{"type":"scene_change"}',
        line('narrator', 'Narrateur', 'La porte s’ouvre.'),
      ].join('\n');
    final state = NarrativeChatController(
      provider: mock, configuration: () => config,
    );
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: GroupChatPage(
        controller: state, onOpenSettings: () {},
      )),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('groupChatInput')), 'Nous partons.',
    );
    await tester.tap(find.byKey(const ValueKey('groupChatSend')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatSceneDivider')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatBubbleText')), findsNWidgets(3));
    expect(find.text('Scène 2'), findsNothing);
    expect(find.text('Changement de scène'), findsNothing);
    final divider = tester.widget<Container>(
      find.byKey(const ValueKey('chatSceneDivider')),
    );
    expect(divider.constraints!.maxHeight, 2);
    expect(tester.getSize(find.byKey(const ValueKey('chatSceneDivider'))).width,
        greaterThan(300));
    expect(divider.decoration, isA<BoxDecoration>());
    expect(tester.takeException(), isNull);
  });

  testWidgets('The conversation menu keeps scoped exports and purge only',
      (tester) async {
    final controller = NarrativeChatController(
      provider: ScriptedProvider(), configuration: () => config,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: GroupChatPage(
        controller: controller, onOpenSettings: () {},
      )),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chatExportMenu')));
    await tester.pumpAndSettle();
    expect(find.text('Exporter la conversation'), findsOneWidget);
    expect(find.text('Requête IA + réponse brute'), findsNothing);
    await tester.tap(find.text('Exporter la conversation'));
    await tester.pumpAndSettle();
    expect(find.text('Toute la conversation'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chatExportScope')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('X derniers messages').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatExportCount')), findsOneWidget);
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
  });

  testWidgets('Long press exposes player edits and resumes from edited text',
      (tester) async {
    tester.view.physicalSize = const Size(420, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final scripted = ScriptedProvider()
      ..response = line('narrator', 'Narrateur', 'Nouvelle réponse');
    final controller = NarrativeChatController(
      provider: scripted, configuration: () => config,
    );
    addTearDown(controller.dispose);
    controller.restoreTimeline(const [
      ChatEntry(id: 0, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Ancienne action'),
      ChatEntry(id: 1, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Ancienne réponse'),
      ChatSceneChange(id: 2),
      ChatEntry(id: 3, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Action suivante'),
      ChatEntry(id: 4, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Ancienne suite'),
    ]);
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: GroupChatPage(
        controller: controller, onOpenSettings: () {},
      )),
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const ValueKey('chat-entry-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatActionEdit')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatActionResume')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatActionExport')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('chatActionEdit')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('chatEditMessageInput')),
        'Action corrigée');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect((controller.timeline.first as ChatEntry).text, 'Action corrigée');
    expect(controller.timeline, hasLength(5));

    await tester.longPress(find.byKey(const ValueKey('chat-entry-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chatActionResume')));
    await tester.pumpAndSettle();
    expect(find.text('Reprendre ici ?'), findsOneWidget);
    await tester.tap(find.text('Continuer'));
    await tester.pumpAndSettle();
    expect(controller.timeline, hasLength(2));
    expect((controller.timeline.first as ChatEntry).text, 'Action corrigée');
    expect((controller.timeline.last as ChatEntry).text, 'Nouvelle réponse');
  });

  testWidgets('Long press on an AI bubble exports its own HTTP exchange',
      (tester) async {
    tester.view.physicalSize = const Size(420, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final controller = NarrativeChatController(
      provider: ScriptedProvider(), configuration: () => config,
    );
    addTearDown(controller.dispose);
    controller.restoreTimeline(const [
      ChatEntry(id: 0, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Première action'),
      ChatEntry(id: 1, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Première réponse'),
      ChatEntry(id: 2, speaker: ChatSpeaker.character,
          name: 'Lina', text: 'Dans la même génération'),
      ChatEntry(id: 3, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Deuxième action'),
      ChatEntry(id: 4, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Deuxième réponse'),
    ]);
    StoredAiDiagnostic diagnostic(int id, String model) =>
        StoredAiDiagnostic(
          id: 'trace-' + id.toString(),
          sessionId: 'partie',
          createdAtUtc: DateTime.utc(2026, 11, 14, 10, 0, id),
          content: jsonEncode({
            'format': 'domolia-ai-exchange-v1',
            'request': {'body': {'model': model}},
            'interpretation': {'events': [
              {'id': id, 'type': 'message'},
              if (id == 1) {'id': 2, 'type': 'message'},
            ]},
          }),
        );
    Map<String, dynamic>? exported;
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: GroupChatPage(
        controller: controller,
        onOpenSettings: () {},
        onLoadDiagnostics: () async => [
          diagnostic(4, 'second-model'),
          diagnostic(1, 'first-model'),
        ],
        onExportDiagnostic: (name, data) async { exported = data; },
      )),
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const ValueKey('chat-entry-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatActionRegenerate')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatActionExport')), findsOneWidget);
    expect(find.byKey(const ValueKey('chatActionEdit')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('chatActionExport')));
    await tester.pumpAndSettle();
    expect((exported!['request'] as Map)['body']['model'], 'first-model');
  });

  testWidgets('Regenerate an AI bubble rewinds only to its own player turn',
      (tester) async {
    tester.view.physicalSize = const Size(420, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final scripted = ScriptedProvider()
      ..response = line('character', 'Lina', 'Réponse remplacée');
    final controller = NarrativeChatController(
      provider: scripted, configuration: () => config,
    );
    addTearDown(controller.dispose);
    controller.restoreTimeline(const [
      ChatEntry(id: 0, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Action initiale'),
      ChatEntry(id: 1, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Première réponse'),
      ChatEntry(id: 2, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Action à rejouer'),
      ChatEntry(id: 3, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Réponse à changer'),
      ChatEntry(id: 4, speaker: ChatSpeaker.character,
          name: 'Lina', text: 'Même tour'),
    ]);
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: GroupChatPage(
        controller: controller, onOpenSettings: () {},
      )),
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const ValueKey('chat-entry-4')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chatActionRegenerate')));
    await tester.pumpAndSettle();
    expect(find.text('Régénérer cette réponse ?'), findsOneWidget);
    await tester.tap(find.text('Continuer'));
    await tester.pumpAndSettle();
    expect(controller.timeline, hasLength(4));
    expect((controller.timeline[1] as ChatEntry).text, 'Première réponse');
    expect((controller.timeline[2] as ChatEntry).text, 'Action à rejouer');
    expect((controller.timeline[3] as ChatEntry).text, 'Réponse remplacée');
  });

  testWidgets('Purger les diagnostics confirme et préserve la conversation',
      (tester) async {
    final controller = NarrativeChatController(
      provider: ScriptedProvider(), configuration: () => config,
    );
    addTearDown(controller.dispose);
    controller.restoreTimeline(const [
      ChatEntry(id: 0, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Ceci doit rester.'),
    ]);
    var purges = 0;
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: GroupChatPage(
        controller: controller,
        onOpenSettings: () {},
        onLoadDiagnostics: () async => [],
        onPurgeDiagnostics: () async { purges++; },
      )),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chatExportMenu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Purger les diagnostics'));
    await tester.pumpAndSettle();
    expect(find.text('Purger les diagnostics ?'), findsOneWidget);
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(purges, 0);

    await tester.tap(find.byKey(const ValueKey('chatExportMenu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Purger les diagnostics'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Purger'));
    await tester.pumpAndSettle();
    expect(purges, 1);
    expect(controller.timeline, hasLength(1));
    expect((controller.timeline.single as ChatEntry).text,
        'Ceci doit rester.');
  });

}
