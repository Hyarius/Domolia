import 'package:material_ui/material_ui.dart';

import '../theme/domolia_theme.dart';
import 'ai_controller.dart';
import 'ai_task_routing.dart';
import 'ai_provider.dart';

class AiSettingsPanel extends StatefulWidget {
  const AiSettingsPanel({
    super.key,
    required this.controller,
    required this.onBack,
    this.showBackButton = true,
    this.taskRouting,
  });

  final AiConnectionController controller;
  final VoidCallback onBack;
  final bool showBackButton;
  final AiTaskRouting? taskRouting;

  @override
  State<AiSettingsPanel> createState() => _AiSettingsPanelState();
}

class _AiSettingsPanelState extends State<AiSettingsPanel> {
  final _base = TextEditingController();
  final _key = TextEditingController();
  String? _selectedModel;
  bool _probingTools = false;

  @override
  void initState() {
    super.initState();
    widget.taskRouting?.addListener(_routingChanged);
    _load();
  }

  Future<void> _load() async {
    await widget.controller.initialize();
    try {
      await widget.taskRouting?.initialize();
    } catch (_) {
      // Existing profile editing must remain available.
    }
    if (mounted) _reloadFields();
  }

  void _reloadFields() {
    final controller = widget.controller;
    if (!controller.initialized || controller.profiles.isEmpty) return;
    setState(() {
      _base.text = controller.baseUrl;
      _selectedModel = controller.model;
      _key.clear();
    });
  }

  void _routingChanged() { if (mounted) setState(() {}); }

  @override
  void dispose() {
    widget.taskRouting?.removeListener(_routingChanged);
    _base.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _selectProviderKind(AiProviderKind kind) async {
    final controller = widget.controller;
    if (kind == controller.selectedKind) return;
    if (controller.selectedKind == AiProviderKind.customAi && !await _save()) {
      return;
    }
    if (await controller.setProviderKind(kind) && mounted) {
      _reloadFields();
    }
  }

  Future<bool> _save() async {
    final saved = await widget.controller.save(
      _base.text,
      _selectedModel ?? widget.controller.model,
      _key.text,
    );
    if (saved && mounted) _reloadFields();
    return saved;
  }

  Future<void> _saveAndLoadModels() async {
    if (widget.controller.selectedKind == AiProviderKind.chatGpt ||
        await _save()) {
      await widget.controller.loadModels();
    }
  }

  Future<void> _saveAndTest() async {
    if (widget.controller.selectedKind == AiProviderKind.chatGpt ||
        await _save()) {
      await widget.controller.testConnection();
    }
  }

  Future<String?> _askForName({String? initialName}) => showDialog<String>(
        context: context,
        builder: (_) => _ProfileNameDialog(initialName: initialName),
      );

  Future<void> _createProfile() async {
    if (widget.controller.busy) return;
    final name = await _askForName();
    if (name == null || !mounted) return;
    if (widget.controller.selectedKind == AiProviderKind.customAi &&
        !await _save()) {
      return;
    }
    if (await widget.controller.createProfile(name) && mounted) {
      _reloadFields();
    }
  }

  Future<void> _renameProfile() async {
    final name = await _askForName(initialName: widget.controller.selectedProfile.name);
    if (name != null && mounted) await widget.controller.renameProfile(name);
  }

  Future<void> _deleteProfile() async {
    if (widget.controller.profiles.length < 2 || widget.controller.busy) return;
    final name = widget.controller.selectedProfile.name;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Supprimer la configuration ?'),
        content: Text(
          'Le profil « $name » et sa clé API seront supprimés de ce téléphone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      if (await widget.controller.deleteProfile() && mounted) {
        _reloadFields();
      }
    }
  }

  Future<void> _selectProfile(String id) async {
    if (id == widget.controller.selectedProfileId) return;
    // Persist in-progress form edits before switching: no profile's key or
    // model should silently end up belonging to another profile.
    if (widget.controller.selectedKind == AiProviderKind.customAi &&
        !await _save()) {
      return;
    }
    if (await widget.controller.selectProfile(id) && mounted) {
      _reloadFields();
    }
  }

  /// Optional billed probe. Only a real native tool-call response can mark
  /// the current profile as confirmed compatible.
  Future<void> _probeTools() async {
    if (_probingTools || widget.controller.busy) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tester le Tool Calling ?'),
        content: const Text('Ce test envoie une courte requête au modèle '
            'sélectionné et peut consommer des crédits. Aucun coût '
            'n’est engagé sans cette confirmation.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Lancer le test')),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    final profileId = widget.controller.selectedProfileId;
    setState(() => _probingTools = true);
    var verified = false;
    try {
      final binding = await widget.controller.connectionForProfile(profileId);
      if (binding.provider is! AiToolCallingChatProvider) {
        throw const AiToolsUnsupportedException();
      }
      var called = false;
      var finished = false;
      await for (final chunk in
          (binding.provider as AiToolCallingChatProvider).streamToolChat(
        binding.configuration,
        messages: const [
          AiToolMessage(role: 'system', content:
              'Tu dois appeler le seul outil fourni, sans texte libre.'),
          AiToolMessage(role: 'user', content:
              'Appelle ping avec la valeur "ok".'),
        ],
        tools: const [
          AiToolDefinition('ping', 'Echo a short test value', {
            'type': 'object',
            'properties': {'value': {'type': 'string'}},
            'required': ['value'],
          }),
        ],
        maxTokens: 128,
      )) {
        if (chunk.callName == 'ping') called = true;
        if (chunk.finishReason == 'tool_calls') finished = true;
      }
      verified = called && finished;
      if (verified && widget.controller.selectedProfileId == profileId) {
        verified = await widget.controller.setToolCallingCompatibility(
            AiToolCallingCompatibility.supported);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
          verified ? 'Tool Calling confirmé et activé pour ce modèle.'
              : 'Test non concluant. Compatibilité inchangée.',
        )));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text(
          'Le modèle n’a pas effectué le test. Compatibilité inchangée.',
        )));
      }
    } finally {
      if (mounted) setState(() => _probingTools = false);
    }
  }

  void _showStatusError() {
    final reason = widget.controller.statusError ??
        'Impossible de joindre le fournisseur. Vérifiez les paramètres.';
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('aiStatusErrorDialog'),
        title: const Text('Échec de connexion'),
        content: Text(reason, key: const ValueKey('aiStatusErrorReason')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
  }

  /// Separate full-width controls are easier to read and tap on phones.
  /// In particular, do not share a single horizontal row between the
  /// profile picker, the actions and the connection status.
  Widget _profileAndStatus(AiConnectionController controller) {
    final status = controller.status;
    final (label, indicatorColor) = switch (status) {
      AiConnectionStatus.untested => ('Non testé', DomoliaColors.muted),
      AiConnectionStatus.testing => ('En cours', DomoliaColors.muted),
      AiConnectionStatus.connected => ('Connecté', const Color(0xFF59D78F)),
      AiConnectionStatus.invalid => ('Invalide', const Color(0xFFFF7777)),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Configuration API',
          style: TextStyle(
            color: DomoliaColors.goldLight,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: DomoliaSpacing.compact),
        Container(
          key: const ValueKey('aiProfilePicker'),
          constraints: const BoxConstraints(minHeight: 58),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: DomoliaColors.raisedSurface,
            border: Border.all(color: DomoliaColors.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              key: const ValueKey('aiProfileSelector'),
              value: controller.selectedProfileId,
              isExpanded: true,
              itemHeight: 64,
              menuMaxHeight: 360,
              dropdownColor: DomoliaColors.raisedSurface,
              borderRadius: BorderRadius.circular(12),
              icon: const Icon(
                Icons.keyboard_arrow_down_rounded,
                color: DomoliaColors.goldLight,
              ),
              selectedItemBuilder: (context) => [
                for (final profile in controller.profiles)
                  Tooltip(
                    message: profile.name,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        profile.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: DomoliaColors.cream,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
              ],
              items: [
                for (final profile in controller.profiles)
                  DropdownMenuItem(
                    value: profile.id,
                    child: Text(
                      profile.name,
                      maxLines: 2,
                      softWrap: true,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: DomoliaColors.cream,
                        fontSize: 16,
                      ),
                    ),
                  ),
              ],
              onChanged: controller.busy
                  ? null
                  : (id) {
                      if (id != null) _selectProfile(id);
                    },
            ),
          ),
        ),
        ExpansionTile(
          key: const ValueKey('aiCompatibilityAdvanced'),
          title: const Text('Compatibilité et tests avancés'),
          subtitle: const Text('À modifier seulement si un modèle en a besoin'),
          childrenPadding: const EdgeInsets.symmetric(vertical: 8),
          children: [
        DropdownButtonFormField<AiNsfwCompatibility>(
          key: const ValueKey('aiNsfwCapability'),
          initialValue: controller.selectedProfile.nsfwCompatibility,
          decoration: const InputDecoration(
            labelText: 'Capacité NSFW déclarée',
          ),
          items: const [
            DropdownMenuItem(
              value: AiNsfwCompatibility.unknown,
              child: Text('Inconnue'),
            ),
            DropdownMenuItem(
              value: AiNsfwCompatibility.supported,
              child: Text('Compatible'),
            ),
            DropdownMenuItem(
              value: AiNsfwCompatibility.unsupported,
              child: Text('Incompatible'),
            ),
          ],
          onChanged: controller.busy ? null : (value) {
            if (value != null) controller.setNsfwCompatibility(value);
          },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<AiToolCallingCompatibility>(
          key: ValueKey('aiToolCallingCapability-${controller.selectedProfileId}'),
          initialValue: controller.selectedProfile.toolCallingCompatibility,
          decoration: const InputDecoration(
            labelText: 'Capacité Tool Calling déclarée',
          ),
          items: const [
            DropdownMenuItem(
              value: AiToolCallingCompatibility.unknown,
              child: Text('Inconnue'),
            ),
            DropdownMenuItem(
              value: AiToolCallingCompatibility.supported,
              child: Text('Compatible'),
            ),
            DropdownMenuItem(
              value: AiToolCallingCompatibility.unsupported,
              child: Text('Incompatible'),
            ),
          ],
          onChanged: controller.busy ? null : (value) {
            if (value != null) controller.setToolCallingCompatibility(value);
          },
        ),
        const SizedBox(height: DomoliaSpacing.compact),
        TextButton.icon(
          key: const ValueKey('aiProbeToolCalling'),
          onPressed: controller.busy || _probingTools
              ? null : _probeTools,
          icon: const Icon(Icons.fact_check_outlined),
          label: Text(_probingTools
              ? 'Vérification en cours…' : 'Tester le Tool Calling (payant)'),
        ),
          ],
        ),
        const SizedBox(height: DomoliaSpacing.compact),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              key: const ValueKey('aiAddProfile'),
              onPressed: controller.busy ? null : _createProfile,
              icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
              label: const Text('Ajouter un profil'),
            ),
            PopupMenuButton<String>(
              key: const ValueKey('aiProfileActions'),
              tooltip: 'Gérer la configuration API',
              enabled: !controller.busy,
              onSelected: (action) {
                if (action == 'rename') _renameProfile();
                if (action == 'delete') _deleteProfile();
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'rename',
                  child: Text('Renommer'),
                ),
                PopupMenuItem(
                  value: 'delete',
                  enabled: controller.profiles.length > 1,
                  child: const Text('Supprimer'),
                ),
              ],
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.more_horiz_rounded,
                        color: DomoliaColors.goldLight, size: 20),
                    SizedBox(width: 7),
                    Text('Gérer',
                        style: TextStyle(color: DomoliaColors.goldLight)),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: DomoliaSpacing.section),
        const Text(
          'Type de fournisseur',
          style: TextStyle(
            color: DomoliaColors.goldLight,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          key: const ValueKey('aiProviderKindPicker'),
          constraints: const BoxConstraints(minHeight: 58),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: DomoliaColors.raisedSurface,
            border: Border.all(color: DomoliaColors.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<AiProviderKind>(
              key: const ValueKey('aiProviderKindSelector'),
              value: controller.selectedKind,
              isExpanded: true,
              dropdownColor: DomoliaColors.raisedSurface,
              items: const [
                DropdownMenuItem(
                  value: AiProviderKind.chatGpt,
                  child: Text('ChatGPT'),
                ),
                DropdownMenuItem(
                  value: AiProviderKind.customAi,
                  child: Text('CustomAI'),
                ),
              ],
              onChanged: controller.busy ? null : (kind) {
                if (kind != null) _selectProviderKind(kind);
              },
            ),
          ),
        ),
        const SizedBox(height: DomoliaSpacing.section),
        const Text(
          'État de la connexion',
          style: TextStyle(
            color: DomoliaColors.goldLight,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          key: const ValueKey('aiConnectionStatus'),
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: indicatorColor.withValues(alpha: 0.08),
            border: Border.all(color: indicatorColor),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              if (status == AiConnectionStatus.testing)
                SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: indicatorColor,
                  ),
                )
              else
                Icon(Icons.circle, color: indicatorColor, size: 16),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  key: const ValueKey('aiConnectionStatusLabel'),
                  style: TextStyle(
                    color: indicatorColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              if (status == AiConnectionStatus.invalid)
                IconButton(
                  key: const ValueKey('aiStatusErrorButton'),
                  tooltip: 'Voir la raison de l’échec',
                  icon: Icon(
                    Icons.chevron_right_rounded,
                    size: 26,
                    color: indicatorColor,
                  ),
                  onPressed: _showStatusError,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _taskProfiles(AiConnectionController controller) {
    final routing = widget.taskRouting;
    if (routing == null || !routing.initialized) {
      return const SizedBox.shrink();
    }
    const titles = <AiNarrativeTask, String>{
      AiNarrativeTask.narrator: 'Narrateur',
      AiNarrativeTask.memory: 'Mémoire automatique',
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: DomoliaSpacing.compact),
      const Divider(),
      const SizedBox(height: DomoliaSpacing.compact),
      ExpansionTile(
        key: const ValueKey('aiTaskSettings'),
        tilePadding: EdgeInsets.zero,
        title: const Text('Modèles et budgets par tâche'),
        subtitle: const Text('Narrateur et mémoire automatique'),
        children: [
      const SizedBox(height: 8),
      const Text('Choisissez parmi les profils déjà configurés. '
        'Ces paramètres s’appliquent par défaut à toutes les Parties ; '
        'chaque Partie peut les surcharger.',
        style: TextStyle(color: DomoliaColors.muted)),
      const SizedBox(height: DomoliaSpacing.field),
      for (final task in AiNarrativeTask.active) ...[
        Builder(builder: (context) {
          final chosen = routing.profileFor(task);
          final known = chosen != null &&
              controller.profiles.any((p) => p.id == chosen);
          final current = known ? chosen : '';
          return DropdownButtonFormField<String>(
            key: ValueKey('aiTaskDefault-${task.name}-$current'),
            isExpanded: true,
            initialValue: current,
            decoration: InputDecoration(labelText: titles[task],
              helperText: chosen != null && !known
                  ? 'Ancien profil supprimé : choisissez-en un autre.'
                  : null),
            items: [
              DropdownMenuItem(value: '', child: Text(
                task == AiNarrativeTask.memory
                    ? 'Même IA que le narrateur' : 'Profil du Livre')),
              for (final profile in controller.profiles)
                DropdownMenuItem(value: profile.id, child: Text(
                  profile.name, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: controller.busy ? null : (id) async {
              try {
                await routing.setProfile(task, id == '' ? null : id);
              } catch (_) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text(
                    'Impossible d’enregistrer ce profil de tâche.')));
              }
            },
          );
        }),
        Builder(builder: (context) {
          final generation = routing.generationFor(task);
          final preset = switch (task) {
            AiNarrativeTask.narrator => 'low',
            AiNarrativeTask.jsonifier => 'none',
            AiNarrativeTask.optimizer => 'low',
            AiNarrativeTask.memory => 'none',
          };
          Future<void> save(AiTaskGenerationSettings options) async {
            try {
              await routing.setGeneration(task, options);
            } catch (_) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text(
                  'Impossible d’enregistrer les paramètres de génération.')));
            }
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: DomoliaSpacing.field),
              DropdownButtonFormField<int>(
                key: ValueKey('aiTaskTokens-${task.name}-${generation.maxOutputTokens}'),
                initialValue: generation.maxOutputTokens,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Budget maximal de sortie (tokens)'),
                items: [
                  for (final tokens in AiTaskGenerationSettings.tokenChoices)
                    DropdownMenuItem(value: tokens,
                      child: Text('$tokens tokens')),
                ],
                onChanged: controller.busy ? null : (tokens) {
                  if (tokens != null) {
                    save(AiTaskGenerationSettings(
                      maxOutputTokens: tokens,
                      reasoningEffort: generation.reasoningEffort,
                    ));
                  }
                },
              ),
              const SizedBox(height: DomoliaSpacing.field),
              DropdownButtonFormField<String>(
                key: ValueKey('aiTaskReasoning-${task.name}-${generation.reasoningEffort}'),
                initialValue: generation.reasoningEffort,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Effort de raisonnement (ChatGPT)',
                  helperText: 'Auto : Luna = $preset ; autres modèles = défaut fournisseur.',
                ),
                items: [
                  for (final effort in AiTaskGenerationSettings.reasoningChoices)
                    DropdownMenuItem(value: effort, child: Text(
                      effort == 'auto' ? 'Automatique' :
                      effort == 'provider' ? 'Défaut du fournisseur' :
                      effort.toUpperCase())),
                ],
                onChanged: controller.busy ? null : (effort) {
                  if (effort != null) {
                    save(AiTaskGenerationSettings(
                      maxOutputTokens: generation.maxOutputTokens,
                      reasoningEffort: effort,
                    ));
                  }
                },
              ),
            ],
          );
        }),
        const SizedBox(height: DomoliaSpacing.section),
      ],
        ],
      ),
      const SizedBox(height: 14),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        if (!c.initialized || c.profiles.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        // ChatGPT is an account-backed catalogue, not a free-form model
        // field. Never display a stale CustomAI model as a valid choice.
        final isChatGpt = c.selectedKind == AiProviderKind.chatGpt;
        final selectedModel = isChatGpt ? c.model : _selectedModel ?? c.model;
        final modelIds = <String>{
          if (!isChatGpt) '',
          if (!isChatGpt && selectedModel.isNotEmpty &&
              !AiConnectionController.isImageModel(selectedModel))
            selectedModel,
          for (final entry in c.models)
            if (isChatGpt ||
                !AiConnectionController.isImageModel(entry.id))
              entry.id,
        }.toList();
        final effectiveModel = !isChatGpt &&
                AiConnectionController.isImageModel(selectedModel)
            ? '' : selectedModel;
        final imageOnlySelected = !isChatGpt &&
            effectiveModel.isEmpty &&
            Uri.tryParse(_base.text.trim())?.host == 'api.openai.com';

        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              if (widget.showBackButton) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Retour aux paramètres'),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              const Text(
                'Profils IA',
                style: TextStyle(
                  color: DomoliaColors.goldLight,
                  fontSize: 25,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Sélectionnez votre connexion. Chaque profil conserve '
                'ses propres paramètres et sa clé sécurisée.',
                style: TextStyle(color: DomoliaColors.cream, height: 1.5),
              ),
              const SizedBox(height: DomoliaSpacing.section),
              _profileAndStatus(c),
              const SizedBox(height: DomoliaSpacing.section),
              if (c.selectedKind == AiProviderKind.customAi) ...[
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
              const SizedBox(height: DomoliaSpacing.field),
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
              const SizedBox(height: DomoliaSpacing.field),
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Modèle de chat (facultatif pour les images)',
                  helperText: 'Pour un profil OpenAI réservé aux images, '
                      'choisissez « Images uniquement ». Le modèle graphique '
                      'se règle séparément dans Paramètres → Images.',
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    key: const ValueKey('aiModelSelector'),
                    value: modelIds.contains(effectiveModel) ? effectiveModel : null,
                    isExpanded: true,
                    itemHeight: 72,
                    menuMaxHeight: 360,
                    dropdownColor: DomoliaColors.raisedSurface,
                    borderRadius: BorderRadius.circular(12),
                    hint: const Text('Charger les modèles'),
                    selectedItemBuilder: (context) => [
                      for (final id in modelIds)
                        Tooltip(
                          message: id.isEmpty ? 'Images uniquement' : id,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              id.isEmpty ? 'Images uniquement (sans chat)' : id,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                    ],
                    items: [
                      for (final id in modelIds)
                        DropdownMenuItem(
                          value: id,
                          child: Text(
                            id.isEmpty ? 'Images uniquement (sans chat)' : id,
                            maxLines: 2,
                            softWrap: true,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: c.busy
                        ? null
                        : (value) {
                            if (value == null) return;
                            if (c.selectedKind == AiProviderKind.chatGpt) {
                              // Only catalogued models can be persisted.
                              c.selectChatGptModel(value);
                            } else {
                              setState(() => _selectedModel = value);
                            }
                          },
                  ),
                ),
              ),
              const SizedBox(height: DomoliaSpacing.section),
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
                label: Text(imageOnlySelected
                    ? 'Vérifier la clé API (sans génération)'
                    : 'Tester la connexion de chat'),
              ),
              const SizedBox(height: 8),
              Text(
                imageOnlySelected
                    ? 'Ce test interroge le catalogue des modèles, sans '
                      'générer d’image ni de texte. Il ne garantit pas '
                      'l’accès au modèle d’image ni le solde de crédits.'
                    : 'Le test de chat peut consommer des crédits.',
                style: const TextStyle(
                    color: DomoliaColors.muted, fontSize: 12),
              ),
              if (c.hasKey) ...[
                const SizedBox(height: 14),
                TextButton.icon(
                  onPressed: c.busy
                      ? null
                      : () async {
                          await c.removeKey();
                          if (mounted) _key.clear();
                        },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Supprimer la clé API'),
                ),
              ],
              ] else ...[
                const Text(
                  'Connectez un compte ChatGPT à cette configuration nommée. '
                  'Les identifiants OAuth restent protégés sur ce téléphone.',
                  style: TextStyle(color: DomoliaColors.cream, height: 1.5),
                ),
                const SizedBox(height: 14),
                FutureBuilder(
                  future: c.chatGptSession,
                  builder: (context, snapshot) {
                    final session = snapshot.data;
                    if (session == null) {
                      return const Text(
                        'Compte ChatGPT non connecté.',
                        style: TextStyle(color: DomoliaColors.muted),
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          session.email.isEmpty
                              ? 'Compte ChatGPT connecté.'
                              : 'Compte : ${session.email}',
                        ),
                        const SizedBox(height: 6),
                        Text(
                          session.planEnabled
                              ? 'Utilisation du forfait autorisée.'
                              : 'Autorisation du forfait non accordée.',
                          style: const TextStyle(color: DomoliaColors.muted),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  key: const ValueKey('chatGptConnect'),
                  onPressed: c.busy ? null : c.connectChatGpt,
                  icon: const Icon(Icons.login),
                  label: const Text('Continuer avec ChatGPT'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const ValueKey('chatGptDisconnect'),
                  onPressed: c.busy ? null : c.disconnectChatGpt,
                  icon: const Icon(Icons.logout),
                  label: const Text('Déconnecter ChatGPT'),
                ),
                const SizedBox(height: 18),
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Modèle de chat',
                  helperText: 'Charger les modèles actualise cette liste.',
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    key: const ValueKey('aiModelSelector'),
                    value: modelIds.contains(selectedModel) ? selectedModel : null,
                    isExpanded: true,
                    itemHeight: 72,
                    menuMaxHeight: 360,
                    dropdownColor: DomoliaColors.raisedSurface,
                    borderRadius: BorderRadius.circular(12),
                    hint: const Text('Charger les modèles'),
                    selectedItemBuilder: (context) => [
                      for (final id in modelIds)
                        Tooltip(
                          message: id,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              id,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                    ],
                    items: [
                      for (final id in modelIds)
                        DropdownMenuItem(
                          value: id,
                          child: Text(
                            id,
                            maxLines: 2,
                            softWrap: true,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: c.busy
                        ? null
                        : (value) {
                            if (value == null) return;
                            if (c.selectedKind == AiProviderKind.chatGpt) {
                              // Only catalogued models can be persisted.
                              c.selectChatGptModel(value);
                            } else {
                              setState(() => _selectedModel = value);
                            }
                          },
                  ),
                ),
              ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: c.busy ? null : _saveAndLoadModels,
                  icon: const Icon(Icons.list_alt),
                  label: const Text('Charger les modèles ChatGPT'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: c.busy ? null : _saveAndTest,
                  icon: const Icon(Icons.wifi_tethering),
                  label: const Text('Tester ChatGPT'),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Les requêtes autorisées utilisent les limites de '
                  'votre abonnement ChatGPT.',
                  style: TextStyle(color: DomoliaColors.muted, fontSize: 12),
                ),
              ],
              if (c.busy && c.status != AiConnectionStatus.testing) ...[
                const SizedBox(height: 18),
                const LinearProgressIndicator(color: DomoliaColors.gold),
              ],
              if (c.message != null) ...[
                const SizedBox(height: 16),
                Text(
                  c.message!,
                  key: const ValueKey('aiConnectionMessage'),
                  style: const TextStyle(color: DomoliaColors.muted),
                ),
              ],
              if (c.testReply != null) ...[
                const SizedBox(height: 12),
                Text(
                  'Réponse du modèle : ${c.testReply!}',
                  key: const ValueKey('aiTestReply'),
                ),
              ],
              _taskProfiles(c),
            ],
          ),
        );
      },
    );
  }
}

class _ProfileNameDialog extends StatefulWidget {
  const _ProfileNameDialog({this.initialName});

  final String? initialName;

  @override
  State<_ProfileNameDialog> createState() => _ProfileNameDialogState();
}

class _ProfileNameDialogState extends State<_ProfileNameDialog> {
  late final TextEditingController _input =
      TextEditingController(text: widget.initialName ?? '');

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _confirm() {
    final value = _input.text.trim();
    if (value.isNotEmpty) Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.initialName == null
            ? 'Nouvelle configuration API'
            : 'Renommer le profil',
      ),
      content: TextField(
        key: const ValueKey('aiProfileNameField'),
        controller: _input,
        autofocus: true,
        maxLength: 60,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(labelText: 'Nom de la configuration'),
        onSubmitted: (_) => _confirm(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _confirm,
          child: const Text('Valider'),
        ),
      ],
    );
  }
}
