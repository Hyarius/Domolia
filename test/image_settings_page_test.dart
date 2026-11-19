import 'dart:async';

import 'package:domolia/ai/ai_controller.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/illustration/image_preferences.dart';
import 'package:domolia/illustration/image_providers.dart';
import 'package:domolia/illustration/image_settings_page.dart';
import 'package:domolia/theme/domolia_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ProfilesStore implements AiProfileStore {
  _ProfilesStore(this.state);
  AiProfilesState state;

  @override
  Future<AiProfilesState?> read() async => state;

  @override
  Future<void> write(AiProfilesState value) async => state = value;
}

class _Catalogue implements ImageGenerationProvider {
  _Catalogue(this.id, this.result);
  @override
  final String id;
  final Future<List<ImageModelCapability>> result;
  @override
  Future<List<ImageModelCapability>> listModels(String apiKey) => result;
  @override
  Future<ImageGenerationResult> generate(ImageGenerationRequest request,
      {required String apiKey}) {
    throw UnimplementedError('This test never calls the billable image API.');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Changing from OU to OpenAI does not reuse the stale OU catalogue',
      (tester) async {
    final slowOu = Completer<List<ImageModelCapability>>();
    final store = _ProfilesStore(const AiProfilesState(
      selectedId: 'ou',
      profiles: [
        AiProfile(
          id: 'ou', name: 'OpenUncensored',
          baseUrl: defaultAiBaseUrl, model: defaultAiModel,
          apiKey: 'ou-key',
        ),
        AiProfile(
          id: 'openai', name: 'ChatGPT - Image',
          baseUrl: 'https://api.openai.com/v1', model: '',
          apiKey: 'sk-test',
        ),
      ],
    ));
    final controller = AiConnectionController(
      store: store, provider: OpenAiCompatibleChatProvider());
    final preferences = ImagePreferences();
    addTearDown(controller.dispose);
    addTearDown(preferences.dispose);
    await controller.initialize();

    tester.view.physicalSize = const Size(480, 1280);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: ImageSettingsPage(
        ai: controller,
        preferences: preferences,
        onBack: () {},
        imageProviderFactory: (profile) =>
            profile.id == 'ou'
                ? _Catalogue('openuncensored', slowOu.future)
                : _Catalogue('openai', Future.value(const [
                    ImageModelCapability(
                      id: 'gpt-image-2.6-flare',
                      sizes: ['1024x1024'],
                    ),
                  ])),
      )),
    ));
    // The first catalogue deliberately never completes until the profile
    // has switched. A loading spinner makes pumpAndSettle inappropriate.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Catalogue graphique : OpenUncensored'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('imageProviderProfile-')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ChatGPT - Image').last);
    await tester.pumpAndSettle();

    expect(find.text('Catalogue graphique : OpenAI'), findsOneWidget);
    expect(find.byKey(const ValueKey('imageModel-openai::1')), findsOneWidget);

    // The previous request returns AFTER OpenAI has already been selected.
    slowOu.complete(const [
      ImageModelCapability(id: 'z-image-turbo', sizes: ['1024x1024']),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Catalogue graphique : OpenAI'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('imageModel-openai::1')));
    await tester.pumpAndSettle();
    expect(find.text('gpt-image-2.6-flare'), findsWidgets);
    expect(find.text('z-image-turbo'), findsNothing);
    await tester.tap(find.text('gpt-image-2.6-flare').last);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('imageSettingsSave')));
    await tester.tap(find.byKey(const ValueKey('imageSettingsSave')));
    await tester.pumpAndSettle();
    expect(preferences.application.profileId, 'openai');
    expect(preferences.application.model, 'gpt-image-2.6-flare');
    expect(tester.takeException(), isNull);
  });
}
