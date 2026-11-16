import 'dart:async';
import 'dart:convert';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/group_chat_page.dart';
import 'package:domolia/theme/domolia_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const config = AiConfiguration(
    baseUrl: defaultAiBaseUrl, model: defaultAiModel, apiKey: 'fake');

String bubble(String text, {String role = 'narrator',
    String name = 'Narrateur', String? status}) {
  final entry = <String, dynamic>{
    'type': 'message', 'speaker': role, 'name': name, 'text': text,
  };
  if (status != null) entry['status'] = status;
  return '${jsonEncode(entry)}\n';
}

class _CompleteProvider implements AiChatProvider {
  _CompleteProvider([String? value]) : reply = value ?? bubble('Le temple apparaît.');
  String reply;
  Completer<String>? gate;
  int requests = 0;
  @override
  Future<List<AiModel>> listModels(AiConfiguration _) async => [];
  @override
  Future<String> complete(AiConfiguration _, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) async {
    requests++;
    return gate == null ? reply : gate!.future;
  }
}

class _StreamingProvider implements AiChatProvider, AiStreamingChatProvider {
  final chunks = StreamController<AiStreamChunk>.broadcast(sync: true);
  int requests = 0;
  @override
  Future<List<AiModel>> listModels(AiConfiguration _) async => [];
  @override
  Future<String> complete(AiConfiguration _, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) => throw StateError('Only streaming is supported');
  @override
  Stream<AiStreamChunk> streamChat(AiConfiguration _, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) {
    requests++;
    return chunks.stream;
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
        controller: chat, onOpenSettings: () {})),
  ));
  await tester.pumpAndSettle();
}

Future<void> send(WidgetTester tester, String message) async {
  await tester.enterText(find.byKey(const ValueKey('groupChatInput')), message);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('groupChatSend')));
  await tester.pump();
}

void main() {
  testWidgets('First streamed bubble appears before the model has finished',
      (tester) async {
    final provider = _StreamingProvider();
    final chat = NarrativeChatController(
        provider: provider, configuration: () => config);
    addTearDown(chat.dispose);
    addTearDown(provider.chunks.close);
    await showChat(tester, chat);
    await send(tester, 'Je frappe à la porte.');
    expect(provider.requests, 1);
    expect(find.byKey(const ValueKey('chatWritingIndicator')), findsOneWidget);
    provider.chunks.add(const AiStreamChunk(text:
        '{"type":"message","speaker":"narrator",'
        '"name":"Narrateur","text":"La porte'));
    await tester.pump();
    expect(find.text('La porte'), findsOneWidget);
    expect(chat.messages, hasLength(1));
    expect(chat.previewEvents, hasLength(1));
    provider.chunks.add(const AiStreamChunk(text: ' s’ouvre."}\n'));
    await provider.chunks.close();
    await tester.pumpAndSettle();
    expect(find.text('La porte s’ouvre.'), findsOneWidget);
    expect(chat.messages, hasLength(2));
    expect(chat.previewEvents, isEmpty);
    expect(find.byKey(const ValueKey('chatWritingIndicator')), findsNothing);
  });

  testWidgets('Long completed answer does not jump to the end of the transcript',
      (tester) async {
    final text = List.filled(65,
        'Le narrateur décrit une longue galerie silencieuse.').join(' ');
    final provider = _CompleteProvider(bubble(text))
      ..gate = Completer<String>();
    final chat = NarrativeChatController(
        provider: provider, configuration: () => config);
    addTearDown(chat.dispose);
    await showChat(tester, chat);
    await send(tester, 'Je regarde la galerie.');
    final list = tester.widget<ListView>(
        find.byKey(const ValueKey('groupChatTranscript')));
    final scroll = list.controller!;
    final before = scroll.offset;
    provider.gate!.complete(provider.reply);
    await tester.pumpAndSettle();
    expect(chat.error, isNull);
    expect(chat.messages.last.text, text);
    expect(scroll.position.maxScrollExtent, greaterThan(before));
    expect(scroll.offset, lessThan(scroll.position.maxScrollExtent));
  });

  testWidgets('Narrator, scene separator and character retain their roles',
      (tester) async {
    final provider = _CompleteProvider(
        '${bubble('Dans la grotte.')}'
        '{"type":"scene_change"}\n'
        '${bubble('Suivez-moi.', role: 'character', name: 'Brann',
            status: 'inquiet')}'
        '${bubble('L’écho disparaît.')}');
    final chat = NarrativeChatController(
        provider: provider, configuration: () => config);
    addTearDown(chat.dispose);
    await showChat(tester, chat);
    await send(tester, 'Nous changeons de lieu.');
    await tester.pumpAndSettle();
    expect(chat.error, isNull);
    expect(find.byKey(const ValueKey('chatSceneDivider')), findsOneWidget);
    expect(find.text('Brann'), findsOneWidget);
    expect(find.text(' - inquiet'), findsOneWidget);
    expect(chat.messages, hasLength(4));
    expect(provider.requests, 1);
  });

  testWidgets('Bad NDJSON stays uncommitted and Retry re-runs one narrator',
      (tester) async {
    final provider = _CompleteProvider('{broken}\n');
    final chat = NarrativeChatController(
        provider: provider, configuration: () => config);
    addTearDown(chat.dispose);
    await showChat(tester, chat);
    await send(tester, 'Je regarde.');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatErrorBanner')), findsOneWidget);
    expect(chat.messages, hasLength(1));
    provider.reply = bubble('Une réponse correcte.');
    await tester.tap(find.byKey(const ValueKey('chatRetry')));
    await tester.pumpAndSettle();
    expect(find.text('Une réponse correcte.'), findsOneWidget);
    expect(chat.messages, hasLength(2));
    expect(provider.requests, 2);
  });

  testWidgets('Long press adds and removes a persistent scene boundary',
      (tester) async {
    final provider = _CompleteProvider();
    final chat = NarrativeChatController(
        provider: provider, configuration: () => config);
    addTearDown(chat.dispose);
    await showChat(tester, chat);
    await send(tester, 'Je regarde.');
    await tester.pumpAndSettle();
    final originalId = chat.messages.last.id;
    await tester.longPress(find.text('Le temple apparaît.'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatActionStartScene')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chatActionStartScene')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatSceneDivider')), findsOneWidget);
    expect(chat.messages.last.id, originalId);
    await tester.longPress(find.text('Le temple apparaît.'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chatActionRemoveScene')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatSceneDivider')), findsNothing);
  });

  testWidgets('Stop removes incomplete preview and never publishes the draft',
      (tester) async {
    final provider = _StreamingProvider();
    final chat = NarrativeChatController(
        provider: provider, configuration: () => config);
    addTearDown(chat.dispose);
    addTearDown(provider.chunks.close);
    await showChat(tester, chat);
    await send(tester, 'Je regarde.');
    provider.chunks.add(const AiStreamChunk(text:
        '{"type":"message","speaker":"narrator",'
        '"name":"Narrateur","text":"Un texte en cours'));
    await tester.pump();
    expect(chat.previewEvents, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('groupChatStop')));
    await tester.pump();
    expect(chat.previewEvents, isEmpty);
    expect(chat.rawGenerations, isEmpty);
    expect(chat.messages, hasLength(1));
    expect(find.text('Un texte en cours'), findsNothing);
  });
}
