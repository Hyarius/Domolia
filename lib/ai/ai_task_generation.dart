import 'dart:convert';

/// Controls for the narrative AI calls, independent from credentials and models.
enum AiNarrativeTask {
  narrator, jsonifier, optimizer, memory;

  /// Legacy task keys remain readable; only these tasks are configurable
  /// in the current narrative UI.
  static const active = [narrator, memory];
}

/// A task uses this configuration unless a Party overrides an individual field.
class AiTaskGenerationSettings {
  const AiTaskGenerationSettings({
    required this.maxOutputTokens,
    this.reasoningEffort = 'auto',
  });

  static const minTokens = 128;
  static const maxTokens = 32768;
  static const tokenChoices = <int>[
    512, 1024, 2400, 4096, 8192, 16384, 32768,
  ];
  /// "auto" uses the Luna preset; "provider" omits the API field.
  static const reasoningChoices = <String>[
    'auto', 'provider', 'none', 'low', 'medium', 'high', 'xhigh', 'max',
  ];

  final int maxOutputTokens;
  final String reasoningEffort;

  static AiTaskGenerationSettings defaults(AiNarrativeTask task) =>
      AiTaskGenerationSettings(maxOutputTokens: switch (task) {
        AiNarrativeTask.narrator => 8192,
        AiNarrativeTask.jsonifier => 4096,
        AiNarrativeTask.optimizer => 4096,
        AiNarrativeTask.memory => 1024,
      });

  void validate() {
    if (maxOutputTokens < minTokens || maxOutputTokens > maxTokens ||
        !reasoningChoices.contains(reasoningEffort)) {
      throw const FormatException('Paramètres de génération IA invalides.');
    }
  }

  Map<String, dynamic> toJson() => {
    'maxOutputTokens': maxOutputTokens,
    'reasoningEffort': reasoningEffort,
  };

  factory AiTaskGenerationSettings.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 2 ||
        value['maxOutputTokens'] is! int ||
        value['reasoningEffort'] is! String) {
      throw const FormatException('Paramètres de génération IA invalides.');
    }
    final result = AiTaskGenerationSettings(
      maxOutputTokens: value['maxOutputTokens'] as int,
      reasoningEffort: value['reasoningEffort'] as String,
    );
    result.validate();
    return result;
  }

  /// Luna-specific defaults: literary writing gets low reasoning; pure
  /// formatting should spend its output budget on text rather than thinking.
  /// Other models keep their own default unless explicitly configured.
  String? effectiveEffort(AiNarrativeTask task, String model) {
    if (reasoningEffort == 'provider') return null;
    if (reasoningEffort != 'auto') return reasoningEffort;
    if (model.toLowerCase().trim() != 'gpt-5.6-luna') return null;
    return switch (task) {
      AiNarrativeTask.narrator => 'low',
      AiNarrativeTask.jsonifier => 'none',
      AiNarrativeTask.optimizer => 'low',
      AiNarrativeTask.memory => 'none',
    };
  }

  AiTaskGenerationSettings merged(AiTaskGenerationOverride? override) =>
      AiTaskGenerationSettings(
        maxOutputTokens: override?.maxOutputTokens ?? maxOutputTokens,
        reasoningEffort: override?.reasoningEffort ?? reasoningEffort,
      );
}

/// Each nullable field inherits the application default for that task.
class AiTaskGenerationOverride {
  const AiTaskGenerationOverride({this.maxOutputTokens, this.reasoningEffort});
  final int? maxOutputTokens;
  final String? reasoningEffort;

  bool get isEmpty => maxOutputTokens == null && reasoningEffort == null;

  AiTaskGenerationOverride copyWith({
    int? maxOutputTokens,
    bool clearMaxOutputTokens = false,
    String? reasoningEffort,
    bool clearReasoningEffort = false,
  }) => AiTaskGenerationOverride(
    maxOutputTokens: clearMaxOutputTokens
        ? null : maxOutputTokens ?? this.maxOutputTokens,
    reasoningEffort: clearReasoningEffort
        ? null : reasoningEffort ?? this.reasoningEffort,
  );

  void validate() {
    if (maxOutputTokens != null &&
        (maxOutputTokens! < AiTaskGenerationSettings.minTokens ||
         maxOutputTokens! > AiTaskGenerationSettings.maxTokens) ||
        reasoningEffort != null &&
            !AiTaskGenerationSettings.reasoningChoices.contains(reasoningEffort)) {
      throw const FormatException('Surcharge de génération IA invalide.');
    }
  }

  Map<String, dynamic> toJson() => {
    if (maxOutputTokens != null) 'maxOutputTokens': maxOutputTokens,
    if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
  };

  factory AiTaskGenerationOverride.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.keys.any((k) =>
            k != 'maxOutputTokens' && k != 'reasoningEffort') ||
        value['maxOutputTokens'] != null && value['maxOutputTokens'] is! int ||
        value['reasoningEffort'] != null && value['reasoningEffort'] is! String) {
      throw const FormatException('Surcharge de génération IA invalide.');
    }
    final result = AiTaskGenerationOverride(
      maxOutputTokens: value['maxOutputTokens'] as int?,
      reasoningEffort: value['reasoningEffort'] as String?,
    );
    result.validate();
    return result;
  }

  static String? encode(Map<AiNarrativeTask, AiTaskGenerationOverride> values) {
    if (values.isEmpty) return null;
    return jsonEncode({
      for (final entry in values.entries)
        if (!entry.value.isEmpty) entry.key.name: entry.value.toJson(),
    });
  }

  static Map<AiNarrativeTask, AiTaskGenerationOverride> decode(String? json) {
    if (json == null || json.isEmpty) return const {};
    if (json.length > 4096) {
      throw const FormatException('Configuration de Partie trop volumineuse.');
    }
    final data = jsonDecode(json);
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Configuration de Partie invalide.');
    }
    final values = <AiNarrativeTask, AiTaskGenerationOverride>{};
    for (final entry in data.entries) {
      final tasks = AiNarrativeTask.values.where((t) => t.name == entry.key);
      if (tasks.isEmpty) {
        throw const FormatException('Tâche IA inconnue.');
      }
      final override = AiTaskGenerationOverride.fromJson(entry.value);
      if (!override.isEmpty) values[tasks.first] = override;
    }
    return Map.unmodifiable(values);
  }
}
