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
  });

  final AiConnectionController ai;
  final ImagePreferences preferences;
  final String? sessionId;
  final VoidCallback onBack;
  final bool showBackButton;

  @override
  State<ImageSettingsPage> createState() => _ImageSettingsPageState();
}

class _ImageSettingsPageState extends State<ImageSettingsPage> {
  final _style = TextEditingController();
  ImageGenerationOptions _options = const ImageGenerationOptions();
  List<ImageModelCapability> _models = const [];
  bool _loading = true;
  bool _loadingModels = false;
  bool _override = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _style.dispose();
    super.dispose();
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
        _style.text = _options.style;
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
    for (final item in widget.ai.profiles) {
      if (item.id == _options.profileId && _supportsImages(item)) return item;
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
    final profile = _imageProfile;
    if (profile == null || profile.apiKey.isEmpty) {
      if (mounted) setState(() {
        _models = const [];
        if (profile != null) _error = 'Clé API manquante pour ce profil.';
      });
      return;
    }
    setState(() { _loadingModels = true; _error = null; });
    try {
      final provider = _kind(profile) == 'openai'
          ? OpenAiImageGenerationProvider()
          : OpenUncensoredImageGenerationProvider();
      final models = await provider.listModels(profile.apiKey);
      if (mounted) setState(() => _models = models);
    } on ImageGenerationFailure catch (failure) {
      if (mounted) setState(() {
        _models = const [];
        _error = failure.message;
      });
    } catch (_) {
      if (mounted) setState(() {
        _models = const [];
        _error = 'Impossible de récupérer les modèles graphiques.';
      });
    } finally {
      if (mounted) setState(() => _loadingModels = false);
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
      final next = _options.copyWith(style: _style.text.trim());
      next.validate();
      if (_imageProfile == null || _selectedModel == null ||
          !(_selectedModel!.sizes.contains(next.size)) ||
          next.count > _selectedModel!.maximumImages ||
          (next.quality != null &&
              !_selectedModel!.qualities.contains(next.quality))) {
        throw const FormatException('Sélectionnez un modèle et des options valides.');
      }
      if (next.directorProfileId.isEmpty ||
          !widget.ai.profiles.any((p) => p.id == next.directorProfileId)) {
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
          'Enregistrement impossible : contrôlez profil, modèle et format.');
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
          _style.text = _options.style;
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
    final formats = model?.sizes ?? const <String>[];
    final quality = _options.quality ?? 'auto';
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (widget.showBackButton)
          Align(alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: widget.onBack, icon: const Icon(Icons.arrow_back),
              label: const Text('Retour'))),
        const Text('Génération d’images',
          style: TextStyle(color: DomoliaColors.goldLight,
              fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('Le narrateur et le générateur graphique sont indépendants. '
          'Un compte ChatGPT connecté ne donne pas accès à l’API Images : '
          'utilisez un profil API avec votre propre clé facturable.'),
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
            key: const ValueKey('imageProviderProfile'),
            value: _imageProfile?.id,
            decoration: const InputDecoration(labelText: 'Profil graphique'),
            items: [
              for (final p in widget.ai.profiles)
                if (_supportsImages(p))
                  DropdownMenuItem(value: p.id, child: Text(p.name)),
            ],
            onChanged: !_canEdit ? null : (id) {
              if (id == null) return;
              setState(() {
                _options = _options.copyWith(
                    profileId: id, model: '', clearQuality: true,
                    size: '1024x1024', count: 1);
                _models = const [];
              });
              _loadModels();
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const ValueKey('imageDirectorProfile'),
            value: widget.ai.profiles.any(
                (p) => p.id == _options.directorProfileId)
                ? _options.directorProfileId : null,
            decoration: const InputDecoration(labelText: 'Metteur en scène IA'),
            items: [
              for (final p in widget.ai.profiles)
                DropdownMenuItem(value: p.id, child: Text(p.name)),
            ],
            onChanged: !_canEdit ? null : (id) {
              if (id != null) setState(() => _options =
                  _options.copyWith(directorProfileId: id));
            },
          ),
          const SizedBox(height: 12),
          if (_loadingModels) const LinearProgressIndicator(),
          DropdownButtonFormField<String>(
            key: const ValueKey('imageModel'),
            value: model?.id,
            decoration: const InputDecoration(labelText: 'Modèle graphique'),
            items: [
              for (final m in _models)
                DropdownMenuItem(value: m.id, child: Text(m.id)),
            ],
            onChanged: !_canEdit ? null : (id) {
              if (id == null) return;
              setState(() => _options = _options.copyWith(
                model: id, size: '1024x1024', count: 1, clearQuality: true));
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const ValueKey('imageSize'),
            value: formats.contains(_options.size) ? _options.size : null,
            decoration: const InputDecoration(labelText: 'Format / ratio'),
            items: [
              for (final size in formats)
                DropdownMenuItem(value: size, child: Text(size)),
            ],
            onChanged: !_canEdit ? null : (size) {
              if (size != null) setState(() =>
                  _options = _options.copyWith(size: size));
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const ValueKey('imageQuality'),
            value: quality == 'auto' ||
                (model?.qualities.contains(quality) ?? false) ? quality : 'auto',
            decoration: const InputDecoration(labelText: 'Qualité'),
            items: [
              const DropdownMenuItem(value: 'auto', child: Text('Par défaut')),
              for (final option in model?.qualities ?? const <String>[])
                DropdownMenuItem(value: option, child: Text(option)),
            ],
            onChanged: !_canEdit ? null : (selected) {
              setState(() => _options = _options.copyWith(
                quality: selected, clearQuality: selected == 'auto'));
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            key: const ValueKey('imageCount'),
            value: _options.count <= (model?.maximumImages ?? 1)
                ? _options.count : 1,
            decoration: const InputDecoration(labelText: 'Nombre d’images'),
            items: [
              for (var count = 1; count <= (model?.maximumImages ?? 1); count++)
                DropdownMenuItem(value: count, child: Text('$count')),
            ],
            onChanged: !_canEdit ? null : (count) {
              if (count != null) setState(() =>
                  _options = _options.copyWith(count: count));
            },
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('imageStyle'),
            controller: _style, enabled: _canEdit, maxLength: 160,
            decoration: const InputDecoration(labelText: 'Style graphique'),
          ),
          const SizedBox(height: 6),
          const Text('Coût avant génération : inconnu. Les tarifs catalogue '
              'ne sont pas des plafonds garantis. Aucune génération '
              'n’est lancée sans confirmation.'),
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
