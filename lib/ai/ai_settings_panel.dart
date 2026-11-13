import 'package:material_ui/material_ui.dart';

import '../theme/domolia_theme.dart';
import 'ai_controller.dart';

class AiSettingsPanel extends StatefulWidget {
  const AiSettingsPanel({
    super.key,
    required this.controller,
    required this.onBack,
  });

  final AiConnectionController controller;
  final VoidCallback onBack;

  @override
  State<AiSettingsPanel> createState() => _AiSettingsPanelState();
}

class _AiSettingsPanelState extends State<AiSettingsPanel> {
  final _base = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await widget.controller.initialize();
    if (!mounted) return;
    _base.text = widget.controller.baseUrl;
    _model.text = widget.controller.model;
  }

  @override
  void dispose() {
    _base.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<bool> _save() async {
    final saved = await widget.controller.save(_base.text, _model.text, _key.text);
    if (saved && mounted) _key.clear();
    return saved;
  }

  Future<void> _saveAndLoadModels() async {
    if (await _save()) await widget.controller.loadModels();
  }

  Future<void> _saveAndTest() async {
    if (await _save()) await widget.controller.testConnection();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              TextButton.icon(
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back),
                label: const Text('Retour aux paramètres'),
              ),
              const SizedBox(height: 14),
              const Text(
                'Fournisseur IA',
                style: TextStyle(
                  color: DomoliaColors.goldLight,
                  fontSize: 25,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Connectez votre compte OpenUncensored. '
                'La clé est chiffrée sur votre téléphone et ne figure pas dans les journaux.',
                style: TextStyle(color: DomoliaColors.cream, height: 1.5),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _base,
                enabled: !c.busy,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Adresse du fournisseur (HTTPS)',
                  hintText: 'https://api.openuncensored.com/v1',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _key,
                key: const ValueKey('aiApiKeyField'),
                enabled: !c.busy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Clé API',
                  hintText: c.hasKey ? 'Clé déjà enregistrée' : 'ou-…',
                  helperText: c.hasKey
                      ? 'Laissez vide pour conserver la clé actuelle.'
                      : 'Votre clé reste sur cet appareil.',
                  suffixIcon: const Icon(Icons.lock_outline),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _model,
                enabled: !c.busy,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Identifiant du modèle',
                  helperText: 'Sélectionnez dans le catalogue ou saisissez un identifiant.',
                ),
              ),
              if (c.models.isNotEmpty) ...[
                const SizedBox(height: 12),
                InputDecorator(
                  decoration: const InputDecoration(labelText: 'Modèles disponibles'),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      key: const ValueKey('aiModelSelector'),
                      value: c.models.any((entry) => entry.id == _model.text)
                          ? _model.text
                          : null,
                      isExpanded: true,
                      hint: const Text('Choisir un modèle'),
                      items: [
                        for (final item in c.models)
                          DropdownMenuItem(
                            value: item.id,
                            child: Text(item.id, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: c.busy ? null : (value) {
                        if (value != null) setState(() => _model.text = value);
                      },
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: c.busy ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Enregistrer la configuration'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: c.busy ? null : _saveAndLoadModels,
                icon: const Icon(Icons.list_alt),
                label: const Text('Charger les modèles'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: c.busy ? null : _saveAndTest,
                icon: const Icon(Icons.wifi_tethering),
                label: const Text('Tester la connexion'),
              ),
              const SizedBox(height: 8),
              const Text(
                'Le test envoie une courte requête au modèle et peut consommer des crédits.',
                style: TextStyle(color: DomoliaColors.muted, fontSize: 12),
              ),
              if (c.hasKey) ...[
                const SizedBox(height: 14),
                TextButton.icon(
                  onPressed: c.busy ? null : () async {
                    await c.removeKey();
                    if (mounted) _key.clear();
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Supprimer la clé API'),
                ),
              ],
              if (c.busy) ...[
                const SizedBox(height: 20),
                const LinearProgressIndicator(color: DomoliaColors.gold),
              ],
              if (c.message != null) ...[
                const SizedBox(height: 18),
                Text(
                  c.message!,
                  key: const ValueKey('aiConnectionStatus'),
                  style: TextStyle(
                    color: c.testPassed == true
                        ? DomoliaColors.goldLight
                        : DomoliaColors.cream,
                  ),
                ),
              ],
              if (c.testReply != null) ...[
                const SizedBox(height: 10),
                Text(
                  'Réponse du modèle : ${c.testReply!}',
                  key: const ValueKey('aiTestReply'),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
