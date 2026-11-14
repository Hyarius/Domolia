import 'dart:async';
import 'dart:convert';

import 'package:domolia/ai/ai_provider.dart';
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
  final controller = StreamController<AiStreamChunk>();
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
    tester.view.physicalSize = const Size(420, 860);
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
    expect(find.byKey(const ValueKey('groupChatStop')), findsOneWidget);
    provider.controller.add(AiStreamChunk(
      text: '{"speaker":"character","name":"Lina","text":"Bon',
    ));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('Bon'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('groupChatStop')));
    await tester.pump();
    expect(find.byKey(const ValueKey('groupChatRetry')), findsOneWidget);
    expect(find.byKey(const ValueKey('groupChatSend')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
