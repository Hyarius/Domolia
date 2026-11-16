import 'dart:async';
import 'dart:convert';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/group_chat_page.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/theme/domolia_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const config = AiConfiguration(
  baseUrl: defaultAiBaseUrl, model: defaultAiModel, apiKey: 'test',
);

class _Provider implements AiChatProvider {
  String raw = 'Le temple apparaît.';
  String? jsonOutput;
  Completer<String>? rawGate;
  Completer<String>? formatGate;
  int narrationCalls = 0;
  int formattingCalls = 0;
  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => [];
  @override
  Future<String> complete(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) async {
    if (messages.first.content.contains('JSONificateur')) {
      formattingCalls++;
      if (formatGate != null) return formatGate!.future;
      return jsonOutput ?? jsonEncode({'events': [
        {'type': 'message', 'start': 0, 'end': raw.length,
          'speaker': 'narrator', 'name': 'Narrateur'},
      ]});
    }
    narrationCalls++;
    return rawGate == null ? raw : rawGate!.future;
  }
}

Future<void> showChat(WidgetTester tester, NarrativeChatController chat) async {
  tester.view.physicalSize = const Size(420, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(MaterialApp(
    theme: DomoliaTheme.dark,
    home: Scaffold(body: GroupChatPage(
      controller: chat, onOpenSettings: () {},
    )),
  ));
  await tester.pumpAndSettle();
}

Future<void> enter(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('groupChatInput')), text);
  await tester.pump(); // Rebuild the input-dependent Send action.
  await tester.tap(find.byKey(const ValueKey('groupChatSend')));
  await tester.pump();
}

void main() {
  testWidgets('Writing indicator replaces all temporary streaming bubbles',
      (tester) async {
    final provider = _Provider()..rawGate = Completer<String>()
      ..formatGate = Completer<String>();
    final chat = NarrativeChatController(
      provider: provider, configuration: () => config,
    );
    addTearDown(chat.dispose);
    await showChat(tester, chat);
    await enter(tester, 'Je franchis la porte.');
    expect(find.byKey(const ValueKey('chatWritingIndicator')), findsOneWidget);
    expect(find.text('Le narrateur écrit…'), findsOneWidget);
    expect(find.byKey(const ValueKey('chatBubbleText')), findsOneWidget);
    expect(find.text(provider.raw), findsNothing);
    provider.rawGate!.complete(provider.raw);
    await tester.pump(const Duration(milliseconds: 50));
    expect(provider.formattingCalls, 1);
    expect(find.text(provider.raw), findsNothing);
    expect(find.byKey(const ValueKey('chatWritingIndicator')), findsOneWidget);
    provider.formatGate!.complete(jsonEncode({'events': [
      {'type': 'message', 'start': 0, 'end': provider.raw.length,
        'speaker': 'narrator', 'name': 'Narrateur'},
    ]}));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatWritingIndicator')), findsNothing);
    expect(find.text(provider.raw), findsOneWidget);
    expect(chat.preview, isNull);
  });

  testWidgets('Long AI reply does not force transcript to its end',
      (tester) async {
    final provider = _Provider()
      ..raw = List.generate(45, (index) =>
          'Paragraphe $index : une longue description du monde.').join(' ')
      ..rawGate = Completer<String>();
    final chat = NarrativeChatController(
      provider: provider, configuration: () => config,
    );
    addTearDown(chat.dispose);
    await showChat(tester, chat);
    await enter(tester, 'Je découvre ce lieu.');
    await tester.pumpAndSettle();
    final transcript = tester.widget<ListView>(
        find.byKey(const ValueKey('groupChatTranscript')));
    final scroll = transcript.controller!;
    final before = scroll.offset;
    provider.rawGate!.complete(provider.raw);
    await tester.pumpAndSettle();
    expect(chat.messages.last.text, provider.raw);
    expect(scroll.position.maxScrollExtent, greaterThan(before));
    expect(scroll.offset, lessThan(scroll.position.maxScrollExtent));
  });

  testWidgets('Une réponse longue reste lisible depuis son début', (tester) async {
    final provider = _Provider()
      ..raw = List.generate(90, (i) => 'Paragraphe ${i + 1} : '
          'Le narrateur décrit soigneusement les lieux et les personnages.')
          .join('\n')
      ..formatGate = Completer<String>();
    final chat = NarrativeChatController(
      provider: provider, configuration: () => config,
    );
    addTearDown(chat.dispose);
    await showChat(tester, chat);
    await enter(tester, 'Je regarde autour de moi.');
    final transcript = tester.widget<ListView>(
      find.byKey(const ValueKey('groupChatTranscript')));
    final scroll = transcript.controller!;
    await tester.pumpAndSettle();
    final beforeReply = scroll.offset;

    provider.formatGate!.complete(jsonEncode({'events': [
      {'type': 'message', 'start': 0, 'end': provider.raw.length,
        'speaker': 'narrator', 'name': 'Narrateur'},
    ]}));
    await tester.pumpAndSettle();
    expect(chat.messages, hasLength(2));
    expect(scroll.position.maxScrollExtent, greaterThan(beforeReply));
    expect(scroll.offset, closeTo(beforeReply, 2));
    expect(find.byKey(const ValueKey('chatWritingIndicator')), findsNothing);
  });

  testWidgets('Scene break and three segments appear in one committed frame',
      (tester) async {
    final provider = _Provider();
    const a = 'Dans la grotte. ';
    const b = 'Brann : « Allons-y ! » ';
    const c = 'Le temple apparaît.';
    provider.raw = a + b + c;
    provider.jsonOutput = jsonEncode({'events': [
      {'type': 'scene_change', 'at': 0},
      {'type': 'message', 'start': 0, 'end': a.length,
        'speaker': 'narrator', 'name': 'Narrateur'},
      {'type': 'message', 'start': a.length, 'end': a.length + b.length,
        'speaker': 'character', 'name': 'Brann'},
      {'type': 'message', 'start': a.length + b.length, 'end': provider.raw.length,
        'speaker': 'narrator', 'name': 'Narrateur'},
    ]});
    final chat = NarrativeChatController(
      provider: provider, configuration: () => config,
    );
    addTearDown(chat.dispose);
    await showChat(tester, chat);
    await enter(tester, 'Nous passons de la grotte au temple.');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatSceneDivider')), findsOneWidget);
    expect(find.text('Brann'), findsOneWidget);
    expect(chat.timeline.whereType<ChatSceneChange>(), hasLength(1));
    expect(chat.messages, hasLength(4));
    expect(find.byKey(const ValueKey('chatWritingIndicator')), findsNothing);
  });

  testWidgets('Formatter error permits retry without writing story twice',
      (tester) async {
    final provider = _Provider()..jsonOutput = '{"events":[]}';
    final chat = NarrativeChatController(
      provider: provider, configuration: () => config,
    );
    addTearDown(chat.dispose);
    await showChat(tester, chat);
    await enter(tester, 'Une action');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatErrorBanner')), findsOneWidget);
    expect(find.text(provider.raw), findsNothing);
    provider.jsonOutput = null;
    await tester.tap(find.byKey(const ValueKey('chatRetry')));
    await tester.pumpAndSettle();
    expect(provider.narrationCalls, 1);
    expect(provider.formattingCalls, 2);
    expect(find.text(provider.raw), findsOneWidget);
  });

  testWidgets('Long press inserts and removes persistent scene boundary',
      (tester) async {
    final provider = _Provider();
    final chat = NarrativeChatController(
      provider: provider, configuration: () => config,
    );
    addTearDown(chat.dispose);
    await showChat(tester, chat);
    await enter(tester, 'Je regarde.');
    await tester.pumpAndSettle();
    final originalId = chat.messages.last.id;
    await tester.longPress(find.text(provider.raw));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatActionStartScene')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chatActionStartScene')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatSceneDivider')), findsOneWidget);
    expect(chat.messages.last.id, originalId);
    await tester.longPress(find.text(provider.raw));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatActionRemoveScene')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chatActionRemoveScene')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatSceneDivider')), findsNothing);
    expect(provider.narrationCalls, 1);
  });

  testWidgets('RAW narrator diagnostic export selects the originating turn',
      (tester) async {
    final provider = _Provider();
    final chat = NarrativeChatController(
      provider: provider, configuration: () => config,
    );
    addTearDown(chat.dispose);
    await chat.send('Je regarde.');
    final playerId = chat.messages.first.id;
    final recorder = AiExchangeRecorder();
    final rawExchange = recorder.begin(
      provider: 'test', method: 'POST', url: 'https://example.test/raw',
      requestBody: '{"model":"test"}', secret: 'private-test-key',
      accept: 'application/json',
    );
    rawExchange.stage = 'narrator_raw';
    rawExchange.playerEventId = playerId;
    rawExchange.complete();
    final captured = <String, Map<String, dynamic>>{};
    final stored = StoredAiDiagnostic(
      id: 'narrator', sessionId: 'session',
      createdAtUtc: rawExchange.createdAtUtc, content: rawExchange.exportJson(),
    );
    tester.view.physicalSize = const Size(420, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: GroupChatPage(
        controller: chat, onOpenSettings: () {},
        onLoadDiagnostics: () async => [stored],
        onExportDiagnostic: (name, data) async {
          captured[name] = data;
        },
      )),
    ));
    await tester.pumpAndSettle();
    await tester.longPress(find.text(provider.raw));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chatActionExportNarratorRaw')));
    await tester.pumpAndSettle();
    expect(captured.length, 1);
    expect(captured.values.single['stage'], 'narrator_raw');
    expect(captured.values.single['playerEventId'], playerId);
  });

  testWidgets('Stopping never reveals a late RAW response', (tester) async {
    final provider = _Provider()..rawGate = Completer<String>();
    final chat = NarrativeChatController(
      provider: provider, configuration: () => config,
    );
    addTearDown(chat.dispose);
    await showChat(tester, chat);
    await enter(tester, 'J’attends.');
    expect(find.byKey(const ValueKey('chatWritingIndicator')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('groupChatStop')));
    await tester.pump();
    provider.rawGate!.complete(provider.raw);
    await tester.pumpAndSettle();
    expect(find.text(provider.raw), findsNothing);
    expect(find.byKey(const ValueKey('chatWritingIndicator')), findsNothing);
  });
  testWidgets('Speech bubble displays emotion beside name without quotes',
      (tester) async {
    final provider = _Provider();
    final chat = NarrativeChatController(
      provider: provider, configuration: () => config,
    );
    addTearDown(chat.dispose);
    chat.restoreTimeline(const [
      ChatEntry(id: 0, speaker: ChatSpeaker.character,
          name: 'Liv', text: 'Quoi ?!', status: 'étonnée'),
      ChatEntry(id: 1, speaker: ChatSpeaker.character,
          name: 'Runa', text: '« Je comprends. »'),
    ]);
    await showChat(tester, chat);
    expect(find.text('Liv'), findsOneWidget);
    expect(find.text(' - étonnée'), findsOneWidget);
    expect(find.text('Quoi ?!'), findsOneWidget);
    expect(find.text('Je comprends.'), findsOneWidget);
    expect(find.text('« Je comprends. »'), findsNothing);
    expect(tester.takeException(), isNull);
  });

}
