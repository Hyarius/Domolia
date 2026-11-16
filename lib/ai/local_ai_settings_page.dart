import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../theme/domolia_theme.dart';
import 'ai_provider.dart';
import 'local_ai_provider.dart';
import 'local_model_manager.dart';
import 'local_model_catalog.dart';
import 'local_inference_options.dart';

/// User-controlled model replacement, never a background installation.
/// The active model is removed only after explicit confirmation.
class LocalAiSettingsPage extends StatefulWidget {
  const LocalAiSettingsPage({
    super.key,
    required this.models,
    required this.provider,
    required this.onBack,
    this.canChangeModel,
    this.showBackButton = true,
  });

  final LocalModelManager models;
  final LocalAiProvider provider;
  final VoidCallback onBack;
  final bool Function()? canChangeModel;
  final bool showBackButton;

  @override
  State<LocalAiSettingsPage> createState() => _LocalAiSettingsPageState();
}

class _LocalAiSettingsPageState extends State<LocalAiSettingsPage> {
  String _selected = localModelVariants.first.id;
  LocalInferenceOptions _options = const LocalInferenceOptions();
  bool _working = false;
  String? _benchmark;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await widget.models.initialize();
      final options = await LocalInferenceOptions.load();
      if (mounted) {
        setState(() {
          _selected = widget.models.installedId ?? localModelVariants.first.id;
          _options = options;
        });
      }
    } catch (_) {
      _notice('Impossible de lire les modèles installés.');
    }
  }

  void _notice(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  bool get _canModify => !_working && !widget.models.installing &&
      (widget.canChangeModel?.call() ?? true);

  Future<bool> _confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(action),
            ),
          ],
        ),
      ) ?? false;

  Future<void> _saveInferenceOptions(LocalInferenceOptions next) async {
    if (!_canModify) return;
    setState(() => _working = true);
    try {
      // A running inference must finish before changing its native settings.
      await widget.provider.unload();
      await next.save();
      if (mounted) setState(() => _options = next);
      _notice('Réglages IA locale enregistrés : prochain chargement du modèle.');
    } catch (_) {
      _notice('Impossible de modifier les réglages CPU/GPU.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _install() async {
    if (!_canModify) return;
    final variant = localModelVariants.firstWhere((v) => v.id == _selected);
    if (widget.models.installedId == variant.id && widget.models.ready) {
      _notice('Ce modèle est déjà installé.');
      return;
    }
    final ok = await _confirm(
      'Remplacer le modèle IA local ?',
      'Domolia téléchargera ${variant.name} et vérifiera son intégrité. '
      'Le modèle actuellement installé sera conservé jusqu’au succès '
      'du téléchargement, puis supprimé.\n\n'
      'Prévoyez environ ${(variant.bytes / 1000000000).toStringAsFixed(2)} Go '
      'd’espace libre supplémentaire. Privilégiez le Wi-Fi et gardez '
      'Domolia ouvert. En cas d’échec, l’ancien modèle reste disponible '
      'mais le mode local doit être réactivé manuellement. '
      'Aucun appel IA payant n’est lancé en secours automatique.',
      'Confirmer le téléchargement',
    );
    if (!ok || !mounted || !_canModify) return;
    setState(() { _working = true; _benchmark = null; });
    try {
      await widget.provider.unload();
      await widget.models.install(variant);
      await widget.models.setEnabled(true);
      _notice('Modèle installé : narration locale activée.');
    } catch (_) {
      _notice(widget.models.error ?? 'Installation du modèle interrompue.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _toggle(bool enabled) async {
    if (!_canModify) return;
    try {
      await widget.models.setEnabled(enabled);
      _notice(enabled ? 'Narrateur local activé.' : 'Narrateur distant réactivé.');
    } catch (_) {
      _notice('Impossible de modifier le mode du narrateur.');
    }
  }

  Future<void> _remove() async {
    if (!_canModify || !widget.models.ready) return;
    final ok = await _confirm('Supprimer le modèle local ?',
      'Le modèle sera supprimé du téléphone. Les Livres et les Parties '
      'ne seront pas touchés.', 'Supprimer');
    if (!ok || !mounted || !_canModify) return;
    setState(() => _working = true);
    try {
      await widget.provider.unload();
      await widget.models.remove();
      _notice('Modèle local supprimé.');
    } catch (_) {
      _notice('Impossible de supprimer le modèle.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _test({bool quick = false}) async {
    if (!_canModify || !widget.models.ready) return;
    setState(() { _working = true; _benchmark = null; });
    final watch = Stopwatch()..start();
    try {
      final result = await widget.provider.complete(
        LocalAiProvider.configurationFor(widget.models.installedVariant!),
        maxTokens: quick ? 24 : 240,
        messages: quick
            ? const [
                AiMessage(role: 'user',
                    content: 'Réponds en français par un bonjour très court.'),
              ]
            : const [
                AiMessage(role: 'system', content:
                    'Tu écris de courtes scènes de jeu de rôle en français. '
                    'N’agis jamais à la place du joueur.'),
                AiMessage(role: 'user', content:
                    'La pluie tombe sur la vitre de l’auberge du Pont de Verre. '
                    'Décris une courte interaction avec l’aubergiste Oren.'),
              ],
      );
      watch.stop();
      if (mounted) {
        setState(() => _benchmark =
          '${quick ? "Diagnostic rapide" : "Génération hors connexion"} : ${watch.elapsed.inSeconds} s\n\n'
          '${result.trim()}');
      }
    } catch (failure) {
      _notice(failure is AiProviderException
          ? failure.userMessage
          : 'Le modèle local ne peut pas générer sur ce téléphone. '
            'Vérifiez la mémoire disponible.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.models,
    builder: (context, _) {
      final models = widget.models;
      final selected = localModelVariants.firstWhere((v) => v.id == _selected);
      return SafeArea(
        child: ListView(
          key: const ValueKey('localModelSettings'),
          padding: const EdgeInsets.all(24),
          children: [
            Row(children: [
              if (widget.showBackButton)
                IconButton(onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back)),
              const Expanded(child: Text('IA locale — Modèles',
                style: TextStyle(color: DomoliaColors.goldLight,
                    fontSize: 23, fontWeight: FontWeight.bold))),
            ]),
            const SizedBox(height: 16),
            const Text('Narrateur directement sur Android : aucune clé API, '
                'aucun token facturé. Le téléchargement initial exige Internet. '
                'Une fois installé, l’inférence reste sur le téléphone.'),
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              key: ValueKey('localSelected-$_selected'),
              initialValue: _selected,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Modèle local'),
              items: [
                for (final variant in localModelVariants)
                  DropdownMenuItem(value: variant.id,
                    child: Text(variant.name, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: _canModify ? (value) {
                if (value != null) setState(() => _selected = value);
              } : null,
            ),
            const SizedBox(height: 20),
            const Text('Performances du moteur local',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: ValueKey('localCpuThreads-${_options.threads}'),
              initialValue: _options.threads,
              decoration: const InputDecoration(labelText: 'Threads CPU'),
              items: [
                DropdownMenuItem(value: 0,
                    child: Text('Tous les cœurs logiques disponibles '
                        '(${_options.effectiveThreads()})')),
                const DropdownMenuItem(value: 2, child: Text('2 threads')),
                const DropdownMenuItem(value: 4, child: Text('4 threads')),
              ],
              onChanged: _canModify ? (value) {
                if (value != null) {
                  unawaited(_saveInferenceOptions(
                      _options.copyWith(threads: value)));
                }
              } : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<LocalGpuMode>(
              key: ValueKey('localGpuMode-${_options.gpuMode.name}'),
              initialValue: _options.gpuMode,
              decoration: const InputDecoration(labelText: 'Accélération GPU'),
              items: const [
                DropdownMenuItem(value: LocalGpuMode.automatic,
                    child: Text('Automatique (Vulkan si disponible)')),
                DropdownMenuItem(value: LocalGpuMode.cpuOnly,
                    child: Text('CPU uniquement')),
              ],
              onChanged: _canModify ? (value) {
                if (value != null) {
                  unawaited(_saveInferenceOptions(
                      _options.copyWith(gpuMode: value)));
                }
              } : null,
            ),
            const SizedBox(height: 8),
            Text(LocalAiProvider.vulkanBackendBuilt
                ? 'Backend Vulkan inclus. Le pilote et les couches GPU seront '
                  'détectés au chargement. Un échec de chargement GPU entraîne '
                  'une tentative sur CPU.'
                : 'Cet APK est compilé sans backend Vulkan : le CPU sera '
                  'utilisé quel que soit le réglage.',
              style: const TextStyle(color: DomoliaColors.muted)),
            const SizedBox(height: 8),
            const Text('Tous les threads n’est pas toujours plus rapide : '
                'comparer 2, 4 et tous pour observer la chauffe et la latence.',
              style: TextStyle(color: DomoliaColors.muted)),
            const SizedBox(height: 12),
            Text('Téléchargement : ${(selected.bytes / 1000000000).toStringAsFixed(2)} Go. '
                 'La RAM requise est supérieure à la taille du fichier. '
                 'Sur un S20 FE 6 Go, commencez par Qwen Q4.',
              style: const TextStyle(color: DomoliaColors.muted)),
            const SizedBox(height: 18),
            if (models.installing) ...[
              LinearProgressIndicator(value: models.progress),
              const SizedBox(height: 8),
              Text('Téléchargé : ${(models.downloadedBytes / 1000000).toStringAsFixed(0)} Mo '
                  '/ ${(selected.bytes / 1000000).toStringAsFixed(0)} Mo'),
              OutlinedButton(onPressed: models.cancelInstallation,
                  child: const Text('Annuler le téléchargement')),
            ] else
              FilledButton.icon(
                key: const ValueKey('localModelInstall'),
                onPressed: _canModify ? _install : null,
                icon: const Icon(Icons.download_rounded),
                label: Text(models.installedId == _selected && models.ready
                    ? 'Modèle déjà installé'
                    : 'Valider et télécharger ce modèle'),
              ),
            if (models.error != null) ...[
              const SizedBox(height: 8),
              Text(models.error!,
                  style: const TextStyle(color: Colors.orangeAccent)),
            ],
            const Divider(height: 36),
            Text(models.ready
                ? 'Modèle installé : ${models.installedVariant!.name}'
                : 'Aucun modèle installé'),
            SwitchListTile(
              key: const ValueKey('localModelEnabled'),
              title: const Text('Narrateur entièrement local'),
              subtitle: const Text('Le JSONificateur et la mémoire utilisent '
                  'aussi le modèle choisi. En cas d’erreur, aucun secours distant '
                   'automatique : la Partie reste sauvegardée.'),
              value: models.ready && models.enabled,
              onChanged: models.ready && _canModify ? _toggle : null,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('localModelQuickTest'),
              onPressed: models.ready && _canModify
                  ? () => _test(quick: true)
                  : null,
              icon: const Icon(Icons.bug_report_outlined),
              label: const Text('Diagnostic rapide (24 tokens)'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('localModelTest'),
              onPressed: models.ready && _canModify ? () => _test() : null,
              icon: const Icon(Icons.science_outlined),
              label: const Text('Tester la narration sur ce téléphone'),
            ),
            if (_working && !models.installing)
              const Padding(padding: EdgeInsets.all(12),
                child: LinearProgressIndicator()),
            if (_benchmark != null)
              Padding(padding: const EdgeInsets.symmetric(vertical: 12),
                child: SelectableText(_benchmark!)),
            TextButton.icon(
              onPressed: models.ready && _canModify ? _remove : null,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Désinstaller le modèle local'),
            ),
            const SizedBox(height: 18),
            const Text('Qwen2.5 1.5B et Ministral 3B sont des modèles '
                'distincts, publiés sous licence Apache 2.0. '
                'Le mode NSFW des Livres est conservé, sans filtre '
                'supplémentaire dans le moteur local. Les modèles standards '
                'peuvent toutefois refuser des scènes adultes. '
                'Comparez la qualité, la vitesse et les refus sur le téléphone. '
                'L’accélération GPU n’est pas encore activée.',
              style: TextStyle(color: DomoliaColors.muted)),
          ],
        ),
      );
    },
  );
}
