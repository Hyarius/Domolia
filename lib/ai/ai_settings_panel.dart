import 'package:material_ui/material_ui.dart';

import '../theme/domolia_theme.dart';
import 'ai_controller.dart';
import 'ai_provider.dart';

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
  final _key = TextEditingController();
  String? _selectedModel;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await widget.controller.initialize();
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

  @override
  void dispose() {
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
    if (saved && mounted) _key.clear();
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
        const SizedBox(height: 8),
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
        const SizedBox(height: 12),
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
        const SizedBox(height: 6),
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
        const SizedBox(height: 17),
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
        const SizedBox(height: 17),
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

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        if (!c.initialized || c.profiles.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        final selectedModel = _selectedModel ?? c.model;
        final modelIds = <String>{
          if (selectedModel.isNotEmpty) selectedModel,
          for (final entry in c.models) entry.id,
        }.toList();

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
                'Fournisseur IA',
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
              const SizedBox(height: 20),
              _profileAndStatus(c),
              const SizedBox(height: 20),
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
                            if (value != null) {
                              setState(() => _selectedModel = value);
                              if (c.selectedKind == AiProviderKind.chatGpt) {
                                c.selectChatGptModel(value);
                              }
                            }
                          },
                  ),
                ),
              ),
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
                'Le test peut consommer des crédits du fournisseur IA.',
                style: TextStyle(color: DomoliaColors.muted, fontSize: 12),
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
                            if (value != null) {
                              setState(() => _selectedModel = value);
                              if (c.selectedKind == AiProviderKind.chatGpt) {
                                c.selectChatGptModel(value);
                              }
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
