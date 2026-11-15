import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/web_ai_profile_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Web profile metadata persists but no API key is serialized', () async {
    final first = WebAiProfileStore();
    await first.write(const AiProfilesState(
      selectedId: 'sample',
      profiles: [
        AiProfile(
          id: 'sample',
          name: 'Mon IA',
          baseUrl: 'https://example.com/v1',
          model: 'test-model',
          apiKey: 'SECRET_DO_NOT_STORE',
          nsfwCompatibility: AiNsfwCompatibility.supported,
        ),
      ],
    ));

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(WebAiProfileStore.storageKey);
    expect(saved, isNotNull);
    expect(saved, contains('Mon IA'));
    expect(saved, isNot(contains('SECRET_DO_NOT_STORE')));
    expect(saved, isNot(contains('apiKey')));

    final inSession = await first.read();
    expect(inSession!.profiles.single.apiKey, 'SECRET_DO_NOT_STORE');

    // Simulates a browser reload: the second store has no memory-only secret.
    final afterReload = await WebAiProfileStore().read();
    expect(afterReload!.profiles.single.apiKey, isEmpty);
    expect(afterReload.profiles.single.model, 'test-model');
    expect(afterReload.profiles.single.name, 'Mon IA');
    expect(afterReload.profiles.single.nsfwCompatibility,
        AiNsfwCompatibility.supported);
  });

  test('Web profile storage rejects colliding IDs before any write', () async {
    final storage = WebAiProfileStore();
    const duplicate = AiProfile(
      id: 'duplicate', name: 'Duplicate', baseUrl: 'https://example.com',
      model: 'test-model', apiKey: '',
    );
    await expectLater(
      storage.write(const AiProfilesState(
        selectedId: 'duplicate',
        profiles: [duplicate, duplicate],
      )),
      throwsFormatException,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(WebAiProfileStore.storageKey), isNull);
  });
}
