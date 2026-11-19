// ignore_for_file: curly_braces_in_flow_control_structures
import 'package:material_ui/material_ui.dart';

import '../ai/ai_controller.dart';
import '../ai/ai_provider.dart';
import '../theme/domolia_theme.dart';
import 'image_preferences.dart';
import 'image_providers.dart';

class ImageSettingsPage extends StatefulWidget {
  const ImageSettingsPage({
    super.key, required this.ai, required this.preferences,
    required this.onBack, this.sessionId, this.showBackButton = true,
    this.imageProviderFactory,
  });

  final AiConnectionController ai;
  final ImagePreferences preferences;
  final String? sessionId;
  final VoidCallback onBack;
  final bool showBackButton;
  final ImageGenerationProvider Function(AiProfile)? imageProviderFactory;

  @override
  State<ImageSettingsPage> createState() => _ImageSettingsPageState();
}

class _ImageSettingsPageState extends State<ImageSettingsPage> {
  ImageGenerationOptions _options = const ImageGenerationOptions();
  List<ImageModelCapability> _models = const [];
  bool _loading = true;
  bool _loadingModels = false;
  int _modelLoadVersion = 0;
  bool _override = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await widget.ai.initialize();
      await widget.preferences.initialize();
      final saved = widget.sessionId == null ? null
          : await widget.preferences.overrideFor(widget.sessionId!);
      if (!mounted) return;
      setState(() {
        _override = saved != null;
        _options = saved ?? widget.preferences.application;
        _loading = false;
      });
      await _loadModels();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Impossible de charger les préférences graphiques.';
        _loading = false;
      });
    }
  }

  bool get _canEdit => !_saving &&
      (widget.sessionId == null || _override);

  AiProfile? get _imageProfile {
    final id = _options.resolveProfiles(widget.ai.profiles).profileId;
    for (final item in widget.ai.profiles) {
      if (item.id == id && _supportsImages(item)) return item;
    }
    return null;
  }

  bool _supportsImages(AiProfile p) {
    if (p.kind != AiProviderKind.customAi) return false;
    final uri = Uri.tryParse(p.baseUrl);
    return uri?.scheme == 'https' && {
      'api.openai.com', 'api.openuncensored.com', 'openuncensored.com',
    }.contains(uri?.host);
  }

  String _kind(AiProfile p) =>
      Uri.parse(p.baseUrl).host == 'api.openai.com'
          ? 'openai' : 'openuncensored';

  Future<void> _loadModels() async {
    final version = ++_modelLoadVersion;
    final profile = _imageProfile;
    if (profile == null || profile.apiKey.isEmpty) {
      if (mounted) setState(() {
        _models = const [];
        _loadingModels = false;
        _error = profile == null
            ? 'Profil graphique indisponible. Vérifiez la configuration.'
            : 'Clé API manquante pour ce profil graphique.';
      });
      return;
    }

    // Clear results immediately: never display a previous provider's models
    // while the newly selected provider's catalogue is being loaded.
    setState(() {
      _loadingModels = true;
      _models = const [];
      _error = null;
    });
    try {
      final provider = widget.imageProviderFactory?.call(profile) ??
          (_kind(profile) == 'openai'
              ? OpenAiImageGenerationProvider()
              : OpenUncensoredImageGenerationProvider());
      final models = await provider.listModels(profile.apiKey);
      if (!mounted || version != _modelLoadVersion ||
          _imageProfile?.id != profile.id) return;
      setState(() => _models = models);
    } on ImageGenerationFailure catch (failure) {
      if (mounted && version == _modelLoadVersion &&
          _imageProfile?.id == profile.id) {
        setState(() {
          _models = const [];
          _error = failure.message;
        });
      }
    } catch (_) {
      if (mounted && version == _modelLoadVersion &&
          _imageProfile?.id == profile.id) {
        setState(() {
          _models = const [];
          _error = 'Impossible de récupérer les modèles graphiques.';
        });
      }
    } finally {
      if (mounted && version == _modelLoadVersion) {
        setState(() => _loadingModels = false);
      }
    }
  }

  ImageModelCapability? get _selectedModel {
    for (final model in _models) {
      if (model.id == _options.model) return model;
    }
    return null;
  }

  Future<void> _save() async {
    if (!_canEdit) return;
    setState(() { _saving = true; _error = null; });
    try {
      final next = _options;
      next.validate();
      if (_imageProfile == null ||
          (next.model.isNotEmpty && _selectedModel == null)) {
        throw const FormatException('Sélectionnez un modèle et des options valides.');
      }
      if (next.resolveProfiles(widget.ai.profiles)
          .directorProfileId.isEmpty) {
        throw const FormatException('Sélectionnez un metteur en scène IA.');
      }
      if (widget.sessionId == null) {
        await widget.preferences.saveApplication(next);
      } else {
        await widget.preferences.saveParty(widget.sessionId!, next);
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Paramètres graphiques sauvegardés.')));
    } catch (_) {
      if (mounted) setState(() => _error =
          'Enregistrement impossible : contrôlez les profils et le modèle.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleOverride(bool selected) async {
    if (widget.sessionId == null) return;
    if (!selected) {
      try {
        await widget.preferences.saveParty(widget.sessionId!, null);
        if (!mounted) return;
        setState(() {
          _override = false;
          _options = widget.preferences.application;
        });
        await _loadModels();
      } catch (_) {
        if (mounted) setState(() => _error = 'Impossible de rétablir l’héritage.');
      }
    } else {
      setState(() { _override = true; _error = null; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = _selectedModel;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (widget.showBackButton)
          Align(alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: widget.onBack, icon: const Icon(Icons.arrow_back),
              label: const Text('Retour'))),
        const Text('Connexion des IA graphiques',
          style: TextStyle(color: DomoliaColors.goldLight,
              fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('Le narrateur et le générateur graphique sont indépendants. '
          'Un compte ChatGPT connecté ne donne pas accès à l’API Images : '
          'utilisez un profil API avec votre propre clé facturable. '
          'La taille, la qualité, le style, le nombre d’images et les '
          'éléments à exclure se règlent dans chaque Livre.'),
        const SizedBox(height: 16),
        if (widget.sessionId != null)
          SwitchListTile(
            key: const ValueKey('imagePartyOverride'),
            title: const Text('Surcharger pour cette Partie'),
            subtitle: const Text('Sinon, utiliser les paramètres de l’application'),
            value: _override, onChanged: _toggleOverride,
          ),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else ...[
          DropdownButtonFormField<String>(
            key: ValueKey('imageProviderProfile-' + _options.profileId),
            initialValue: _options.profileId.isEmpty ? '' : _imageProfile?.id,
            decoration: const InputDecoration(labelText: 'Profil graphique'),
            items: [
              const DropdownMenuItem(value: '',
                  child: Text('Automatique (OpenUncensored)')),
              for (final p in widget.ai.profiles)
                if (_supportsImages(p))
                  DropdownMenuItem(value: p.id, child: Text(p.name)),
            ],
            onChanged: !_canEdit ? null : (id) {
              if (id == null) return;
              setState(() {
                _options = _options.copyWith(
                    profileId: id, model: '');
                _models = const [];
              });
              _loadModels();
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('imageDirectorProfile-' + _options.directorProfileId),
            initialValue: widget.ai.profiles.any(
                (p) => p.id == _options.directorProfileId &&
                    canDirectImages(p))
                ? _options.directorProfileId : '',
            decoration: const InputDecoration(labelText: 'Metteur en scène IA',
              helperText: 'Une IA de chat (ChatGPT ou CustomAI), '
                  'distincte du générateur d’images.'),
            items: [
              const DropdownMenuItem(value: '',
                  child: Text('Automatique (IA conversationnelle)')),
              for (final p in widget.ai.profiles)
                if (canDirectImages(p))
                  DropdownMenuItem(value: p.id, child: Text(p.name)),
            ],
            onChanged: !_canEdit ? null : (id) {
              if (id != null) setState(() => _options =
                  _options.copyWith(directorProfileId: id));
            },
          ),
          const SizedBox(height: 12),
          if (_imageProfile != null) ...[
            const SizedBox(height: 8),
            Text('Catalogue graphique : ' +
                (_kind(_imageProfile!) == 'openai'
                    ? 'OpenAI' : 'OpenUncensored'),
                style: const TextStyle(color: DomoliaColors.muted)),
          ],
          if (_loadingModels) const LinearProgressIndicator(),
          DropdownButtonFormField<String>(
            key: ValueKey('imageModel-' + _options.profileId + ':' +
                _options.model + ':' + _models.length.toString()),
            initialValue: model?.id ?? '',
            decoration: const InputDecoration(labelText: 'Modèle graphique'),
            items: [
              const DropdownMenuItem(value: '',
                  child: Text('Automatique (recommandé)')),
              for (final m in _models)
                DropdownMenuItem(value: m.id, child: Text(m.id)),
            ],
            onChanged: !_canEdit ? null : (id) {
              if (id == null) return;
              setState(() => _options = _options.copyWith(model: id));
            },
          ),
          const SizedBox(height: 12),
          const SizedBox(height: 6),
          const Text('Coût avant génération : inconnu. Aucune '
              'génération n’est lancée sans confirmation.'),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('imageSettingsSave'),
            onPressed: _canEdit && !_loadingModels ? _save : null,
            child: const Text('Enregistrer'),
          ),
        ],
      ],
    );
  }
}
