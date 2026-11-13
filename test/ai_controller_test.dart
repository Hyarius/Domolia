import 'package:domolia/ai/ai_controller.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:flutter_test/flutter_test.dart';

class InMemoryEncryptedStore implements AiConfigurationStore {
  AiConfiguration? stored;
  @override
  Future<AiConfiguration?> read() async => stored;
  @override
  Future<void> write(AiConfiguration configuration) async {
    stored = configuration;
  }
}

class FakeChatProvider implements AiChatProvider {
  bool offline = false;
  int calls = 0;
  @override
  Future<List<AiModel>> listModels(AiConfiguration c) async {
    expect(c.apiKey, 'ou-my-key');
    return [const AiModel('model-a'), const AiModel('model-b')];
  }

  @override
  Future<String> complete(
    AiConfiguration configuration, {
    required List<AiMessage> messages,
    int maxTokens = 64,
  }) async {
    calls++;
    if (offline) throw const AiProviderException('Fournisseur indisponible.');
    expect(configuration.apiKey, 'ou-my-key');
    expect(maxTokens, 64);
    expect(messages.single.role, 'user');
    return 'Connexion établie, bonjour !';
  }
}

void main() {
  test('Secure repository contract survives a controller restart', () async {
    final store = InMemoryEncryptedStore();
    final provider = FakeChatProvider();
    final a = AiConnectionController(store: store, provider: provider);
    await a.initialize();
    expect(a.hasKey, false);
    expect(await a.save(defaultAiBaseUrl, 'model-a', 'ou-my-key'), true);
    expect(a.hasKey, true);
    a.dispose();

    final b = AiConnectionController(store: store, provider: provider);
    await b.initialize();
    expect(b.hasKey, true);
    expect(b.baseUrl, defaultAiBaseUrl);
    expect(b.model, 'model-a');
    expect(await b.save(defaultAiBaseUrl, 'model-b', ''), true);
    expect((await store.read())!.apiKey, 'ou-my-key');
    expect((await store.read())!.model, 'model-b');
    await b.loadModels();
    expect(b.models.map((m) => m.id), ['model-a', 'model-b']);
    await b.testConnection();
    expect(b.testPassed, true);
    expect(b.testReply, contains('bonjour'));
    expect(provider.calls, 1);
    await b.removeKey();
    expect(b.hasKey, false);
    expect((await store.read())!.apiKey, '');
    b.dispose();
  });

  test('Absent key and offline provider display safe errors without crash', () async {
    final store = InMemoryEncryptedStore();
    final provider = FakeChatProvider();
    final c = AiConnectionController(store: store, provider: provider);
    await c.initialize();
    await c.testConnection();
    expect(c.testPassed, false);
    expect(c.message, contains('clé API'));
    expect(provider.calls, 0);

    expect(await c.save(defaultAiBaseUrl, defaultAiModel, 'ou-my-key'), true);
    provider.offline = true;
    await c.testConnection();
    expect(c.testPassed, false);
    expect(c.message, 'Fournisseur indisponible.');
    c.dispose();
  });

  test('Invalid HTTPS URL is rejected without replacing saved credentials', () async {
    final store = InMemoryEncryptedStore();
    final c = AiConnectionController(store: store, provider: FakeChatProvider());
    expect(await c.save(defaultAiBaseUrl, defaultAiModel, 'ou-my-key'), true);
    expect(await c.save('http://insecure.example/v1', defaultAiModel, 'bad'), false);
    expect((await store.read())!.apiKey, 'ou-my-key');
    expect(c.message, contains('HTTPS'));
    c.dispose();
  });
}
