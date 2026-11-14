import 'package:material_ui/material_ui.dart';

import '../theme/domolia_theme.dart';
import 'narrator_settings.dart';

/// Early narrator editor: one style field and one list of opening messages.
/// Each non-empty line in the second field is one possible first bubble.
class NarratorSettingsPage extends StatefulWidget {
  const NarratorSettingsPage({
    super.key,
    required this.controller,
    required this.onBack,
  });

  final NarratorSettingsController controller;
  final VoidCallback onBack;

  @override
  State<NarratorSettingsPage> createState() => _NarratorSettingsPageState();
}

class _NarratorSettingsPageState extends State<NarratorSettingsPage> {
  final _style = TextEditingController();
  final _openings = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await widget.controller.initialize();
    if (!mounted) return;
    _style.text = widget.controller.narrator.narrativePrompt;
    _openings.text = widget.controller.narrator.openingMessages.join('\n');
    setState(() {});
  }

  Future<void> _save() async {
    await widget.controller.save(
      style: _style.text,
      openingMessagesText: _openings.text,
    );
  }

  @override
  void dispose() {
    _style.dispose();
    _openings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final settings = widget.controller;
        if (!settings.initialized) {
          return const Center(child: CircularProgressIndicator());
        }
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Retour aux paramètres'),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Configuration du narrateur',
                style: TextStyle(
                  color: DomoliaColors.goldLight,
                  fontSize: 25,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Personnalisez le style de l’histoire et les messages '
                'qui peuvent ouvrir une nouvelle conversation.',
                style: TextStyle(color: DomoliaColors.cream, height: 1.5),
              ),
              const SizedBox(height: 24),
              TextField(
                key: const ValueKey('narratorStyleField'),
                controller: _style,
                enabled: !settings.busy,
                minLines: 5,
                maxLines: 10,
                maxLength: 8000,
                decoration: const InputDecoration(
                  labelText: 'Style narratif',
                  alignLabelWithHint: true,
                  hintText: 'Décrivez le ton, le rythme et les personnages…',
                  helperText: 'Instructions de narration envoyées à l’IA.',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                key: const ValueKey('narratorOpeningsField'),
                controller: _openings,
                enabled: !settings.busy,
                minLines: 4,
                maxLines: 9,
                decoration: const InputDecoration(
                  labelText: 'Premiers messages possibles',
                  alignLabelWithHint: true,
                  hintText: 'Une ouverture par ligne…',
                  helperText: 'Une ligne = un message possible. '
                      'Une ouverture est choisie au hasard lors du '
                      'démarrage d’une nouvelle conversation.',
                  helperMaxLines: 3,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Le protocole JSON reste géré par Domolia et ne peut pas '
                'être modifié dans cet écran. Modifier ces réglages '
                'ne réécrit pas les messages déjà affichés.',
                style: TextStyle(
                  color: DomoliaColors.muted,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                key: const ValueKey('narratorSave'),
                onPressed: settings.busy ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Enregistrer le narrateur'),
              ),
              if (settings.busy) ...[
                const SizedBox(height: 14),
                const LinearProgressIndicator(color: DomoliaColors.gold),
              ],
              if (settings.message != null) ...[
                const SizedBox(height: 14),
                Text(
                  settings.message!,
                  key: const ValueKey('narratorSettingsMessage'),
                  style: const TextStyle(color: DomoliaColors.cream),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
