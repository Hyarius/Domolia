import 'package:domolia/ai/ai_controller.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/chatgpt_auth.dart';
import 'package:flutter_test/flutter_test.dart';

class ProfileStoreFake implements AiProfileStore {
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

class ProviderFake implements AiChatProvider {
  @override
  Future<List<AiModel>> listModels(AiConfiguration value) async =>
      [const AiModel('custom-model')];
  @override
  Future<String> complete(
    AiConfiguration value, {
    required List<AiMessage> messages,
    int maxTokens = 64,
  }) async => 'Réponse simulée';
}

class ChatGptAccountFake implements ChatGptAccountService {
  final accounts = <String, ChatGptSession>{};
  int signInCalls = 0;
  @override
  Future<ChatGptSession?> session(String id) async => accounts[id];

  @override
  Future<ChatGptSession> signIn(String id) async {
    signInCalls++;
    final saved = ChatGptSession(
      clientId: 'oaiapp_mock',
      subject: 'user-one',
      email: 'fake@example.com',
      idToken: 'id-test',
      accessToken: 'access-mock',
      refreshToken: 'refresh-mock',
      scopes: {'chatgpt.tokens.use.direct', 'resource.invoke'},
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    accounts[id] = saved;
    return saved;
  }

  @override
  Future<String> accessToken(String id) async {
    if (!accounts.containsKey(id)) {
      throw const AiProviderException('Connexion ChatGPT manquante.');
    }
    return accounts[id]!.accessToken;
  }

  @override
  Future<List<AiModel>> listModels(String id) async =>
      [const AiModel('gpt-mock')];

  @override
  Future<void> disconnect(String id) async { accounts.remove(id); }

  @override
  Future<void> delete(String id) async { accounts.remove(id); }
}

void main() {
  late ProfileStoreFake storage;
  late ProviderFake custom;
  late ProviderFake chatGptProvider;
  late ChatGptAccountFake auth;
  late AiConnectionController controller;

  setUp(() {
    storage = ProfileStoreFake();
    custom = ProviderFake();
    chatGptProvider = ProviderFake();
    auth = ChatGptAccountFake();
    controller = AiConnectionController(
      store: storage,
      provider: custom,
      chatGpt: auth,
      chatGptProvider: chatGptProvider,
    );
  });
  tearDown(() => controller.dispose());

  test('Existing named configuration is CustomAI by default', () async {
    await controller.initialize();
    expect(controller.profiles.single.kind, AiProviderKind.customAi);
    expect(controller.selectedProfile.name, 'OpenUncensored');
    await controller.save(defaultAiBaseUrl, 'custom-model', 'test-key');
    final binding = await controller.connectionForProfile(
      controller.selectedProfileId,
    );
    expect(identical(binding.provider, custom), true);
    expect(binding.configuration.apiKey, 'test-key');
  });

  test('A named configuration may be ChatGPT without a second global picker', () async {
    await controller.initialize();
    final customId = controller.selectedProfileId;
    await controller.save(defaultAiBaseUrl, 'custom-model', 'custom-key');
    await controller.createProfile('ChatGPT familial');
    final chatGptId = controller.selectedProfileId;
    expect(await controller.setProviderKind(AiProviderKind.chatGpt), true);
    expect(controller.selectedProfile.name, 'ChatGPT familial');
    expect(controller.selectedKind, AiProviderKind.chatGpt);
    expect(storage.state!.profiles.first.kind, AiProviderKind.customAi);
    expect(storage.state!.profiles.last.kind, AiProviderKind.chatGpt);

    await controller.connectChatGpt();
    expect(auth.signInCalls, 1);
    expect(controller.status, AiConnectionStatus.connected);
    expect(controller.model, 'gpt-mock');
    final resolved = await controller.connectionForProfile(chatGptId);
    expect(identical(resolved.provider, chatGptProvider), true);
    expect(resolved.configuration.baseUrl, 'https://api.openai.com/v1');
    expect(resolved.configuration.apiKey, 'access-mock');

    await controller.selectProfile(customId);
    final original = await controller.connectionForProfile(customId);
    expect(identical(original.provider, custom), true);
    expect(original.configuration.apiKey, 'custom-key');

    await controller.selectProfile(chatGptId);
    await controller.disconnectChatGpt();
    expect(auth.accounts.containsKey(chatGptId), false);
    expect(controller.selectedProfile.name, 'ChatGPT familial');
  });

  test('Deleted ChatGPT named configuration erases only its own OAuth session',
      () async {
    await controller.initialize();
    await controller.createProfile('Compte GPT A');
    await controller.setProviderKind(AiProviderKind.chatGpt);
    await controller.connectChatGpt();
    final removedId = controller.selectedProfileId;
    expect(auth.accounts.containsKey(removedId), true);
    await controller.deleteProfile();
    expect(auth.accounts.containsKey(removedId), false);
    expect(controller.profiles.single.kind, AiProviderKind.customAi);
  });

  test('Persisted provider kind is preserved after a controller restart',
      () async {
    await controller.initialize();
    await controller.createProfile('GPT persistant');
    await controller.setProviderKind(AiProviderKind.chatGpt);
    final id = controller.selectedProfileId;
    final reloaded = AiConnectionController(
      store: storage, provider: custom,
      chatGpt: auth, chatGptProvider: chatGptProvider,
    );
    await reloaded.initialize();
    expect(reloaded.selectedProfileId, id);
    expect(reloaded.selectedKind, AiProviderKind.chatGpt);
    expect(reloaded.selectedProfile.name, 'GPT persistant');
    reloaded.dispose();
  });
}
