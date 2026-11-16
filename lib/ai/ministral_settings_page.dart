import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../theme/domolia_theme.dart';
import 'ai_provider.dart';
import 'ministral_local_provider.dart';
import 'ministral_model_manager.dart';

/// User-controlled model replacement, never a background installation.
/// The active model is removed only after explicit confirmation.
class MinistralSettingsPage extends StatefulWidget {
  const MinistralSettingsPage({
    super.key,
    required this.models,
    required this.provider,
    required this.onBack,
    this.canChangeModel,
    this.showBackButton = true,
  });

  final MinistralModelManager models;
  final MinistralLocalProvider provider;
  final VoidCallback onBack;
  final bool Function()? canChangeModel;
  final bool showBackButton;

  @override
  State<MinistralSettingsPage> createState() => _MinistralSettingsPageState();
}

class _MinistralSettingsPageState extends State<MinistralSettingsPage> {
  String _selected = ministralVariants.first.id;
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
      if (mounted) {
        setState(() {
          _selected = widget.models.installedId ?? ministralVariants.first.id;
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

  Future<void> _install() async {
    if (!_canModify) return;
    final variant = ministralVariants.firstWhere((v) => v.id == _selected);
    if (widget.models.installedId == variant.id && widget.models.ready) {
      _notice('Ce modèle est déjà installé.');
      return;
    }
    final ok = await _confirm(
      'Remplacer le modèle IA local ?',
      'Le modèle actuellement installé sera désinstallé pour libérer '
      'de la place. Domolia téléchargera ensuite ${variant.name}.\n\n'
      'Le fichier fait environ ${(variant.bytes / 1000000000).toStringAsFixed(2)} Go. '
      'Le téléchargement peut prendre un moment : privilégiez le Wi-Fi et '
      'gardez Domolia ouvert. Si l’installation échoue, le mode local restera '
      'désactivé. Aucun appel IA payant ne sera lancé automatiquement.',
      'Désinstaller et télécharger',
    );
    if (!ok || !mounted || !_canModify) return;
    setState(() { _working = true; _benchmark = null; });
    try {
      await widget.provider.unload();
      await widget.models.install(variant);
      await widget.models.setEnabled(true);
      _notice('Ministral installé : narrateur local activé.');
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
    final ok = await _confirm('Supprimer le modèle Ministral ?',
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
        MinistralLocalProvider.configuration,
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
          : 'Ministral ne peut pas générer sur ce téléphone. '
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
      final selected = ministralVariants.firstWhere((v) => v.id == _selected);
      return SafeArea(
        child: ListView(
          key: const ValueKey('ministralSettings'),
          padding: const EdgeInsets.all(24),
          children: [
            Row(children: [
              if (widget.showBackButton)
                IconButton(onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back)),
              const Expanded(child: Text('IA locale — Mistral',
                style: TextStyle(color: DomoliaColors.goldLight,
                    fontSize: 23, fontWeight: FontWeight.bold))),
            ]),
            const SizedBox(height: 16),
            const Text('Narrateur directement sur Android : aucune clé API, '
                'aucun token facturé. Le téléchargement initial exige Internet. '
                'Une fois installé, l’inférence reste sur le téléphone.'),
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              key: ValueKey('ministralSelected-$_selected'),
              initialValue: _selected,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Modèle Mistral'),
              items: [
                for (final variant in ministralVariants)
                  DropdownMenuItem(value: variant.id,
                    child: Text(variant.name, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: _canModify ? (value) {
                if (value != null) setState(() => _selected = value);
              } : null,
            ),
            const SizedBox(height: 12),
            Text('Téléchargement : ${(selected.bytes / 1000000000).toStringAsFixed(2)} Go. '
                 'La RAM requise est supérieure à la taille du fichier. '
                 'Sur un S20 FE 6 Go, commencez par Q4.',
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
                key: const ValueKey('ministralInstall'),
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
              key: const ValueKey('ministralEnabled'),
              title: const Text('Narrateur entièrement local'),
              subtitle: const Text('Le JSONificateur et la mémoire utilisent '
                  'aussi Ministral. En cas d’erreur, aucun secours distant '
                  'automatique : la Partie reste sauvegardée.'),
              value: models.ready && models.enabled,
              onChanged: models.ready && _canModify ? _toggle : null,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('ministralQuickTest'),
              onPressed: models.ready && _canModify
                  ? () => _test(quick: true)
                  : null,
              icon: const Icon(Icons.bug_report_outlined),
              label: const Text('Diagnostic rapide (24 tokens)'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('ministralTest'),
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
            const Text('Ministral 3 3B Instruct est publié par Mistral AI '
                '(licence Apache 2.0). La compatibilité NSFW n’est pas '
                'garantie : aucun filtrage applicatif supplémentaire n’est '
                'introduit ici, mais le modèle peut refuser certaines scènes. '
                'Les performances et la qualité narrative doivent être '
                'mesurées sur le téléphone.',
              style: TextStyle(color: DomoliaColors.muted)),
          ],
        ),
      );
    },
  );
}
