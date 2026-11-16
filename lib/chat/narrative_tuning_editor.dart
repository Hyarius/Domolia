import 'package:material_ui/material_ui.dart';

import '../theme/domolia_theme.dart';
import 'narrator.dart';

/// Shared editor for the global Narrator and each Book's override.
/// The controls are independent of the existing descriptive detail slider.
class NarrativeTuningEditor extends StatelessWidget {
  const NarrativeTuningEditor({
    super.key,
    required this.keyPrefix,
    required this.tuning,
    required this.keywordsController,
    required this.onTuningChanged,
    required this.onKeywordsChanged,
    this.enabled = true,
  });

  final String keyPrefix;
  final NarrativeTuning tuning;
  final TextEditingController keywordsController;
  final ValueChanged<NarrativeTuning> onTuningChanged;
  final VoidCallback onKeywordsChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final selected = NarrativeTuning.parseKeywords(keywordsController.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Longueur de la réponse', style: TextStyle(
          fontSize: 18, color: DomoliaColors.goldLight)),
        Slider(
          key: ValueKey('${keyPrefix}ResponseLengthSlider'),
          min: 1, max: 5, divisions: 4,
          value: tuning.responseLength.toDouble(),
          label: NarrativeTuning.lengthNames[tuning.responseLength - 1],
          onChanged: enabled ? (value) => onTuningChanged(
            tuning.copyWith(responseLength: value.round())) : null,
        ),
        Text(NarrativeTuning.lengthNames[tuning.responseLength - 1],
          style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 5),
        Text(NarrativeTuning.lengthDescriptions[tuning.responseLength - 1]),
        const SizedBox(height: DomoliaSpacing.section),
        const Text('Avancement de la scène', style: TextStyle(
          fontSize: 18, color: DomoliaColors.goldLight)),
        const SizedBox(height: 5),
        const Text('Choisissez quand le narrateur vous redonne la main. '
            'Ce réglage ne contrôle pas la quantité de détails.'),
        Slider(
          key: ValueKey('${keyPrefix}ScenePacingSlider'),
          min: 1, max: 5, divisions: 4,
          value: tuning.scenePacing.toDouble(),
          label: NarrativeTuning.pacingNames[tuning.scenePacing - 1],
          onChanged: enabled ? (value) => onTuningChanged(
            tuning.copyWith(scenePacing: value.round())) : null,
        ),
        Text(NarrativeTuning.pacingNames[tuning.scenePacing - 1],
          style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 5),
        Text(NarrativeTuning.pacingDescriptions[tuning.scenePacing - 1]),
        const SizedBox(height: DomoliaSpacing.section),
        const Text('Mots-clés de style', style: TextStyle(
          fontSize: 18, color: DomoliaColors.goldLight)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 0,
          children: [
            for (final suggestion in NarrativeTuning.keywordSuggestions)
              FilterChip(
                key: ValueKey('${keyPrefix}Keyword-$suggestion'),
                label: Text(suggestion),
                selected: selected.any((word) =>
                    word.toLowerCase() == suggestion.toLowerCase()),
                onSelected: !enabled ? null : (chosen) {
                  final updated = selected.toList();
                  if (chosen) {
                    if (updated.length >= 8) return;
                    updated.add(suggestion);
                  } else {
                    updated.removeWhere((word) =>
                        word.toLowerCase() == suggestion.toLowerCase());
                  }
                  keywordsController.text = updated.join(', ');
                  onKeywordsChanged();
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          key: ValueKey('${keyPrefix}StyleKeywordsField'),
          controller: keywordsController,
          enabled: enabled,
          maxLength: 300,
          decoration: const InputDecoration(
            labelText: 'Mots-clés personnalisés',
            hintText: 'Immersif, Dialogué, Sensoriel…',
            helperText: 'Séparez les mots-clés par une virgule '
                '(8 maximum, 32 caractères chacun).',
            helperMaxLines: 2,
          ),
          onChanged: (_) => onKeywordsChanged(),
        ),
      ],
    );
  }
}
