import 'dart:async';
import 'dart:convert';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/books/book_lore.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/narrator.dart';
import 'package:domolia/chat/raw_generation.dart';
import 'package:flutter_test/flutter_test.dart';

const credentials = AiConfiguration(
  baseUrl: defaultAiBaseUrl, model: defaultAiModel, apiKey: 'test-only');

String line(String text, {String speaker = 'narrator',
    String name = 'Narrateur', String? status}) =>
    '${jsonEncode({
      'type': 'message', 'speaker': speaker, 'name': name,
      'text': text, if (status != null) 'status': status,
    })}\n';

class _Provider implements AiChatProvider {
  String prose = 'La porte s’ouvre.';
  String? structured;
  bool fail = false;
  Completer<String>? gate;
  int calls = 0;
  final budgets = <int>[];
  List<AiMessage>? lastContext;

  String get response => structured ?? line(prose);

  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => [];
  @override
  Future<String> complete(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) async {
    calls++;
    budgets.add(maxTokens);
    lastContext = messages;
    if (fail) throw const AiProviderException('Narrateur en panne.');
    if (gate != null) return gate!.future;
    return response;
  }
}

Future<void> until(bool Function() predicate) async {
  for (var i = 0; i < 100 && !predicate(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(predicate(), true);
}

void main() {
  late _Provider provider;
  late NarrativeChatController chat;
  setUp(() {
    provider = _Provider();
    chat = NarrativeChatController(
        provider: provider, configuration: () => credentials);
  });
  tearDown(() => chat.dispose());

  test('one narrative request produces structured bubbles and SQLite source',
      () async {
    await chat.send('Je frappe.');
    expect(provider.calls, 1);
    expect(provider.lastContext!.first.content, contains('NDJSON'));
    expect(provider.lastContext!.first.content,
        isNot(contains('JSONificateur')));
    expect(chat.messages.map((m) => m.text),
        ['Je frappe.', 'La porte s’ouvre.']);
    expect(chat.rawGenerations.single.rawText, provider.prose);
    expect(chat.rawGenerations.single.isStructured, true);
    expect(chat.previewEvents, isEmpty);
    expect(chat.error, isNull);
  });

  test('narrator and characters form distinct messages with emotion and scene',
      () async {
    provider.structured =
        '${line('Le couloir est froid.')}'
        '${line('Avancez.', speaker: 'character', name: 'Oren',
            status: 'inquiet')}'
        '{"type":"scene_change"}\n'
        '${line('La pluie cesse.')}';
    await chat.send('Je suis Oren.');
    expect(chat.error, isNull);
    expect(chat.messages.map((m) => m.name),
        ['Vous', 'Narrateur', 'Oren', 'Narrateur']);
    expect(chat.messages[2].status, 'inquiet');
    expect(chat.timeline.whereType<ChatSceneChange>(), hasLength(1));
    expect(chat.rawGenerations.single.rawText,
        contains('Oren : Avancez.'));
    expect(provider.calls, 1);
  });

  test('invalid or empty NDJSON never publishes or persists partial story',
      () async {
    provider.structured = '${line('Début valide.')}{broken}\n';
    await chat.send('Une action.');
    expect(chat.error, isNotNull);
    expect(chat.messages, hasLength(1));
    expect(chat.rawGenerations, isEmpty);
    provider.structured = '';
    await chat.retry();
    expect(chat.messages, hasLength(1));
    expect(chat.error, isNotNull);
    provider.structured = line('Réponse valide.');
    await chat.retry();
    expect(chat.messages.map((m) => m.text),
        ['Une action.', 'Réponse valide.']);
    expect(provider.calls, 3);
  });

  test('impersonating the player is rejected before durable publication',
      () async {
    provider.structured = line('Je pars.',
        speaker: 'player', name: 'Vous');
    await chat.send('Bonjour.');
    expect(chat.error, isNotNull);
    expect(chat.rawGenerations, isEmpty);
    expect(chat.messages, hasLength(1));
  });

  test('canonical narrator prompt keeps configured interactive style',
      () async {
    const configured = Narrator(
      narrativePrompt: 'Ton : enquête concise.',
      tuning: NarrativeTuning(responseLength: 1, scenePacing: 1),
    );
    final local = NarrativeChatController(
        provider: provider, configuration: () => credentials,
        narrator: configured);
    addTearDown(local.dispose);
    await local.send('Je regarde.');
    final system = provider.lastContext!.first.content;
    expect(system, contains('Ton : enquête concise.'));
    expect(system, contains('Vise 45 à 90 mots'));
    expect(system, contains('NDJSON'));
  });

  test('an old saved RAW is recovered without calling another model',
      () async {
    chat.restoreTimeline(const [
      ChatEntry(id: 8, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Je frappe.'),
    ], rawGenerations: const [
      RawGeneration(playerEventId: 8, rawText: 'Ancien texte conservé.'),
    ]);
    expect(chat.pendingRaw, isNotNull);
    await chat.retry();
    expect(provider.calls, 0);
    expect(chat.messages.last.text, 'Ancien texte conservé.');
    expect(chat.pendingRaw, isNull);
    expect(chat.rawGenerations.single.isStructured, true);
  });

  test('legacy sessions without generations preserve visible history',
      () async {
    chat.restoreTimeline(const [
      ChatEntry(id: 1, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Avant.'),
      ChatEntry(id: 2, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Texte ancien.'),
    ]);
    await chat.send('Maintenant.');
    expect(provider.lastContext!.map((m) => m.content).join(' '),
        contains('Texte ancien.'));
  });

  test('story source remains in context across turns, without JSON markers',
      () async {
    provider.prose = 'Premier texte original.';
    await chat.send('Premier tour.');
    provider.prose = 'Deuxième texte original.';
    await chat.send('Second tour.');
    final values = provider.lastContext!.map((m) => m.content).join(' ');
    expect(values, contains('Premier texte original.'));
    expect(values, contains('Premier tour.'));
    expect(values, isNot(contains('"speaker":"narrator"')));
    expect(chat.rawGenerations, hasLength(2));
  });

  test('explicit Lore remains available to the narrator', () async {
    const lore = BookLore(
      global: LoreGlobal(universe: 'Les Marches de Verre'),
      characters: [LoreCharacter(id: 'oren', name: 'Oren',
          description: 'Un aubergiste discret.')],
    );
    final local = NarrativeChatController(
        provider: provider, configuration: () => credentials,
        loreProvider: () => lore);
    addTearDown(local.dispose);
    await local.send('Je parle à Oren.');
    expect(provider.lastContext!.first.content,
        contains('Les Marches de Verre'));
    expect(provider.lastContext!.first.content, contains('Oren'));
  });

  test('regeneration replaces only the current reply', () async {
    await chat.send('Je regarde.');
    provider.prose = 'La porte est fermée.';
    await chat.regenerate();
    expect(chat.messages.map((m) => m.text),
        ['Je regarde.', 'La porte est fermée.']);
    expect(chat.rawGenerations, hasLength(1));
  });

  test('edit and rewind remove obsolete answers and generations', () async {
    await chat.send('Tour un.');
    final first = chat.messages.first.id;
    provider.prose = 'Deuxième réponse.';
    await chat.send('Tour deux.');
    expect(chat.rawGenerations, hasLength(2));
    expect(chat.editPlayerMessage(first, 'Tour un corrigé.'), isTrue);
    provider.prose = 'Réponse corrigée.';
    expect(await chat.resumeFromPlayerMessage(first), isTrue);
    expect(chat.rawGenerations, hasLength(1));
    expect(chat.messages.map((m) => m.text),
        ['Tour un corrigé.', 'Réponse corrigée.']);
  });

  test('manual scene boundaries retain committed message IDs', () async {
    await chat.send('Je regarde.');
    final id = chat.messages.last.id;
    expect(chat.startSceneAt(id), true);
    expect(chat.hasSceneChangeBefore(id), true);
    expect(chat.messages.last.id, id);
    expect(chat.removeSceneBefore(id), true);
    expect(chat.hasSceneChangeBefore(id), false);
  });

  test('late completion after stop never leaks drafts or creates a source',
      () async {
    final hold = Completer<String>();
    provider.gate = hold;
    final sending = chat.send('Je regarde.');
    await until(() => provider.calls == 1);
    chat.stop();
    hold.complete(line('Une réponse trop tardive.'));
    await sending;
    expect(chat.messages, hasLength(1));
    expect(chat.rawGenerations, isEmpty);
    expect(chat.busy, false);
  });

  test('a failed request leaves no memory source and can retry',
      () async {
    provider.fail = true;
    await chat.send('Je pars.');
    expect(chat.error, isNotNull);
    expect(chat.rawGenerations, isEmpty);
    provider.fail = false;
    await chat.retry();
    expect(chat.error, isNull);
    expect(provider.calls, 2);
  });

  test('pending SQLite commit does not publish a partial turn', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final local = NarrativeChatController(
      provider: provider, configuration: () => credentials,
      onPersistState: (events, raws) async {
        if (raws.any((r) => r.isStructured)) {
          entered.complete();
          await release.future;
        }
      },
    );
    addTearDown(local.dispose);
    final sending = local.send('Je frappe.');
    await entered.future;
    expect(local.messages, hasLength(1));
    expect(local.busy, isTrue);
    local.stop();
    expect(local.busy, isTrue,
        reason: 'Irreversible SQLite transaction in progress.');
    release.complete();
    await sending;
    expect(local.messages.last.text, provider.prose);
    expect(local.rawGenerations.single.isStructured, isTrue);
    expect(local.busy, isFalse);
  });

  test('failed SQLite transaction is not a partially committed reply',
      () async {
    var fail = true;
    final local = NarrativeChatController(
      provider: provider, configuration: () => credentials,
      onPersistState: (events, raws) async {
        if (fail && raws.any((r) => r.isStructured)) {
          throw StateError('SQLite refused transaction');
        }
      },
    );
    addTearDown(local.dispose);
    await local.send('Je frappe.');
    expect(local.messages, hasLength(1));
    expect(local.rawGenerations, isEmpty);
    expect(local.error, isNotNull);
    fail = false;
    await local.retry();
    expect(local.messages, hasLength(2));
    expect(provider.calls, 2);
  });

  test('the old formatter endpoint is never contacted', () async {
    final formatter = _Provider();
    final local = NarrativeChatController(
      provider: provider, configuration: () => credentials,
      resolveFormatterConnection: () async => NarrativeAiEndpoint(
        provider: formatter, configuration: credentials),
    );
    addTearDown(local.dispose);
    await local.send('Bonjour.');
    expect(provider.calls, 1);
    expect(formatter.calls, 0);
  });

  test('narrator output budget remains configurable without a second LLM',
      () async {
    final local = NarrativeChatController(
      provider: provider, configuration: () => credentials,
      resolveConnection: () async => NarrativeAiEndpoint(
        provider: provider, configuration: credentials, maxOutputTokens: 900),
    );
    addTearDown(local.dispose);
    await local.send('Bonjour.');
    expect(provider.budgets, [900]);
  });
}
