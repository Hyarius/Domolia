import 'dart:async';
import 'dart:convert';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/books/book_lore.dart';
import 'package:domolia/books/lore_context_optimizer.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/jsonifier.dart';
import 'package:domolia/chat/raw_generation.dart';
import 'package:flutter_test/flutter_test.dart';

const credentials = AiConfiguration(
  baseUrl: defaultAiBaseUrl, model: defaultAiModel, apiKey: 'test-only',
);

String format(String raw, {String speaker = 'narrator',
    String name = 'Narrateur', bool scene = false}) => jsonEncode({
  'events': [
    if (scene) {'type': 'scene_change', 'at': 0},
    {'type': 'message', 'start': 0, 'end': raw.length,
      'speaker': speaker, 'name': name},
  ],
});

class _Provider implements AiChatProvider {
  String raw = 'La porte s’ouvre.';
  String? structured;
  int rawCalls = 0;
  int formatCalls = 0;
  final outputBudgets = <int>[];
  bool failRaw = false;
  bool failFormat = false;
  List<AiMessage>? narrativeContext;
  List<AiMessage>? formatterContext;
  Completer<String>? heldRaw;
  Completer<String>? heldFormat;

  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => [];

  @override
  Future<String> complete(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) async {
    outputBudgets.add(maxTokens);
    if (messages.first.content.contains('JSONificateur')) {
      formatCalls++;
      formatterContext = messages;
      if (failFormat) throw const AiProviderException('JSONification en panne.');
      if (heldFormat != null) return heldFormat!.future;
      return structured ?? format(raw);
    }
    rawCalls++;
    narrativeContext = messages;
    if (failRaw) throw const AiProviderException('Narrateur en panne.');
    if (heldRaw != null) return heldRaw!.future;
    return raw;
  }
}

class _StreamingProvider implements AiChatProvider, AiStreamingChatProvider {
  final raw = StreamController<AiStreamChunk>.broadcast();
  final json = StreamController<AiStreamChunk>.broadcast();
  int rawCalls = 0, formatCalls = 0;
  @override
  Stream<AiStreamChunk> streamChat(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) {
    if (messages.first.content.contains('JSONificateur')) {
      formatCalls++;
      return json.stream;
    }
    rawCalls++;
    return raw.stream;
  }
  @override
  Future<String> complete(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) => throw StateError('stream required');
  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => [];
}

class _ContextProvider implements AiChatProvider {
  _ContextProvider(this.summary);
  String summary;
  int calls = 0;
  final outputBudgets = <int>[];
  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => const [];
  @override
  Future<String> complete(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) async {
    calls++;
    outputBudgets.add(maxTokens);
    expect(messages.first.content, contains('compresseur'));
    return summary;
  }
}

BookLore _largeLore() => BookLore(
  global: LoreGlobal(
    universe: 'Skogheim',
    overview: List.filled(115, 'Pierres, montagnes et fjord').join(' '),
    rules: 'Les événements restent hypothétiques.',
  ),
  characters: [
    LoreCharacter(id:'astrid',name:'Astrid',
      description: List.filled(280, 'Astrid veille au foyer.').join(' ')),
  ],
);

void main() {
  late _Provider provider;
  late NarrativeChatController chat;
  setUp(() {
    provider = _Provider();
    chat = NarrativeChatController(
      provider: provider, configuration: () => credentials,
    );
  });
  tearDown(() => chat.dispose());

  test('Two passes: literary context, RAW retained, committed bubbles only', () async {
    await chat.send('Je frappe.');
    expect(provider.rawCalls, 1);
    expect(provider.formatCalls, 1);
    expect(provider.narrativeContext!.first.content, isNot(contains('NDJSON')));
    expect(provider.narrativeContext!.first.content, isNot(contains('scene_change')));
    expect(provider.formatterContext!.first.content, jsonifierSystemPrompt);
    expect(chat.messages.map((m) => m.text), ['Je frappe.', 'La porte s’ouvre.']);
    expect(chat.rawGenerations.single.rawText, 'La porte s’ouvre.');
    expect(chat.rawGenerations.single.isStructured, isTrue);
    expect(chat.preview, isNull);
  });

  test('RAW survives a failed formatter and retry never reruns narrator', () async {
    provider.failFormat = true;
    await chat.send('J’entre.');
    expect(chat.error, isNotNull);
    expect(chat.messages, hasLength(1));
    expect(chat.pendingRaw!.rawText, provider.raw);
    provider.failFormat = false;
    await chat.retry();
    expect(provider.rawCalls, 1);
    expect(provider.formatCalls, 2);
    expect(chat.messages, hasLength(2));
    expect(chat.pendingRaw, isNull);
    expect(chat.error, isNull);
  });

  test('A failed first pass leaves no RAW or AI bubble', () async {
    provider.failRaw = true;
    await chat.send('Je parle.');
    expect(chat.messages, hasLength(1));
    expect(chat.rawGenerations, isEmpty);
    expect(provider.formatCalls, 0);
    expect(chat.error, isNotNull);
    provider.failRaw = false;
    await chat.retry();
    expect(provider.rawCalls, 2);
  });

  test('Empty or invalid formatter leaves the entire RAW pending', () async {
    provider.structured = '{"events":[]}';
    await chat.send('Je regarde.');
    expect(chat.messages, hasLength(1));
    expect(chat.pendingRaw, isNotNull);
    provider.structured = format(provider.raw);
    await chat.retry();
    expect(chat.messages, hasLength(2));
  });

  test('No partial event appears until the SQLite snapshot completes', () async {
    final gate = Completer<void>();
    final persisted = <List<RawGeneration>>[];
    final local = NarrativeChatController(
      provider: provider, configuration: () => credentials,
      onPersistState: (events, raws) async {
        persisted.add(List.of(raws));
        if (raws.any((e) => e.isStructured)) await gate.future;
      },
    );
    addTearDown(local.dispose);
    final pending = local.send('Test');
    for (var i = 0; i < 20 && persisted.length < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(persisted.any((r) => r.any((e) => e.isStructured)), isTrue);
    expect(local.messages, hasLength(1));
    expect(local.busy, true);
    gate.complete();
    await pending;
    expect(local.messages, hasLength(2));
  });

  test('RAW becomes narrator context in the correct order, not bubble JSON', () async {
    provider.raw = 'Premier texte original.';
    await chat.send('Première action');
    provider.raw = 'Deuxième texte original.';
    await chat.send('Seconde action');
    final contents = provider.narrativeContext!.skip(1).map((e) => e.content).toList();
    expect(contents, containsAllInOrder([
      'Première action', 'Premier texte original.', 'Seconde action',
    ]));
    expect(contents.join(), isNot(contains('"speaker"')));
  });

  test('Legacy sessions still use visible structured messages as fallback', () async {
    chat.restoreTimeline(const [
      ChatEntry(id: 0, speaker: ChatSpeaker.player, name: 'Vous', text: 'Salut'),
      ChatEntry(id: 1, speaker: ChatSpeaker.character, name: 'Lina', text: 'Bonjour'),
    ]);
    await chat.send('Une question');
    expect(provider.narrativeContext!.map((e) => e.content),
        contains('Lina : Bonjour'));
  });

  test('Restored RAW in pending state exposes retry immediately', () async {
    chat.restoreTimeline(const [
      ChatEntry(id: 8, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'J’entre.'),
    ], rawGenerations: const [
      RawGeneration(playerEventId: 8, rawText: 'Texte RAW conservé.'),
    ]);
    expect(chat.error, contains('mise en forme'));
    expect(chat.pendingRaw!.rawText, 'Texte RAW conservé.');
    provider.structured = format('Texte RAW conservé.');
    await chat.retry();
    expect(provider.rawCalls, 0);
    expect(provider.formatCalls, 1);
    expect(chat.error, isNull);
    expect(chat.messages.last.text, 'Texte RAW conservé.');
  });

  test('Regenerate discards old RAW and never duplicates player text', () async {
    await chat.send('Test');
    provider.raw = 'Réponse deux.';
    await chat.regenerate();
    expect(provider.rawCalls, 2);
    expect(chat.messages.map((m) => m.text), ['Test', 'Réponse deux.']);
    expect(chat.rawGenerations.single.rawText, 'Réponse deux.');
  });

  test('Rewind from older player drops obsolete generations', () async {
    await chat.send('Tour un');
    await chat.send('Tour deux');
    final firstId = chat.messages.first.id;
    expect(chat.editPlayerMessage(firstId, 'Tour un corrigé'), isTrue);
    expect(await chat.resumeFromPlayerMessage(firstId), isTrue);
    expect(chat.messages.where((e) => e.speaker == ChatSpeaker.player),
        hasLength(1));
    expect(chat.rawGenerations, hasLength(1));
  });

  test('Manual scene changes retain every existing event ID', () async {
    await chat.send('Test');
    final id = chat.messages.last.id;
    final firstId = chat.messages.first.id;
    expect(chat.startSceneAt(id), isTrue);
    expect(chat.hasSceneChangeBefore(id), isTrue);
    expect(chat.messages.first.id, firstId);
    expect(chat.messages.last.id, id);
    expect(chat.removeSceneBefore(id), isTrue);
    expect(chat.hasSceneChangeBefore(id), isFalse);
  });

  test('A scene transition from the previous turn can lead the new reply', () async {
    provider.raw = 'Le temple souterrain se dévoile.';
    provider.structured = format(provider.raw, scene: true);
    await chat.send('Nous quittons la grotte et arrivons au temple.');
    expect(chat.timeline.whereType<ChatSceneChange>(), hasLength(1));
    expect(chat.timeline.last, isA<ChatEntry>());
  });

  test('Late result after stop is never published', () async {
    final hold = Completer<String>();
    provider.heldRaw = hold;
    final task = chat.send('Une action');
    await Future<void>.delayed(Duration.zero);
    chat.stop();
    hold.complete(provider.raw);
    await task;
    expect(chat.messages, hasLength(1));
    expect(provider.formatCalls, 0);
  });

  test('Late formatter result after stop preserves pending RAW only', () async {
    final hold = Completer<String>();
    provider.heldFormat = hold;
    final task = chat.send('Une action');
    for (var i = 0; i < 30 && provider.formatCalls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(chat.pendingRaw, isNotNull);
    chat.stop();
    hold.complete(format(provider.raw));
    await task;
    expect(chat.messages, hasLength(1));
  });

  test('Streaming buffers RAW and JSON instead of revealing draft bubbles', () async {
    final streaming = _StreamingProvider();
    final local = NarrativeChatController(
      provider: streaming, configuration: () => credentials,
    );
    addTearDown(local.dispose);
    final task = local.send('Test');
    for (var i = 0; i < 20 && streaming.rawCalls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    streaming.raw.add(const AiStreamChunk(text: 'Le te'));
    await Future<void>.delayed(Duration.zero);
    expect(local.messages, hasLength(1));
    expect(local.preview, isNull);
    streaming.raw.add(const AiStreamChunk(text: 'mple.'));
    await streaming.raw.close();
    for (var i = 0; i < 20 && streaming.formatCalls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(local.messages, hasLength(1));
    streaming.json.add(AiStreamChunk(text: format('Le temple.')));
    await streaming.json.close();
    await task;
    expect(local.messages.last.text, 'Le temple.');
  });

  test('Editing a player turn is blocked while its RAW still awaits JSONification',
      () async {
    provider.failFormat = true;
    await chat.send('Action initiale');
    final playerId = chat.messages.first.id;
    expect(chat.pendingRaw, isNotNull);
    expect(chat.editPlayerMessage(playerId, 'Action modifiée'), isFalse);
    expect(chat.messages.first.text, 'Action initiale');
    provider.failFormat = false;
    await chat.retry();
    expect(provider.rawCalls, 1);
    expect(chat.messages.last.text, provider.raw);
  });

  test('Inserting and removing a scene before the last player keeps regeneration on that turn',
      () async {
    await chat.send('Premier tour');
    await chat.send('Deuxième tour');
    final firstAiId = chat.messages[1].id;
    final secondPlayerId = chat.messages[2].id;
    expect(chat.startSceneAt(firstAiId), isTrue);
    provider.raw = 'Réponse remplacée.';
    await chat.regenerate();
    expect(chat.messages.where((m) => m.speaker == ChatSpeaker.player)
        .map((m) => m.id), [chat.messages.first.id, secondPlayerId]);
    expect(chat.messages.last.text, 'Réponse remplacée.');
    expect(chat.rawGenerations, hasLength(2));
    expect(chat.rawGenerations.last.playerEventId, secondPlayerId);

    expect(chat.removeSceneBefore(firstAiId), isTrue);
    provider.raw = 'Troisième réponse.';
    await chat.regenerate();
    expect(chat.messages.last.text, 'Troisième réponse.');
    expect(chat.rawGenerations.last.playerEventId, secondPlayerId);
  });

  test('Cancellation during the durable RAW save retains it for retry',
      () async {
    final enteredSave = Completer<void>();
    final releaseSave = Completer<void>();
    final local = NarrativeChatController(
      provider: provider,
      configuration: () => credentials,
      onPersistState: (events, raws) async {
        if (raws.any((r) => !r.isStructured) && !enteredSave.isCompleted) {
          enteredSave.complete();
          await releaseSave.future;
        }
      },
    );
    addTearDown(local.dispose);
    final initial = local.send('Je regarde');
    await enteredSave.future;
    local.stop();
    releaseSave.complete();
    await initial;
    expect(local.messages, hasLength(1));
    expect(local.pendingRaw?.rawText, provider.raw);
    await local.retry();
    expect(provider.rawCalls, 1);
    expect(provider.formatCalls, 1);
    expect(local.messages, hasLength(2));
  });

  test('Failed final snapshot keeps the RAW and never publishes partial bubbles',
      () async {
    var failCommit = true;
    final local = NarrativeChatController(
      provider: provider,
      configuration: () => credentials,
      onPersistState: (events, raws) async {
        if (failCommit && raws.any((r) => r.isStructured)) {
          throw StateError('transaction refused');
        }
      },
    );
    addTearDown(local.dispose);
    await local.send('Je m’avance');
    expect(local.messages, hasLength(1));
    expect(local.pendingRaw?.rawText, provider.raw);
    expect(local.error, isNotNull);
    failCommit = false;
    await local.retry();
    expect(provider.rawCalls, 1);
    expect(provider.formatCalls, 2);
    expect(local.messages, hasLength(2));
    expect(local.pendingRaw, isNull);
  });

  test('Several generated events become visible together only after commit',
      () async {
    const first = 'Dans la cour. ';
    const second = 'Brann : « Viens ! »';
    provider.raw = first + second;
    provider.structured = jsonEncode({'events': [
      {'type': 'scene_change', 'at': 0},
      {'type': 'message', 'start': 0, 'end': first.length,
        'speaker': 'narrator', 'name': 'Narrateur'},
      {'type': 'message', 'start': first.length,
        'end': provider.raw.length, 'speaker': 'character', 'name': 'Brann'},
    ]});
    final commitStarted = Completer<void>();
    final finishCommit = Completer<void>();
    final local = NarrativeChatController(
      provider: provider, configuration: () => credentials,
      onPersistState: (events, raws) async {
        if (raws.any((r) => r.isStructured)) {
          commitStarted.complete();
          await finishCommit.future;
        }
      },
    );
    addTearDown(local.dispose);
    final sending = local.send('Nous changeons de lieu');
    await commitStarted.future;
    expect(local.messages, hasLength(1));
    expect(local.timeline.whereType<ChatSceneChange>(), isEmpty);
    finishCommit.complete();
    await sending;
    expect(local.messages, hasLength(3));
    expect(local.timeline.whereType<ChatSceneChange>(), hasLength(1));
  });

  test('A distinct formatter endpoint does not change the narrator model',
      () async {
    final formatter = _Provider()..structured = format(provider.raw);
    final local = NarrativeChatController(
      provider: provider,
      configuration: () => credentials,
      resolveFormatterConnection: () async => NarrativeAiEndpoint(
        provider: formatter, configuration: credentials,
      ),
    );
    addTearDown(local.dispose);
    await local.send('Action');
    expect(provider.rawCalls, 1);
    expect(provider.formatCalls, 0);
    expect(formatter.rawCalls, 0);
    expect(formatter.formatCalls, 1);
    expect(local.messages.last.text, provider.raw);
  });


  test('Stop during the final transaction cannot leave a committed but invisible reply',
      () async {
    final commitStarted = Completer<void>();
    final releaseCommit = Completer<void>();
    final local = NarrativeChatController(
      provider: provider,
      configuration: () => credentials,
      onPersistState: (events, raws) async {
        if (raws.any((r) => r.isStructured)) {
          commitStarted.complete();
          await releaseCommit.future;
        }
      },
    );
    addTearDown(local.dispose);
    final task = local.send('Je regarde la salle');
    await commitStarted.future;
    expect(local.messages, hasLength(1));
    local.stop();
    expect(local.busy, isTrue,
        reason: 'The final SQLite commit is already irreversible.');
    releaseCommit.complete();
    await task;
    expect(local.messages.last.text, provider.raw);
    expect(local.rawGenerations.single.isStructured, isTrue);
    expect(local.pendingRaw, isNull);
    expect(local.busy, isFalse);
  });


  test('Lore optimization is compiled once, cached across turns and restarts',
      () async {
    final lore = _largeLore();
    final summary = 'Skogheim. Astrid, prêtresse principale. '
        '${List.filled(75, "Vie ordinaire").join(" ")}';
    final optimizer = _ContextProvider(summary);
    String? cached, hash;
    final local = NarrativeChatController(
      provider: provider, configuration: () => credentials,
      loreProvider: () => lore,
      resolveOptimizerConnection: () async =>
          NarrativeAiEndpoint(provider: optimizer, configuration: credentials),
      onOptimizedLore: (h, s) async { hash = h; cached = s; },
    );
    addTearDown(local.dispose);
    await local.send('Bonjour');
    expect(optimizer.calls, 1);
    expect(cached, summary);
    expect(hash, const LoreContextOptimizer().sourceHash(lore));
    expect(provider.narrativeContext!.first.content,
      contains('LORE CANONIQUE RÉSUMÉ'));
    await local.send('Je m’assieds.');
    expect(optimizer.calls, 1);

    final reopened = NarrativeChatController(
      provider: provider, configuration: () => credentials,
      loreProvider: () => lore,
      resolveOptimizerConnection: () async =>
          NarrativeAiEndpoint(provider: optimizer, configuration: credentials),
      initialOptimizedLore: cached, initialOptimizedLoreHash: hash,
    );
    addTearDown(reopened.dispose);
    await reopened.send('Je regarde dehors.');
    expect(optimizer.calls, 1);
    expect(reopened.messages.last.text, provider.raw);

    expect(local.requestLoreRecompilation(), true);
    await local.send('Une nouvelle journée commence.');
    expect(optimizer.calls, 2);
  });

  test('Invalid summary never prevents storytelling or replaces canonical Lore',
      () async {
    final lore = _largeLore();
    final optimizer = _ContextProvider('Résumé incomplet');
    String? persisted;
    final local = NarrativeChatController(
      provider: provider, configuration: () => credentials,
      loreProvider: () => lore,
      resolveOptimizerConnection: () async =>
          NarrativeAiEndpoint(provider: optimizer, configuration: credentials),
      onOptimizedLore: (h, s) async { persisted = s; },
    );
    addTearDown(local.dispose);
    await local.send('Un pas.');
    expect(optimizer.calls, 1);
    expect(persisted, isEmpty);
    expect(local.messages.last.text, provider.raw);
    expect(provider.narrativeContext!.first.content,
      contains('CANON DU MONDE'));
    expect(provider.narrativeContext!.first.content,
      isNot(contains('LORE CANONIQUE RÉSUMÉ')));
  });

  test('Disabling optimization ignores an existing cached summary',
      () async {
    final lore = _largeLore();
    final local = NarrativeChatController(
      provider: provider, configuration: () => credentials,
      loreProvider: () => lore,
      initialOptimizedLore: 'Skogheim Astrid résumé ancien. '
        '${List.filled(75, "Résumé").join(" ")}',
      initialOptimizedLoreHash:
        const LoreContextOptimizer().sourceHash(lore),
      resolveOptimizerConnection: () async => null,
    );
    addTearDown(local.dispose);
    await local.send('Je me présente.');
    expect(local.messages.last.text, provider.raw);
    expect(provider.narrativeContext!.first.content,
      contains('CANON DU MONDE'));
    expect(provider.narrativeContext!.first.content,
      isNot(contains('LORE CANONIQUE RÉSUMÉ')));
  });

  test('All three real pipeline stages use independent output budgets', () async {
    final source = _largeLore();
    final summary = 'Skogheim Astrid. ${List.filled(80, "Vie quotidienne").join(" ")}';
    final optimizer = _ContextProvider(summary);
    final formatter = _Provider()..structured = format(provider.raw);
    const config = AiConfiguration(
      baseUrl: defaultAiBaseUrl, model: 'gpt-5.6-luna',
      apiKey: 'test-only',
    );
    final local = NarrativeChatController(
      provider: provider, configuration: () => config,
      loreProvider: () => source,
      resolveConnection: () async => NarrativeAiEndpoint(
        provider: provider,
        configuration: config.withReasoning('low'),
        maxOutputTokens: 8192,
      ),
      resolveFormatterConnection: () async => NarrativeAiEndpoint(
        provider: formatter,
        configuration: config.withReasoning('none'),
        maxOutputTokens: 4096,
      ),
      resolveOptimizerConnection: () async => NarrativeAiEndpoint(
        provider: optimizer,
        configuration: config.withReasoning('low'),
        maxOutputTokens: 16384,
      ),
    );
    addTearDown(local.dispose);
    await local.send('Bonjour');
    expect(optimizer.outputBudgets, [16384]);
    expect(provider.outputBudgets, [8192]);
    expect(formatter.outputBudgets, [4096]);
    expect(local.messages.last.text, provider.raw);
    await local.send('Encore');
    expect(optimizer.outputBudgets, [16384],
      reason: 'Never redo a successful compilation per scene.');
    expect(provider.outputBudgets, [8192, 8192]);
    expect(formatter.outputBudgets, [4096, 4096]);
  });

  test('New numbered-block JSONifier preserves source and character voices',
      () async {
    provider.raw = 'Les pierres sont froides.\n\n'
        'Astrid : « Vous êtes à Skogheim. »\n\n'
        'Liv observe le plafond.\n\n'
        'Liv : « Nous avons prié. »';
    provider.structured = jsonEncode({'events': [
      {'type': 'message', 'block': 0,
        'speaker': 'narrator', 'name': 'Narrateur'},
      {'type': 'message', 'block': 1,
        'speaker': 'character', 'name': 'Astrid'},
      {'type': 'message', 'block': 2,
        'speaker': 'narrator', 'name': 'Narrateur'},
      {'type': 'message', 'block': 3,
        'speaker': 'character', 'name': 'Liv'},
    ]});
    await chat.send('Où suis-je ?');
    expect(chat.error, isNull);
    expect(chat.messages.skip(1).map((e) => e.name),
      ['Narrateur', 'Astrid', 'Narrateur', 'Liv']);
    expect(chat.messages.skip(1).map((e) => e.text).join(), provider.raw);
    expect(provider.rawCalls, 1);
    expect(provider.formatCalls, 1);
    final formattedRequest = provider.formatterContext![1].content;
    expect(formattedRequest, contains('Partie 0 (prose)'));
    expect(formattedRequest, contains('Partie 6 (citation)'));
    expect(formattedRequest, isNot(contains('UTF-16')));
    expect(chat.pendingRaw, isNull);
  });

  test('Bad block labels keep RAW intact until retry with correct numbering',
      () async {
    provider.raw = 'Un couloir.\n\nAstrid : « Bonjour ! »';
    provider.structured = jsonEncode({'events': [
      {'type': 'message', 'block': 0,
        'speaker': 'narrator', 'name': 'Narrateur'},
      {'type': 'message', 'block': 999,
        'speaker': 'character', 'name': 'Astrid'},
    ]});
    await chat.send('Bonjour');
    expect(chat.pendingRaw!.rawText, provider.raw);
    expect(chat.messages, hasLength(1));
    expect(chat.error, isNotNull);
    provider.structured = jsonEncode({'events': [
      {'type': 'message', 'block': 0,
        'speaker': 'narrator', 'name': 'Narrateur'},
      {'type': 'message', 'block': 1,
        'speaker': 'character', 'name': 'Astrid'},
    ]});
    await chat.retry();
    expect(chat.error, isNull);
    expect(chat.pendingRaw, isNull);
    expect(provider.rawCalls, 1);
    expect(provider.formatCalls, 2);
    expect(chat.messages.skip(1).map((e) => e.text).join(), provider.raw);
  });

  test('Pipeline persists clean split dialogue, emotion and original RAW',
      () async {
    provider.raw = 'Liv, étonnée : « Quoi ?! » ajouta-t-elle. '
        '« Ce n’est pas possible ! »';
    provider.structured = jsonEncode({'events': [
      {'type': 'part', 'part': 0, 'kind': 'aside'},
      {'type': 'part', 'part': 1, 'kind': 'dialogue',
        'name': 'Liv', 'status': 'étonnée'},
      {'type': 'part', 'part': 2, 'kind': 'aside'},
      {'type': 'part', 'part': 3, 'kind': 'dialogue',
        'name': 'Liv', 'status': 'incrédule'},
    ]});
    await chat.send('Que se passe-t-il ?');
    expect(chat.error, isNull);
    final speeches = chat.messages.skip(1).toList();
    expect(speeches.map((e) => e.name), ['Liv', 'Liv']);
    expect(speeches.map((e) => e.text),
        ['Quoi ?!', 'Ce n’est pas possible !']);
    expect(speeches.map((e) => e.status), ['étonnée', 'incrédule']);
    expect(chat.rawGenerations.single.rawText, provider.raw);
    expect(chat.rawGenerations.single.isStructured, isTrue);
    expect(provider.formatterContext![1].content,
        contains('Partie 1 (citation)'));
  });

}
