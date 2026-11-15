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
}
