import 'dart:async';

import 'package:domolia/ai/ai_controller.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/chatgpt_auth.dart';
import 'package:flutter_test/flutter_test.dart';

class InMemoryEncryptedStore implements AiProfileStore {
  AiProfilesState? stored;
  bool failWrite = false;

  @override
  Future<AiProfilesState?> read() async => stored;

  @override
  Future<void> write(AiProfilesState state) async {
    if (failWrite) throw const FormatException('Sensitive storage details');
    stored = AiProfilesState(
      profiles: List.of(state.profiles),
      selectedId: state.selectedId,
    );
  }
}

class FakeChatProvider implements AiChatProvider {
  bool offline = false;
  int calls = 0;
  Completer<String>? gate;
  AiConfiguration? lastConfiguration;

  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async {
    lastConfiguration = configuration;
    return [const AiModel('model-a'), const AiModel('model-b')];
  }

  @override
  Future<String> complete(
    AiConfiguration configuration, {
    required List<AiMessage> messages,
    int maxTokens = 64,
  }) async {
    calls++;
    lastConfiguration = configuration;
    if (offline) {
      throw const AiProviderException('Clé API refusée. Vérifiez votre clé.');
    }
    expect(maxTokens, 64);
    expect(messages.single.role, 'user');
    if (gate != null) return gate!.future;
    return 'Connexion établie, bonjour !';
  }
}

class FakeChatGptAccount implements ChatGptAccountService {
  int catalogueCalls = 0;
  List<AiModel> catalogue = [
    const AiModel('gpt-test'),
    const AiModel('gpt-secondary'),
  ];

  @override
  Future<ChatGptSession?> session(String id) async => signIn(id);

  @override
  Future<ChatGptSession> signIn(String id) async => ChatGptSession(
    clientId: 'test-client',
    subject: 'test-user',
    email: 'test@example.org',
    idToken: 'test-id',
    accessToken: 'test-access',
    refreshToken: 'test-refresh',
    scopes: {'chatgpt.tokens.use.direct', 'resource.invoke'},
    expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  );

  @override
  Future<String> accessToken(String id) async => 'test-access';

  @override
  Future<List<AiModel>> listModels(String id) async {
    catalogueCalls++;
    return catalogue;
  }

  @override
  Future<void> disconnect(String id) async {}

  @override
  Future<void> delete(String id) async {}
}

void main() {
  late InMemoryEncryptedStore store;
  late FakeChatProvider provider;
  late AiConnectionController controller;

  setUp(() {
    store = InMemoryEncryptedStore();
    provider = FakeChatProvider();
    controller = AiConnectionController(store: store, provider: provider);
  });
  tearDown(() => controller.dispose());


  test('OpenAI image-only profile validates API key without a chat request',
      () async {
    await controller.initialize();
    expect(await controller.save(
        'https://api.openai.com/v1', '', 'sk-test'), true);
    expect(controller.imageOnlyProfile, true);
    expect(controller.model, isEmpty);
    await controller.testConnection();
    expect(controller.status, AiConnectionStatus.connected);
    expect(controller.testReply, contains('Génération d’image non testée'));
    expect(provider.calls, 0, reason: 'No billed chat completion');
    expect(provider.lastConfiguration!.model, isEmpty);

    // An old image model stored as a chat model is also migrated safely.
    expect(await controller.save(
        'https://api.openai.com/v1', 'gpt-image-2.6-flare', ''), true);
    expect(controller.model, isEmpty);

    final restart = AiConnectionController(store: store, provider: provider);
    addTearDown(restart.dispose);
    await restart.initialize();
    expect(restart.imageOnlyProfile, true);
    expect(restart.hasKey, true);
    expect(restart.model, isEmpty);
  });

  test('Image-only setting is rejected on unrelated chat providers', () async {
    await controller.initialize();
    expect(await controller.save(defaultAiBaseUrl, '', 'ou-key'), false);
    expect(controller.message, contains('identifiant de modèle'));
    expect(controller.model, defaultAiModel);
  });

  test('Legacy single-profile behavior persists through restart', () async {
    await controller.initialize();
    expect(controller.profiles, hasLength(1));
    expect(controller.selectedProfile.name, 'OpenUncensored');
    expect(controller.hasKey, false);
    expect(await controller.save(defaultAiBaseUrl, 'model-a', 'ou-my-key'), true);
    expect(controller.hasKey, true);

    final restarted = AiConnectionController(store: store, provider: provider);
    await restarted.initialize();
    expect(restarted.hasKey, true);
    expect(restarted.baseUrl, defaultAiBaseUrl);
    expect(restarted.model, 'model-a');
    expect(await restarted.save(defaultAiBaseUrl, 'model-b', ''), true);
    expect(store.stored!.profiles.single.apiKey, 'ou-my-key');
    expect(store.stored!.profiles.single.model, 'model-b');
    await restarted.loadModels();
    expect(restarted.models.map((m) => m.id), ['model-a', 'model-b']);
    await restarted.testConnection();
    expect(restarted.testPassed, true);
    expect(restarted.testReply, contains('bonjour'));
    expect(provider.calls, 1);
    await restarted.removeKey();
    expect(restarted.hasKey, false);
    expect(store.stored!.profiles.single.apiKey, '');
    restarted.dispose();
  });

  test('Create, rename, select and delete profiles keep credentials separate', () async {
    await controller.initialize();
    final originalId = controller.selectedProfileId;
    await controller.save(defaultAiBaseUrl, 'model-a', 'ou-first');
    expect(await controller.createProfile('Compte de test'), true);
    final secondId = controller.selectedProfileId;
    expect(secondId, isNot(originalId));
    expect(controller.selectedProfile.name, 'Compte de test');
    expect(controller.hasKey, false);
    expect(controller.status, AiConnectionStatus.untested);

    await controller.save('https://example.org/v1', 'model-b', 'ou-second');
    expect(await controller.renameProfile('Secondaire'), true);
    expect(controller.selectedProfile.name, 'Secondaire');
    expect(controller.profiles, hasLength(2));
    expect(await controller.selectProfile(originalId), true);
    expect(controller.model, 'model-a');
    expect(controller.hasKey, true);
    await controller.testConnection();
    expect(provider.lastConfiguration!.apiKey, 'ou-first');

    expect(await controller.selectProfile(secondId), true);
    expect(controller.baseUrl, 'https://example.org/v1');
    expect(controller.model, 'model-b');
    await controller.testConnection();
    expect(provider.lastConfiguration!.apiKey, 'ou-second');
    expect(controller.status, AiConnectionStatus.connected);
    expect(await controller.deleteProfile(), true);
    expect(controller.profiles, hasLength(1));
    expect(controller.selectedProfileId, originalId);
    expect(store.stored!.profiles.single.apiKey, 'ou-first');
    expect(await controller.deleteProfile(), false);
  });

  test('Status is isolated, resets on edit, and never claims connected after restart',
      () async {
    await controller.initialize();
    await controller.save(defaultAiBaseUrl, 'model-a', 'ou-one');
    provider.gate = Completer<String>();
    final testing = controller.testConnection();
    expect(controller.status, AiConnectionStatus.testing);
    expect(controller.testPassed, isNull);
    expect(controller.statusError, isNull);
    provider.gate!.complete('Connexion OK');
    await testing;
    expect(controller.status, AiConnectionStatus.connected);

    final originalId = controller.selectedProfileId;
    await controller.createProfile('Autre compte');
    await controller.save(defaultAiBaseUrl, 'model-a', 'ou-two');
    provider.gate = null;
    provider.offline = true;
    await controller.testConnection();
    expect(controller.status, AiConnectionStatus.invalid);
    expect(controller.statusError, contains('Clé API refusée'));
    expect(controller.testReply, isNull);
    expect(await controller.selectProfile(originalId), true);
    expect(controller.status, AiConnectionStatus.connected);
    expect(controller.statusError, isNull);
    expect(await controller.save(defaultAiBaseUrl, 'model-a', ''), true);
    expect(controller.status, AiConnectionStatus.connected,
        reason: 'Saving identical values must not hide a valid result');
    expect(await controller.save(defaultAiBaseUrl, 'model-b', ''), true);
    expect(controller.status, AiConnectionStatus.untested);

    final restarted = AiConnectionController(store: store, provider: provider);
    await restarted.initialize();
    expect(restarted.status, AiConnectionStatus.untested);
    expect(restarted.profiles, hasLength(2));
    expect(restarted.selectedProfileId, originalId);
    restarted.dispose();
  });

  test('No key and offline test produce a readable per-profile error', () async {
    await controller.initialize();
    await controller.testConnection();
    expect(controller.testPassed, false);
    expect(controller.statusError, contains('clé API'));
    expect(provider.calls, 0);
    await controller.save(defaultAiBaseUrl, defaultAiModel, 'ou-my-key');
    provider.offline = true;
    await controller.testConnection();
    expect(controller.testPassed, false);
    expect(controller.statusError, contains('Clé API refusée'));
    expect(controller.message, isNull);
  });

  test('Invalid URL never overwrites a saved profile or leaks secret', () async {
    await controller.initialize();
    expect(await controller.save(defaultAiBaseUrl, defaultAiModel, 'ou-my-key'),
        true);
    expect(await controller.save('http://insecure.example/v1', defaultAiModel, 'bad'),
        false);
    expect(store.stored!.profiles.single.apiKey, 'ou-my-key');
    expect(controller.message, contains('HTTPS'));
    expect(controller.message, isNot(contains('ou-my-key')));
  });

  test('Persisted selected profile and names survive restart', () async {
    await controller.initialize();
    await controller.createProfile('Mon autre API');
    await controller.save(defaultAiBaseUrl, 'model-b', 'ou-two');
    final selected = controller.selectedProfileId;
    final fresh = AiConnectionController(store: store, provider: provider);
    await fresh.initialize();
    expect(fresh.selectedProfileId, selected);
    expect(fresh.profiles.map((p) => p.name), ['OpenUncensored', 'Mon autre API']);
    expect(fresh.selectedProfile.apiKey, 'ou-two');
    fresh.dispose();
  });

  test('Storage failure never corrupts active profile selection', () async {
    await controller.initialize();
    await controller.createProfile('Autre');
    final selected = controller.selectedProfileId;
    store.failWrite = true;
    expect(await controller.selectProfile('default'), false);
    expect(controller.selectedProfileId, selected);
    expect(controller.message, contains('Impossible'));
    expect(await controller.deleteProfile(), false);
    expect(controller.profiles, hasLength(2));
    expect(controller.message, isNot(contains('Sensitive')));
  });

  test('Empty and too long profile names are rejected', () async {
    await controller.initialize();
    expect(await controller.createProfile('   '), false);
    expect(await controller.createProfile('x' * 61), false);
    expect(controller.profiles, hasLength(1));
  });

  test('Switching to ChatGPT never retains the CustomAI model', () async {
    final account = FakeChatGptAccount();
    final chat = AiConnectionController(
      store: store, provider: provider,
      chatGpt: account, chatGptProvider: provider,
    );
    addTearDown(chat.dispose);
    await chat.initialize();
    expect(await chat.save(defaultAiBaseUrl,
        'deepseek-v4.1-flash-1017-uncensored', 'test-key'), true);
    expect(await chat.setProviderKind(AiProviderKind.chatGpt), true);
    expect(chat.model, isEmpty);
    expect(store.stored!.profiles.single.model, isEmpty);
    await chat.connectChatGpt();
    expect(chat.model, 'gpt-test');
    expect(chat.models.map((item) => item.id),
        ['gpt-test', 'gpt-secondary']);
    expect(await chat.selectChatGptModel(
        'deepseek-v4.1-flash-1017-uncensored'), false);
    expect(chat.model, 'gpt-test');
    expect(await chat.selectChatGptModel('gpt-secondary'), true);
    expect(chat.model, 'gpt-secondary');
    expect(chat.models, hasLength(2),
        reason: 'Selecting a model must not clear the catalogue.');
    final connection = await chat.connectionForProfile(chat.selectedProfileId);
    expect(connection.configuration.model, 'gpt-secondary');
    expect(connection.configuration.apiKey, 'test-access');
  });

  test('Legacy ChatGPT profile with a foreign model is repaired on catalogue load',
      () async {
    final account = FakeChatGptAccount();
    store.stored = const AiProfilesState(
      selectedId: 'legacy',
      profiles: [
        AiProfile(
          id: 'legacy', name: 'ChatGPT', baseUrl: defaultAiBaseUrl,
          model: 'deepseek-v4.1-flash-1017-uncensored', apiKey: '',
          kind: AiProviderKind.chatGpt,
        ),
      ],
    );
    final chat = AiConnectionController(
      store: store, provider: provider,
      chatGpt: account, chatGptProvider: provider,
    );
    addTearDown(chat.dispose);
    await chat.initialize();
    await expectLater(
      chat.connectionForProfile('legacy'),
      throwsA(isA<AiProviderException>().having(
        (error) => error.userMessage, 'message',
        contains('incompatible'),
      )),
    );
    await chat.loadModels();
    expect(chat.model, 'gpt-test');
    expect(store.stored!.profiles.single.model, 'gpt-test');
    expect(await chat.selectChatGptModel('not-in-account'), false);
    expect(chat.model, 'gpt-test');
  });

}
