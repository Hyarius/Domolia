// ignore_for_file: prefer_interpolation_to_compose_strings, curly_braces_in_flow_control_structures
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/illustration/image_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('App defaults and Party overrides persist separately', () async {
    final prefs=ImagePreferences();
    await prefs.initialize();
    expect((await prefs.forSession('s1')).model,isEmpty);
    const saved=ImageGenerationOptions(
        profileId:'ou', directorProfileId:'gpt',
        model:'visual');
    await prefs.saveApplication(saved);
    await prefs.saveParty('s1', saved.copyWith(model:'gpt-image-2'));
    final restarted=ImagePreferences();
    await restarted.initialize();
    expect((await restarted.forSession('s1')).model,'gpt-image-2');
    expect((await restarted.forSession('s2')).model,'visual');
    await restarted.saveParty('s1', null);
    expect((await restarted.forSession('s1')).model,'visual');
    prefs.dispose();
    restarted.dispose();
  });

  test('Default settings resolve a funded OpenUncensored profile automatically',
      () {
    const options = ImageGenerationOptions();
    final resolved = options.resolveProfiles(const [
      AiProfile(id:'default', name:'OpenUncensored',
          baseUrl:defaultAiBaseUrl, model:defaultAiModel, apiKey:'ou-key'),
      AiProfile(id:'external', name:'Other',
          baseUrl:'https://api.openai.com/v1',
          model:'gpt-image-2', apiKey:'openai-key'),
    ]);
    expect(resolved.profileId, 'default');
    expect(resolved.directorProfileId, 'default');
    expect(resolved.model, isEmpty);
    expect(options.profileId, isEmpty); // No settings are silently persisted.
    expect(options.toJson()['profileId'], isEmpty);
    final override = options.copyWith(profileId:'external',
        directorProfileId:'default', model:'gpt-image-2');
    expect(override.resolveProfiles(const [
      AiProfile(id:'default', name:'OpenUncensored',
        baseUrl:defaultAiBaseUrl, model:defaultAiModel, apiKey:'ou-key'),
      AiProfile(id:'external', name:'Other',
        baseUrl:'https://api.openai.com/v1',
        model:'gpt-image-2', apiKey:'openai-key'),
    ]).profileId, 'external');
  });

  test('An image-only OpenAI key uses ChatGPT for visual direction',
      () {
    const profiles = [
      AiProfile(
        id: 'openai-image', name: 'OpenAI images',
        kind: AiProviderKind.customAi,
        baseUrl: 'https://api.openai.com/v1', model: '',
        apiKey: 'sk-image-only',
      ),
      AiProfile(
        id: 'chatgpt-narrator', name: 'ChatGPT',
        kind: AiProviderKind.chatGpt,
        baseUrl: 'https://api.openai.com/v1', model: 'gpt-test',
        apiKey: '',
      ),
    ];
    const options = ImageGenerationOptions(profileId: 'openai-image');
    final resolved = options.resolveProfiles(profiles);
    expect(resolved.profileId, 'openai-image');
    expect(resolved.directorProfileId, 'chatgpt-narrator');
    expect(canDirectImages(profiles.first), false);
    expect(canDirectImages(profiles.last), true);

    final invalidDirector = const ImageGenerationOptions(
      profileId: 'openai-image',
      directorProfileId: 'openai-image',
    ).resolveProfiles(profiles);
    expect(invalidDirector.directorProfileId, 'chatgpt-narrator');
  });

  test('An explicit OpenAI profile without a key cannot fall back to OU',
      () {
    final profiles = const [
      AiProfile(
        id: 'openai-images', name: 'ChatGPT - Image',
        kind: AiProviderKind.customAi,
        baseUrl: 'https://api.openai.com/v1', model: '', apiKey: '',
      ),
      AiProfile(
        id: 'ou', name: 'OpenUncensored',
        kind: AiProviderKind.customAi,
        baseUrl: defaultAiBaseUrl, model: defaultAiModel,
        apiKey: 'ou-key',
      ),
    ];
    const options = ImageGenerationOptions(
        profileId: 'openai-images', directorProfileId: 'ou');
    final resolved = options.resolveProfiles(profiles);
    expect(resolved.profileId, 'openai-images');
    expect(resolved.directorProfileId, 'ou');
    expect(options.profileId, 'openai-images');
    // An unknown explicitly requested profile is also not silently replaced.
    expect(const ImageGenerationOptions(
      profileId: 'removed-profile',
    ).resolveProfiles(profiles).profileId, 'removed-profile');
    // Auto mode still chooses the funded OU profile for backwards compatibility.
    expect(const ImageGenerationOptions()
        .resolveProfiles(profiles).profileId, 'ou');
  });

  test('Only API configuration is persisted, legacy art keys ignored', () {
    final settings = ImageGenerationOptions.fromJson({
      'profileId':'image',
      'directorProfileId':'director',
      'model':'visual',
      'style':'old style',
      'size':'512x512',
      'count':4,
      'quality':'low',
    });
    expect(settings.model,'visual');
    expect(settings.toJson().keys,
      containsAllInOrder(['profileId','directorProfileId','model']));
    expect(settings.toJson().containsKey('style'),isFalse);
    expect(()=>ImageGenerationOptions(
      model:'x' * 120).validate(),throwsFormatException);
  });
}
