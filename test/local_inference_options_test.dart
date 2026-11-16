import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:domolia/ai/local_inference_options.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Default uses all available logical CPUs and automatic Vulkan', () async {
    final options = await LocalInferenceOptions.load();
    expect(options.threads, 0);
    expect(options.gpuMode, LocalGpuMode.automatic);
    expect(options.effectiveThreads(8), 8);
    expect(options.effectiveThreads(1), 1);
    expect(options.effectiveThreads(0), 1);
  });

  test('Manual thread selection never exceeds the detected CPU count', () {
    const options = LocalInferenceOptions(threads: 4);
    expect(options.effectiveThreads(8), 4);
    expect(options.effectiveThreads(2), 2);
    expect(const LocalInferenceOptions(threads: -2).effectiveThreads(8), 8);
  });

  test('CPU-only fallback and manual threads persist', () async {
    const selected = LocalInferenceOptions(
      threads: 2, gpuMode: LocalGpuMode.cpuOnly);
    await selected.save();
    final restored = await LocalInferenceOptions.load();
    expect(restored.threads, 2);
    expect(restored.gpuMode, LocalGpuMode.cpuOnly);
    expect(restored.effectiveThreads(8), 2);
  });

  test('Unknown saved Vulkan preference is handled conservatively', () async {
    SharedPreferences.setMockInitialValues({
      LocalInferenceOptions.gpuModeKey: 'unknown',
      LocalInferenceOptions.threadsKey: 0,
    });
    final options = await LocalInferenceOptions.load();
    expect(options.gpuMode, LocalGpuMode.automatic);
    expect(options.effectiveThreads(8), 8);
  });
}
