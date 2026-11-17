import 'dart:convert';
import 'dart:io';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/group_chat_page.dart';
import 'package:domolia/chat/narrative_reference_tools.dart';
import 'package:domolia/chat/raw_generation.dart';
import 'package:domolia/chat/theatrical_narrator_protocol.dart';
import 'package:domolia/chat/theatrical_script_decoder.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _config = AiConfiguration(
  baseUrl: defaultAiBaseUrl, model: defaultAiModel, apiKey: 'simulated',
);

List<ChatOutputEvent> _decode(String text, {
  int chunk = 1, bool allowImages = true,
}) {
  final parser = TheatricalScriptDecoder(allowImages: allowImages);
  final result = <ChatOutputEvent>[];
  for (var i = 0; i < text.length; i += chunk) {
    final end = (i + chunk).clamp(0, text.length);
    result.addAll(parser.add(text.substring(i, end)));
  }
  result.addAll(parser.finish());
  return result;
}

class _ScriptProvider implements AiChatProvider, AiStreamingChatProvider,
    AiToolCallingChatProvider {
  _ScriptProvider(this.script);
  String script;
  int calls = 0;
  List<AiMessage>? prompt;
  List<AiToolMessage>? toolPrompt;
  AiExchangeRecorder? recorder;

  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async => [];

  @override
  Future<String> complete(AiConfiguration configuration, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) => throw StateError('No JSONifier or second AI pass expected');

  @override
  Stream<AiStreamChunk> streamChat(AiConfiguration configuration, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) async* {
    calls++;
    prompt = messages;
    yield AiStreamChunk(text: script);
  }

  @override
  Stream<AiToolStreamChunk> streamToolChat(AiConfiguration configuration, {
    required List<AiToolMessage> messages,
    required List<AiToolDefinition> tools, int maxTokens = 1200,
  }) async* {
    calls++;
    toolPrompt = messages;
    final exchange = recorder?.begin(
      provider: 'test-tool-provider', method: 'POST',
      url: 'https://example.invalid/v1/responses',
      requestBody: '{"model":"test"}', secret: 'simulated',
      accept: 'text/event-stream',
    );
    exchange?.statusCode = 200;
    exchange?.addRawResponse(utf8.encode(script));
    yield AiToolStreamChunk(text: script, finishReason: 'stop');
  }
}

NarrativeChatController _chat(_ScriptProvider provider,
    IllustrationMode mode, {
    Future<void> Function(List<ChatTimelineEvent>, List<RawGeneration>)? save,
  }) => NarrativeChatController(
    provider: provider,
    configuration: () => _config,
    structuredStreamingEnabled: true,
    illustrationMode: mode,
    onPersistState: save,
  );

void main() {
  group('Decoder [IMAGE]', () {
    test('ordinary prose and legacy markers stay unchanged', () {
      final events = _decode(
          '[NARRATION]\nVent marin.\n[PERSONNAGE:Léa Monel|inquiète]\n'
          '« Le registre ? »\n[SCENE]\nUne autre salle.');
      expect(events.whereType<ChatIllustrationOutput>(), isEmpty);
      expect(events.whereType<ChatLine>(), hasLength(3));
      expect((events[1] as ChatLine).status, 'inquiète');
      expect(events.whereType<ChatSceneChangeOutput>(), hasLength(1));
    });

    test('inserts the illustration between the two narrative blocks', () {
      final events = _decode('[NARRATION]\nLes portes s’ouvrent.\n'
          '[IMAGE]\nLa salle de marbre, éclairée par des torches.\n'
          '[NARRATION]\nUne silhouette attend.');
      expect(events, hasLength(3));
      expect(events[0], isA<ChatLine>());
      expect(events[1], isA<ChatIllustrationOutput>());
      expect((events[1] as ChatIllustrationOutput).description,
          'La salle de marbre, éclairée par des torches.');
      expect((events[2] as ChatLine).text, 'Une silhouette attend.');
    });

    test('preserves dialogue ordering and identity despite close names', () {
      final events = _decode('[PERSONNAGE:Léa Monel]\nBonjour.\n'
          '[IMAGE]\nLéa Monel sur le quai, sacoche orange.\n'
          '[PERSONNAGE:Léa Monnel]\nQui êtes-vous ?', chunk: 2);
      expect(events, hasLength(3));
      expect((events.first as ChatLine).name, 'Léa Monel');
      expect(events[1], isA<ChatIllustrationOutput>());
      expect((events.last as ChatLine).name, 'Léa Monnel');
    });

    test('accepts absent images, drops empty and excess proposals', () {
      expect(_decode('La lumière baisse.').whereType<ChatIllustrationOutput>(),
          isEmpty);
      final events = _decode('[NARRATION]\nUne horloge sonne.\n'
          '[IMAGE]\n   \n'
          '[IMAGE] Horloge dans la brume.\n'
          '[IMAGE] Deuxième suggestion redondante.\n'
          '[NARRATION]\nLe silence revient.');
      expect(events.whereType<ChatIllustrationOutput>(), hasLength(1));
      expect((events[1] as ChatIllustrationOutput).description,
          'Horloge dans la brume.');
      expect(events.whereType<ChatLine>(), hasLength(2));
    });

    test('holds incomplete image markers and descriptions during streaming', () {
      final parser = TheatricalScriptDecoder();
      expect(parser.add('[IM'), isEmpty);
      expect(parser.preview, isNull);
      expect(parser.add('AGE]\nLéa sur le quai, é'), isEmpty);
      expect(parser.preview, isNull);
      expect(parser.add('clairée par le fanal.\n[NARRATION]\nSuite.'),
          hasLength(1));
      expect((parser.finish().single as ChatLine).text, 'Suite.');
      expect(() => _decode('[IMAG'), throwsFormatException);
    });

    test('disabled decoder strips visual blocks without becoming dialogue', () {
      final events = _decode('[NARRATION]\nLa porte claque.\n'
          '[IMAGE]\nCe bloc ne doit pas s’afficher.\n'
          '[PERSONNAGE:Oren]\nBonsoir.', allowImages: false);
      expect(events, hasLength(2));
      expect(events.whereType<ChatIllustrationOutput>(), isEmpty);
    });

    test('rejects long images and player impersonation', () {
      expect(() => _decode('[NARRATION]\nUne pierre.\n[IMAGE]\n${List.filled(501, 'x').join()}'), throwsFormatException);
      expect(() => _decode('[IMAGE]\nVous prenez le jeton.\n'
          '[JOUEUR]\nJe le prends.'), throwsFormatException);
    });
  });

  group('Book and Party compatibility', () {
    test('new Books suggest, old Books default disabled', () {
      const fresh = BookDefinition(id: 'registre', title: 'Le Registre de Sel');
      expect(fresh.illustrationMode, IllustrationMode.suggestions);
      expect(BookDefinition.importJson(fresh.exportJson()).illustrationMode,
          IllustrationMode.suggestions);
      final old = jsonDecode(fresh.exportJson()) as Map<String, dynamic>;
      old['version'] = 2;
      (old['narrative'] as Map<String, dynamic>)
          .remove('illustrationMode');
      expect(BookDefinition.importJson(jsonEncode(old)).illustrationMode,
          IllustrationMode.disabled);
      old['version'] = 1;
      old.remove('lore');
      expect(BookDefinition.importJson(jsonEncode(old)).illustrationMode,
          IllustrationMode.disabled);
    });

    test('Book mode validation and Party override inheritance', () {
      const book = BookDefinition(id: 'registre', title: 'Registre',
          illustrationMode: IllustrationMode.automatic);
      final saved = jsonDecode(book.exportJson()) as Map<String, dynamic>;
      (saved['narrative'] as Map<String, dynamic>)['illustrationMode'] =
          'untrusted';
      expect(() => BookDefinition.importJson(jsonEncode(saved)),
          throwsFormatException);
      const session = BookSession(id: 'part', bookId: 'registre',
          title: 'Partie');
      expect(session.illustrationModeOverride, isNull);
      final overridden = session.copyWith(
          illustrationModeOverride: IllustrationMode.disabled);
      expect(overridden.illustrationModeOverride, IllustrationMode.disabled);
      expect(overridden.copyWith(clearIllustrationMode: true)
          .illustrationModeOverride, isNull);
    });

    test('intent timeline survives serialization and old parts still load', () {
      const session = BookSession(id: 'part', bookId: 'registre',
          title: 'Partie', timeline: [
        ChatEntry(id: 1, speaker: ChatSpeaker.player,
            name: 'Vous', text: 'Je regarde Léa.'),
        ChatEntry(id: 2, speaker: ChatSpeaker.narrator,
            name: 'Narrateur', text: 'Elle sort sur le quai.'),
        ChatIllustrationIntent(id: 3, playerEventId: 1,
            description: 'Léa Monel sous le fanal.'),
        ChatEntry(id: 4, speaker: ChatSpeaker.narrator,
            name: 'Narrateur', text: 'Elle attend.'),
      ]);
      final restored = BookSession.decodeTimeline(session.encodeTimeline());
      final intent = restored[2] as ChatIllustrationIntent;
      expect(intent.id, 3);
      expect(intent.playerEventId, 1);
      expect(intent.state, IllustrationIntentState.proposed);
      expect(intent.description, contains('fanal'));
      expect(BookSession.decodeTimeline('[{"id":0,"type":"scene_change"}]'),
          hasLength(1));
    });

    test('SQLite snapshot removes intents during rewind and preserves RAW', () async {
      sqfliteFfiInit();
      final dir = await Directory.systemTemp.createTemp('domolia-pr33-');
      final file = '${dir.path}/part.sqlite';
      final store = SqliteBookStore(
          factory: databaseFactoryFfi, databasePath: file);
      addTearDown(() async { await store.close(); await dir.delete(recursive: true); });
      await store.putBook(const BookDefinition(
          id: 'registre', title: 'Registre'));
      const player = ChatEntry(id: 1, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Je regarde le quai.');
      const intent = ChatIllustrationIntent(id: 3, playerEventId: 1,
          description: 'Le quai et le fanal.');
      final part = BookSession(id: 'part', bookId: 'registre',
          title: 'Partie', illustrationModeOverride: IllustrationMode.suggestions,
          timeline: const [player]);
      await store.putSession(part);
      await store.saveNarrativeSnapshot(part.copyWith(timeline: const [
        player,
        ChatEntry(id: 2, speaker: ChatSpeaker.narrator,
            name: 'Narrateur', text: 'Le fanal brille.'),
        intent,
      ]), const [
        RawGeneration(playerEventId: 1,
            rawText: '[NARRATION]\nLe fanal brille.\n[IMAGE]\nLe quai et le fanal.',
            compactText: 'Le fanal brille.',
            firstEventId: 2, lastEventId: 3),
      ]);
      expect((await store.findSession('part'))!.timeline[2],
          isA<ChatIllustrationIntent>());
      expect((await store.findSession('part'))!.illustrationModeOverride,
          IllustrationMode.suggestions);
      expect((await store.listRawGenerations('part')).single.rawText,
          contains('[IMAGE]'));
      await store.saveNarrativeSnapshot(part, const []);
      expect((await store.findSession('part'))!.timeline, hasLength(1));
      expect(await store.listRawGenerations('part'), isEmpty);
    });
  });

  group('Narrator selection and history isolation', () {
    test('disabled sends no visual instruction and records no image', () async {
      final provider = _ScriptProvider('[NARRATION]\nUne lanterne.\n'
          '[IMAGE]\nLanterne imaginaire.');
      final chat = _chat(provider, IllustrationMode.disabled);
      addTearDown(chat.dispose);
      await chat.send('Je regarde.');
      expect(chat.error, isNull);
      expect(provider.calls, 1);
      expect(provider.prompt!.first.content,
          isNot(contains(theatricalIllustrationInstruction)));
      expect(chat.timeline.whereType<ChatIllustrationIntent>(), isEmpty);
    });

    test('Suggestions adds exactly one proposal, no extra AI pass', () async {
      final provider = _ScriptProvider('[NARRATION]\nLéa apparaît.\n'
          '[IMAGE]\nLéa Monel et sa sacoche orange dans la brume.\n'
          '[NARRATION]\nLa sirène retentit.');
      List<ChatTimelineEvent> saved = [];
      List<RawGeneration> savedRaw = [];
      final chat = _chat(provider, IllustrationMode.suggestions,
          save: (events, raw) async {
            saved = List.of(events);
            savedRaw = List.of(raw);
          });
      addTearDown(chat.dispose);
      await chat.send('Je regarde le quai.');
      expect(chat.error, isNull);
      expect(provider.calls, 1);
      expect(provider.prompt!.first.content,
          contains(theatricalIllustrationInstruction));
      expect(chat.timeline.map((e) => e.runtimeType).toList(), [
        ChatEntry, ChatEntry, ChatIllustrationIntent, ChatEntry,
      ]);
      expect(saved.whereType<ChatIllustrationIntent>(), hasLength(1));
      expect(savedRaw.single.rawText, contains('[IMAGE]'));
      expect(savedRaw.single.compactText, isNot(contains('[IMAGE]')));
      expect(savedRaw.single.compactText, isNot(contains('sacoche orange')));
    });

    test('Tool Calling records bubbles and image on the billed narrator exchange',
        () async {
      final recorder = AiExchangeRecorder();
      final captured = <AiExchange>[];
      final provider = _ScriptProvider(
        '[NARRATION]\nLéa arrive sur le quai.\n'
        '[IMAGE]\nLéa Monel avec sa sacoche orange dans la brume.\n'
        '[PERSONNAGE:Léa Monel]\\n« Je suis ici. »',
      )..recorder = recorder;
      final chat = NarrativeChatController(
        provider: provider, configuration: () => _config,
        structuredStreamingEnabled: true,
        illustrationMode: IllustrationMode.suggestions,
        diagnostics: recorder, onExchangeCaptured: captured.add,
        resolveConnection: () async => NarrativeAiEndpoint(
          provider: provider, configuration: _config,
          toolCallingEnabled: true),
      );
      addTearDown(chat.dispose);
      await chat.send('Je regarde son arrivée.');
      expect(chat.error, isNull);
      expect(provider.calls, 1);
      expect(provider.toolPrompt!.first.content,
          contains(theatricalIllustrationInstruction));
      expect(chat.timeline.whereType<ChatIllustrationIntent>(), hasLength(1));
      expect(captured, hasLength(2)); // Initial billed round + enrichment.
      final saved = captured.last;
      expect(saved.stage, 'narrator_tool_round_0');
      expect(saved.completedAtUtc, isNotNull);
      expect(saved.interpretedEvents.where(
          (e) => e['type'] == 'image_intent'), hasLength(1));
      final stored = StoredAiDiagnostic(
        id: 'test', sessionId: 'part', createdAtUtc: saved.createdAtUtc,
        content: saved.exportJson(),
      );
      expect(stored.isNarratorForTurn(0), isTrue);
      expect(stored.containsMessage(1), isTrue);
    });

    test('Automatic is a future mode, not an image provider call', () async {
      final provider = _ScriptProvider('[NARRATION]\nUn quai.')
        ..script = '[NARRATION]\nUn quai.\n[IMAGE]\nLe quai.';
      final chat = _chat(provider, IllustrationMode.automatic);
      addTearDown(chat.dispose);
      await chat.send('Je regarde.');
      expect(provider.calls, 1);
      expect(chat.timeline.whereType<ChatIllustrationIntent>(), hasLength(1));
      expect(chat.timeline.whereType<ChatIllustrationIntent>()
          .single.state, IllustrationIntentState.proposed);
    });

    test('no image is perfectly valid even when enabled', () async {
      final provider = _ScriptProvider('[NARRATION]\nLe vent souffle.');
      final chat = _chat(provider, IllustrationMode.suggestions);
      addTearDown(chat.dispose);
      await chat.send('Je patiente.');
      expect(chat.error, isNull);
      expect(chat.timeline.whereType<ChatIllustrationIntent>(), isEmpty);
    });

    test('regeneration removes old intents and replaces them atomically', () async {
      final provider = _ScriptProvider('[NARRATION]\nUne horloge.\n'
          '[IMAGE]\nUne horloge dans le brouillard.');
      final chat = _chat(provider, IllustrationMode.suggestions);
      addTearDown(chat.dispose);
      await chat.send('Je regarde.');
      expect(chat.timeline.whereType<ChatIllustrationIntent>(), hasLength(1));
      provider.script = '[NARRATION]\nAucun changement remarquable.';
      await chat.regenerate();
      expect(chat.error, isNull);
      expect(chat.timeline.whereType<ChatIllustrationIntent>(), isEmpty);
      expect(chat.rawGenerations, hasLength(1));
      expect(chat.messages.last.text, 'Aucun changement remarquable.');
    });

    test('RAW remains diagnostic; history tools and memory input omit image', () {
      const raw = '[NARRATION]\nLéa attend sur le quai.\n'
          '[IMAGE]\nLe jeton 62 est dans la main du joueur.\n'
          '[NARRATION]\nElle ne lui a rien donné.';
      const generation = RawGeneration(
        playerEventId: 1, rawText: raw,
        firstEventId: 2, lastEventId: 4,
      );
      expect(stripIllustrationBlocks('[IMAGE]objet non narré\n[NARRATION]\nSuite.'), '[NARRATION]\nSuite.');
      expect(generation.rawText, contains('jeton 62'));
      expect(generation.validatedNarrative, isNot(contains('jeton 62')));
      expect(generation.validatedNarrative,
          contains('Elle ne lui a rien donné.'));
      final tools = NarrativeReferenceTools(
        lore: () => const BookDefinition(
            id: 'registre', title: 'Registre').lore,
        timeline: () => const [
          ChatEntry(id: 1, speaker: ChatSpeaker.player,
              name: 'Vous', text: 'Je regarde.'),
          ChatEntry(id: 2, speaker: ChatSpeaker.narrator,
              name: 'Narrateur', text: 'Léa attend sur le quai.'),
          ChatIllustrationIntent(id: 3, playerEventId: 1,
              description: 'Le jeton 62 est dans la main du joueur.'),
          ChatEntry(id: 4, speaker: ChatSpeaker.narrator,
              name: 'Narrateur', text: 'Elle ne lui a rien donné.'),
        ],
        rawGenerations: () => const [generation],
      );
      final found = jsonDecode(tools.execute('search_history',
          '{"query":"jeton"}')) as Map<String, dynamic>;
      expect(found['results'], isEmpty);
      final history = jsonDecode(tools.execute('get_history_excerpt',
          '{"player_event_id":1}')) as Map<String, dynamic>;
      expect((history['turns'] as List).single['raw_original'],
          isNot(contains('jeton 62')));
    });

    test('prompt addition stays bounded, without new context budget', () {
      expect(theatricalNarratorProtocol.length, lessThan(600));
      expect(theatricalIllustrationInstruction.length, lessThan(250));
      expect(theatricalIllustrationInstruction, contains('au plus un'));
      expect(theatricalIllustrationInstruction, contains('secrets'));
    });
  });

  testWidgets('chat renders a discreet inline illustration, not a button',
      (tester) async {
    final provider = _ScriptProvider('[NARRATION]\nInutilisé.');
    final chat = _chat(provider, IllustrationMode.suggestions);
    addTearDown(chat.dispose);
    chat.restoreTimeline(const [
      ChatEntry(id: 0, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Je regarde.'),
      ChatEntry(id: 1, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Le fanal perce le brouillard.'),
      ChatIllustrationIntent(id: 2, playerEventId: 0,
          description: 'Léa Monel sous le fanal.'),
      ChatEntry(id: 3, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Elle attend votre réponse.'),
    ]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
        GroupChatPage(controller: chat, onOpenSettings: () {}))));
    expect(find.byKey(const ValueKey('chatIllustrationPlaceholder')),
        findsOneWidget);
    expect(find.text('Léa Monel sous le fanal.'), findsOneWidget);
    expect(find.text('Génération indisponible pour le moment'), findsOneWidget);
    expect(find.text('Elle attend votre réponse.'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Générer'), findsNothing);
  });
}
