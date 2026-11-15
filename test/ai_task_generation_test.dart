import 'package:domolia/ai/ai_task_generation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Recommended budgets differ for narrative and mechanical tasks', () {
    expect(AiTaskGenerationSettings.defaults(AiNarrativeTask.narrator)
        .maxOutputTokens, 8192);
    expect(AiTaskGenerationSettings.defaults(AiNarrativeTask.jsonifier)
        .maxOutputTokens, 4096);
    expect(AiTaskGenerationSettings.defaults(AiNarrativeTask.optimizer)
        .maxOutputTokens, 4096);
  });

  test('Luna presets allocate reasoning according to the task', () {
    for (final task in AiNarrativeTask.values) {
      final settings = AiTaskGenerationSettings.defaults(task);
      expect(settings.effectiveEffort(task, 'gpt-5.6-luna'),
        task == AiNarrativeTask.jsonifier ? 'none' : 'low');
      expect(settings.effectiveEffort(task, 'unknown-custom-model'), isNull);
      expect(settings.effectiveEffort(task, 'gpt-6-astra'), isNull);
    }
  });

  test('Explicit reasoning overrides auto presets and provider opt-out', () {
    const low = AiTaskGenerationSettings(
      maxOutputTokens: 8192, reasoningEffort: 'high');
    expect(low.effectiveEffort(AiNarrativeTask.jsonifier, 'gpt-5.6-luna'),
      'high');
    const skipped = AiTaskGenerationSettings(
      maxOutputTokens: 4096, reasoningEffort: 'provider');
    expect(skipped.effectiveEffort(
      AiNarrativeTask.narrator, 'gpt-5.6-luna'), isNull);
  });

  test('Settings and individual field overrides validate and serialize', () {
    const app = AiTaskGenerationSettings(
      maxOutputTokens: 8192, reasoningEffort: 'low');
    final read = AiTaskGenerationSettings.fromJson(app.toJson());
    expect(read.maxOutputTokens, 8192);
    expect(read.reasoningEffort, 'low');
    const override = AiTaskGenerationOverride(maxOutputTokens: 16384);
    final merged = app.merged(override);
    expect(merged.maxOutputTokens, 16384);
    expect(merged.reasoningEffort, 'low');
    final entries = <AiNarrativeTask, AiTaskGenerationOverride>{
      AiNarrativeTask.narrator: override,
      AiNarrativeTask.jsonifier:
          const AiTaskGenerationOverride(reasoningEffort: 'none'),
    };
    final restored = AiTaskGenerationOverride.decode(
        AiTaskGenerationOverride.encode(entries));
    expect(restored[AiNarrativeTask.narrator]!.maxOutputTokens, 16384);
    expect(restored[AiNarrativeTask.narrator]!.reasoningEffort, isNull);
    expect(restored[AiNarrativeTask.jsonifier]!.reasoningEffort, 'none');
  });

  test('Removing one override does not clear the other fields', () {
    const original = AiTaskGenerationOverride(
      maxOutputTokens: 32768, reasoningEffort: 'medium');
    final cleared = original.copyWith(clearMaxOutputTokens: true);
    expect(cleared.maxOutputTokens, isNull);
    expect(cleared.reasoningEffort, 'medium');
    expect(cleared.copyWith(clearReasoningEffort: true).isEmpty, true);
  });

  test('Invalid or corrupted settings fail closed before HTTP or SQLite', () {
    expect(() => const AiTaskGenerationSettings(
      maxOutputTokens: 100).validate(), throwsFormatException);
    expect(() => const AiTaskGenerationSettings(
      maxOutputTokens: 50000).validate(), throwsFormatException);
    expect(() => const AiTaskGenerationSettings(
      maxOutputTokens: 8192, reasoningEffort: 'unsupported').validate(),
      throwsFormatException);
    expect(() => AiTaskGenerationSettings.fromJson({
      'maxOutputTokens': '32768', 'reasoningEffort': 'none',
    }), throwsFormatException);
    expect(() => AiTaskGenerationOverride.decode(
      '{"unknown":{"maxOutputTokens":4096}}'), throwsFormatException);
    expect(() => AiTaskGenerationOverride.decode(
      '{"jsonifier":{"reasoningEffort":"invalid"}}'),
      throwsFormatException);
  });
}
