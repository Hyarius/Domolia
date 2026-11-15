import 'package:domolia/ai/ai_task_routing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('All three task defaults are independent and survive restart', () async {
    final first = AiTaskRouting();
    addTearDown(first.dispose);
    await first.initialize();
    for (final task in AiNarrativeTask.values) {
      expect(first.profileFor(task), isNull);
    }
    await first.setProfile(AiNarrativeTask.narrator, 'writer');
    await first.setProfile(AiNarrativeTask.jsonifier, 'formatter');
    await first.setProfile(AiNarrativeTask.optimizer, 'optimizer');
    expect(first.profileFor(AiNarrativeTask.narrator), 'writer');
    expect(first.profileFor(AiNarrativeTask.jsonifier), 'formatter');
    expect(first.profileFor(AiNarrativeTask.optimizer), 'optimizer');

    final reloaded = AiTaskRouting();
    addTearDown(reloaded.dispose);
    await reloaded.initialize();
    expect(reloaded.profileFor(AiNarrativeTask.narrator), 'writer');
    expect(reloaded.profileFor(AiNarrativeTask.jsonifier), 'formatter');
    expect(reloaded.profileFor(AiNarrativeTask.optimizer), 'optimizer');
    await reloaded.setProfile(AiNarrativeTask.optimizer, null);
    expect(reloaded.profileFor(AiNarrativeTask.optimizer), isNull);
    expect(reloaded.profileFor(AiNarrativeTask.jsonifier), 'formatter');

    final restarted = AiTaskRouting();
    addTearDown(restarted.dispose);
    await restarted.initialize();
    expect(restarted.profileFor(AiNarrativeTask.optimizer), isNull);
  });

  test('Legacy settings have no mandatory optimizer request', () async {
    SharedPreferences.setMockInitialValues({
      'aiTaskNarratorProfileId': 'writer',
    });
    final routing = AiTaskRouting();
    addTearDown(routing.dispose);
    await routing.initialize();
    expect(routing.profileFor(AiNarrativeTask.narrator), 'writer');
    expect(routing.profileFor(AiNarrativeTask.optimizer), isNull);
    expect(routing.profileFor(AiNarrativeTask.jsonifier), isNull);
  });
  test('Generation budgets and reasoning settings survive app restart', () async {
    final first = AiTaskRouting();
    addTearDown(first.dispose);
    await first.initialize();
    expect(first.generationFor(AiNarrativeTask.narrator).maxOutputTokens, 8192);
    expect(first.generationFor(AiNarrativeTask.jsonifier).maxOutputTokens, 4096);
    await first.setGeneration(AiNarrativeTask.narrator,
      const AiTaskGenerationSettings(
        maxOutputTokens: 16384, reasoningEffort: 'medium',
      ));
    await first.setGeneration(AiNarrativeTask.jsonifier,
      const AiTaskGenerationSettings(
        maxOutputTokens: 8192, reasoningEffort: 'none',
      ));
    final next = AiTaskRouting();
    addTearDown(next.dispose);
    await next.initialize();
    expect(next.generationFor(AiNarrativeTask.narrator).maxOutputTokens, 16384);
    expect(next.generationFor(AiNarrativeTask.narrator).reasoningEffort, 'medium');
    expect(next.generationFor(AiNarrativeTask.jsonifier).maxOutputTokens, 8192);
    expect(next.generationFor(AiNarrativeTask.jsonifier).reasoningEffort, 'none');
    expect(next.generationFor(AiNarrativeTask.optimizer).maxOutputTokens, 4096);
  });

  test('Invalid persisted generation settings revert to defaults', () async {
    SharedPreferences.setMockInitialValues({
      'aiTaskGeneration-jsonifier': '{"maxOutputTokens":-1,"reasoningEffort":"none"}',
      'aiTaskGeneration-narrator': 'not-json',
    });
    final routing = AiTaskRouting();
    addTearDown(routing.dispose);
    await routing.initialize();
    expect(routing.generationFor(AiNarrativeTask.narrator).maxOutputTokens, 8192);
    expect(routing.generationFor(AiNarrativeTask.jsonifier).maxOutputTokens, 4096);
    expect(routing.initialized, true);
    await expectLater(routing.setGeneration(AiNarrativeTask.jsonifier,
      const AiTaskGenerationSettings(
        maxOutputTokens: 50000)), throwsFormatException);
    expect(routing.generationFor(AiNarrativeTask.jsonifier).maxOutputTokens, 4096);
  });

}
