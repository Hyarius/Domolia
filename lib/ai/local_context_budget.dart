import 'dart:convert';

import 'ai_provider.dart';
import 'local_model_catalog.dart';
import 'local_prompt.dart';

/// Conservative per-model estimate, recalibrated with native token counts
/// after each completed request. Not a tokenizer.
class LocalTokenEstimator {
  final Map<String, double> _tokensPerByte = {};

  double rate(LocalModelVariant variant) =>
      _tokensPerByte[variant.id] ??
      (variant.format == LocalPromptFormat.chatMl ? 0.43 : 0.48);

  int estimate(LocalModelVariant variant, String prompt) =>
      (utf8.encode(prompt).length * rate(variant)).ceil() + 24;

  void observe(LocalModelVariant variant, String prompt, int actualTokens) {
    final length = utf8.encode(prompt).length;
    if (length < 16 || actualTokens < 1) return;
    final sample = actualTokens / length;
    final previous = rate(variant);
    _tokensPerByte[variant.id] =
        (previous * 0.4 + sample * 0.6 + 0.05).clamp(0.30, 1.10).toDouble();
  }
}

/// One accounting rule for narrator, JSONifier and live memory.
/// Includes ChatML/INST markup and reserves output plus safety margin.
class LocalContextBudget {
  const LocalContextBudget({
    required this.model,
    required this.estimator,
    required this.outputTokens,
  });

  static const safetyTokens = 96;
  final LocalModelVariant model;
  final LocalTokenEstimator estimator;
  final int outputTokens;

  int get capacity => model.contextTokens - outputTokens - safetyTokens;
  String format(List<AiMessage> messages) => LocalPrompt.format(model, messages);
  int estimate(List<AiMessage> messages) =>
      estimator.estimate(model, format(messages));
  bool fits(List<AiMessage> messages) =>
      capacity > 0 && estimate(messages) <= capacity;

  /// Rough maximum characters before UTF-8 accents, format and safety overhead.
  int get availableTextCharacters =>
      ((capacity - 24) / estimator.rate(model)).floor();

  void requireFit(List<AiMessage> messages) {
    if (!fits(messages)) {
      throw FormatException(
        'Le contexte du modèle local est trop long '
        '(${estimate(messages)} tokens estimés pour $capacity disponibles, '
        '${model.contextTokens} au total). Réduisez la réponse, le Lore '
        'ou l’historique, sans supprimer de faits canoniques.',
      );
    }
  }
}
