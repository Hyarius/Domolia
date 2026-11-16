import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

enum LocalGpuMode { automatic, cpuOnly }

/// User preferences for on-device inference. A value of zero means use all
/// logical processors exposed by Android. Android remains free to schedule
/// threads and thermal throttling can make fewer threads faster.
class LocalInferenceOptions {
  const LocalInferenceOptions({
    this.threads = 0,
    this.gpuMode = LocalGpuMode.automatic,
  });

  static const threadsKey = 'local-ai-cpu-threads';
  static const gpuModeKey = 'local-ai-gpu-mode';
  final int threads;
  final LocalGpuMode gpuMode;

  int effectiveThreads([int? available]) {
    final detected = (available ?? Platform.numberOfProcessors);
    final cores = detected < 1 ? 1 : detected;
    if (threads <= 0) return cores;
    return threads > cores ? cores : threads;
  }

  static Future<LocalInferenceOptions> load() async {
    final prefs = await SharedPreferences.getInstance();
    final gpuName = prefs.getString(gpuModeKey);
    return LocalInferenceOptions(
      threads: prefs.getInt(threadsKey) ?? 0,
      gpuMode: gpuName == LocalGpuMode.cpuOnly.name
          ? LocalGpuMode.cpuOnly : LocalGpuMode.automatic,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setInt(threadsKey, threads) ||
        !await prefs.setString(gpuModeKey, gpuMode.name)) {
      throw StateError('Impossible de sauvegarder les paramètres locaux.');
    }
  }

  LocalInferenceOptions copyWith({int? threads, LocalGpuMode? gpuMode}) =>
      LocalInferenceOptions(
        threads: threads ?? this.threads,
        gpuMode: gpuMode ?? this.gpuMode,
      );
}
