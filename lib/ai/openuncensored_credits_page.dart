import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/domolia_theme.dart';
import 'ai_task_generation.dart';
import 'openuncensored_api.dart';
import 'openuncensored_controller.dart';
import 'openuncensored_vault.dart';
import 'openuncensored_simulation.dart';

/// Payments are hosted by Stripe; no card number ever enters Domolia.
class OpenUncensoredCreditsPage extends StatefulWidget {
  const OpenUncensoredCreditsPage({
    super.key,
    required this.controller,
    required this.onBack,
    this.showBackButton = true,
    this.onOpenLocalAi,
    this.sandbox,
  });
  final OuCreditsController controller;
  final VoidCallback onBack;
  final bool showBackButton;
  final VoidCallback? onOpenLocalAi;
  final OpenUncensoredSandbox? sandbox;

  @override
  State<OpenUncensoredCreditsPage> createState() =>
      _OpenUncensoredCreditsPageState();
}

class _OpenUncensoredCreditsPageState extends State<OpenUncensoredCreditsPage>
    with WidgetsBindingObserver {
  int _amount = 1000;
  Timer? _poller;
  int _pollCount = 0;
  bool _checking = false;
  Map<String, String> _advanced = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    if (widget.sandbox != null) {
      await widget.sandbox!.initialize();
    } else {
      await widget.controller.initialize();
    }
    if (!mounted) return;
    _advanced = Map.of(widget.controller.taskModels);
    if (widget.controller.pending != null) {
      await _check();
      _startPoller();
    } else if (widget.controller.active != null) {
      unawaited(widget.controller.refresh(widget.controller.active!.id));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        widget.controller.pending != null) {
      unawaited(_check());
      _startPoller();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _stopPoller();
    }
  }

  void _startPoller() {
    if (widget.controller.pending == null || _poller != null ||
        kIsWeb || widget.sandbox != null) {
      return;
    }
    _pollCount = 0;
    _poller = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || widget.controller.pending == null || ++_pollCount > 24) {
        _stopPoller();
      } else {
        unawaited(_check());
      }
    });
  }

  void _stopPoller() {
    _poller?.cancel();
    _poller = null;
  }

  Future<void> _check() async {
    if (_checking || widget.controller.pending == null) return;
    _checking = true;
    try {
      await widget.controller.checkPending();
      if (widget.controller.pending == null) _stopPoller();
    } finally {
      _checking = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPoller();
    super.dispose();
  }

  Future<bool> _confirm(String title, String explanation) async {
    if (!mounted) return false;
    return await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(explanation),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirmer')),
        ],
      ),
    ) ?? false;
  }

  Future<void> _probeNarrator(String modelId) async {
    if (widget.sandbox != null) return;
    final accepted = await _confirm('Tester le Tool Calling ?',
      'Un court appel IA sera envoyé à OpenUncensored avec la clé active '
      'et pourra consommer des crédits. Aucun outil réel ne sera exécuté. '
      'Un résultat sans appel de fonction reste « non concluant ».');
    if (!accepted || !mounted) return;
    await widget.controller.testToolCalling(modelId);
  }

  String _toolStatus(String modelId) {
    final result = widget.controller.probeFor(modelId);
    if (result == OuToolProbeOutcome.inconclusive) {
      return 'Test effectué : non concluant. La compatibilité reste inconnue.';
    }
    final suffix = result == null ? ' (catalogue)' : ' (test réel)';
    return switch (widget.controller.toolSupportFor(modelId)) {
      OuToolSupport.supported => 'Tool Calling compatible$suffix.',
      OuToolSupport.unsupported => 'Tool Calling incompatible$suffix.',
      OuToolSupport.unknown =>
          'Compatibilité inconnue : modèle utilisable sans outils.',
    };
  }

  Future<void> _payment({String? target}) async {
    if (kIsWeb) return;
    final url = await widget.controller.startCheckout(_amount, topUpKeyId: target);
    if (url == null || !mounted) return;
    if (widget.sandbox != null) return; // Never launch a sandbox payment URL.
    var opened = false;
    try {
      opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Impossible d’ouvrir Stripe. Reprenez le paiement depuis cette page.')));
    }
    _startPoller();
  }

  void _openSandbox() {
    final sandbox = OpenUncensoredSandbox();
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (ctx) => Scaffold(body: OpenUncensoredCreditsPage(
        controller: sandbox.controller,
        sandbox: sandbox,
        onBack: () => Navigator.of(ctx).pop(),
      )),
    )).whenComplete(sandbox.dispose);
  }

  Future<void> _simulate(OuCheckoutStatus outcome) async {
    final sandbox = widget.sandbox;
    if (sandbox == null || widget.controller.pending == null) return;
    sandbox.api.selectOutcome(outcome);
    await _check();
  }

  Future<void> _import() async {
    final input = TextEditingController();
    final key = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Importer une clé existante'),
        content: TextField(
          key: const ValueKey('ouImportKey'),
          controller: input, obscureText: true,
          enableSuggestions: false, autocorrect: false,
          decoration: const InputDecoration(labelText: 'Clé OpenUncensored',
            hintText: 'ou-…')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, input.text.trim()),
            child: const Text('Vérifier')),
        ],
      ),
    );
    input.dispose();
    if (key == null || !mounted) return;
    if (!validOpenUncensoredKey(key)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Format de clé invalide.')));
      return;
    }
    OuBalance balance;
    try {
      balance = await widget.controller.api.balance(key);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Impossible de vérifier cette clé. Rien n’a été modifié.')));
      }
      return;
    }
    if (!mounted) return;
    final accepted = await _confirm('Remplacer la clé active ?',
      'Solde vérifié : ${_usd(balance.remainingUsd)}. '
      'Les crédits de votre ancienne clé restent sur celle-ci et ne sont pas transférés. '
      'Toutes les clés restent dans votre historique sécurisé.');
    if (accepted) await widget.controller.importKey(key);
  }

  Future<void> _activate(StoredOuKey key) async {
    // Obtain a current balance before asking for confirmation.
    await widget.controller.refresh(key.id);
    if (!mounted || widget.controller.error != null) return;
    final updated = widget.controller.keys.firstWhere((item) => item.id == key.id);
    final approved = await _confirm('Activer cette clé ?',
      'Solde : ${_usd(updated.lastBalance?.remainingUsd)}. '
      'Les crédits ne sont pas transférables entre les clés.');
    if (approved) await widget.controller.activate(key.id);
  }

  Future<void> _showKey(String id) async {
    if (!await _confirm('Afficher la clé privée ?',
        'Quiconque possède cette clé peut dépenser ses crédits. '
        'Évitez les captures d’écran et ne la partagez pas.')) {
      return;
    }
    final key = widget.controller.revealKey(id);
    if (!mounted || key == null) return;
    await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Votre clé OpenUncensored'),
      content: SelectableText(key),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx),
          child: const Text('Masquer')),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: key));
            if (ctx.mounted) Navigator.pop(ctx);
          },
          icon: const Icon(Icons.copy), label: const Text('Copier')),
      ],
    ));
  }

  Future<void> _rename(StoredOuKey key) async {
    final input = TextEditingController(text: key.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Renommer la clé'),
        content: TextField(controller: input, maxLength: 48,
          decoration: const InputDecoration(labelText: 'Nom local')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, input.text),
            child: const Text('Enregistrer')),
        ],
      ),
    );
    input.dispose();
    if (name != null) await widget.controller.rename(key.id, name);
  }

  String _usd(double? balance) =>
      balance == null ? 'Non vérifié' : '${balance.toStringAsFixed(2)} USD';

  Widget _keyCard(StoredOuKey item, bool active) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(item.displayName,
            style: const TextStyle(fontWeight: FontWeight.w700),
            overflow: TextOverflow.ellipsis)),
          if (active) const Text('ACTIVE', style: TextStyle(color: DomoliaColors.gold)),
        ]),
        if (item.name.isNotEmpty) Text(item.masked),
        const SizedBox(height: DomoliaSpacing.compact),
        Text('Solde : ${_usd(item.lastBalance?.remainingUsd)}'),
        Text('Dernière vérification : ${item.lastChecked?.toLocal().toString().split(".").first ?? "Jamais"}',
          style: const TextStyle(color: DomoliaColors.muted)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          TextButton(onPressed: widget.controller.busy ? null :
            () => widget.controller.refresh(item.id),
            child: const Text('Actualiser')),
          if (!active) TextButton(onPressed: widget.controller.busy ? null :
            () => _activate(item), child: const Text('Activer')),
          TextButton(onPressed: widget.controller.busy || kIsWeb ? null :
            () => _payment(target: item.id), child: const Text('Recharger')),
          TextButton(onPressed: widget.controller.busy ? null :
            () => _showKey(item.id), child: const Text('Afficher')),
          TextButton(onPressed: widget.controller.busy ? null :
            () => _rename(item), child: const Text('Renommer')),
        ]),
      ]),
    ),
  );

  Widget _models() {
    final controller = widget.controller;
    final enabled = controller.active != null && !controller.busy;
    final options = controller.catalogue;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Qualité narrative', style: TextStyle(
        color: DomoliaColors.goldLight, fontSize: 18)),
      const SizedBox(height: DomoliaSpacing.field),
      DropdownButtonFormField<OuQuality>(
        key: ValueKey('ouPreset-${controller.quality.name}'),
        initialValue: controller.quality == OuQuality.advanced ?
            null : controller.quality,
        hint: controller.quality == OuQuality.advanced
            ? const Text('Avancé (personnalisé)') : null,
        decoration: const InputDecoration(labelText: 'Préréglage'),
        items: const [
          DropdownMenuItem(value: OuQuality.economical,
            child: Text('Économique')),
          DropdownMenuItem(value: OuQuality.balanced,
            child: Text('Équilibré')),
          DropdownMenuItem(value: OuQuality.quality,
            child: Text('Qualité')),
        ],
        onChanged: !enabled ? null : (value) {
          if (value != null) unawaited(controller.setPreset(value));
        },
      ),
      const SizedBox(height: DomoliaSpacing.compact),
      const Text('Le mode Économique désactive l’optimiseur facultatif. '
        'Les prix et modèles sont consultés auprès du fournisseur.',
        style: TextStyle(color: DomoliaColors.muted)),
      const SizedBox(height: DomoliaSpacing.field),
      OutlinedButton(onPressed: controller.busy ? null : () async {
        await controller.loadModels();
        if (mounted) {
          setState(() {
            _advanced = Map.of(controller.taskModels);
          });
        }
      }, child: const Text('Actualiser les modèles')),
      const SizedBox(height: DomoliaSpacing.compact),
      ExpansionTile(title: const Text('Modèles avancés'), children: [
        if (options.isEmpty) const Padding(
          padding: EdgeInsets.all(12),
          child: Text('Chargez le catalogue pour afficher les modèles disponibles.')),
        for (final task in ['narrator', 'jsonifier', 'optimizer'])
          Builder(builder: (context) {
            final eligible = options;
            final selected = _advanced[task];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              child: eligible.isEmpty ?
                Text('Aucun modèle disponible pour $task')
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownButtonFormField<String>(
                      key: ValueKey('ouAdvanced-$task-${selected ?? ""}'),
                      initialValue: eligible.any((m) => m.id == selected)
                          ? selected : null,
                      isExpanded: true,
                      decoration: InputDecoration(labelText: switch (task) {
                        'narrator' => 'Narrateur RAW',
                        'jsonifier' => 'JSONificateur',
                        _ => 'Optimiseur de Lore',
                      }),
                      items: [
                        for (final model in eligible)
                          DropdownMenuItem(value: model.id,
                            child: Text(model.id,
                                overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: !enabled ? null : (id) {
                        if (id != null) setState(() => _advanced[task] = id);
                      },
                    ),
                    if (task == 'narrator' && selected != null &&
                        eligible.any((m) => m.id == selected)) ...[
                      const SizedBox(height: DomoliaSpacing.compact),
                      Text(_toolStatus(selected),
                        key: const ValueKey('ouToolStatus'),
                        style: const TextStyle(color: DomoliaColors.muted)),
                      const SizedBox(height: DomoliaSpacing.compact),
                      OutlinedButton.icon(
                        key: const ValueKey('ouToolProbe'),
                        onPressed: !enabled || widget.sandbox != null
                            ? null : () => _probeNarrator(selected),
                        icon: const Icon(Icons.science_outlined),
                        label: const Text('Tester le Tool Calling'),
                      ),
                      const Text('Test facultatif et potentiellement facturé. '
                        'Un modèle non vérifié reste disponible pour '
                        'la narration classique.',
                        style: TextStyle(color: DomoliaColors.muted)),
                    ],
                  ],
                ),
            );
          }),
        const SizedBox(height: DomoliaSpacing.field),
        FilledButton(
          onPressed: !enabled || !['narrator','jsonifier','optimizer']
            .every((task) => _advanced.containsKey(task)) ? null :
            () => controller.setAdvanced(_advanced),
          child: const Text('Appliquer les modèles avancés'),
        ),
      ]),
      const SizedBox(height: DomoliaSpacing.section),
      const Divider(),
      const SizedBox(height: DomoliaSpacing.compact),
      const Text('Limites de génération', style: TextStyle(
        color: DomoliaColors.goldLight, fontSize: 17)),
      const SizedBox(height: DomoliaSpacing.field),
      for (final task in AiNarrativeTask.values) ...[
        DropdownButtonFormField<int>(
          key: ValueKey('ouTokens-${task.name}'),
          initialValue: controller.routing.generationFor(task).maxOutputTokens,
          decoration: InputDecoration(labelText: switch (task) {
            AiNarrativeTask.narrator => 'Narrateur RAW',
            AiNarrativeTask.jsonifier => 'JSONificateur',
            AiNarrativeTask.optimizer => 'Optimiseur de Lore',
            AiNarrativeTask.memory => 'Extracteur de mémoire',
          }),
          items: [
            for (final count in AiTaskGenerationSettings.tokenChoices)
              DropdownMenuItem(value: count, child: Text('$count tokens')),
          ],
          onChanged: !enabled ? null : (count) async {
            if (count != null) {
              final previous = controller.routing.generationFor(task);
              await controller.routing.setGeneration(task,
                AiTaskGenerationSettings(
                  maxOutputTokens: count,
                  reasoningEffort: previous.reasoningEffort,
                ));
            }
          },
        ),
        const SizedBox(height: DomoliaSpacing.field),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final active = controller.active;
      return SafeArea(child: ListView(
        key: const ValueKey('ouCreditsPage'),
        padding: const EdgeInsets.all(20),
        children: [
          Row(children: [
            if (widget.showBackButton)
               IconButton(onPressed: widget.onBack,
              icon: const Icon(Icons.arrow_back)),
            const Expanded(child: Text('Crédits IA', style: TextStyle(
              color: DomoliaColors.goldLight, fontSize: 24,
              fontWeight: FontWeight.bold))),
          ]),
          const SizedBox(height: 16),
          if (widget.onOpenLocalAi != null) ...[
            OutlinedButton.icon(
              key: const ValueKey('creditsOpenLocalAi'),
              onPressed: widget.onOpenLocalAi,
              icon: const Icon(Icons.smartphone_outlined),
              label: const Text('IA locale Mistral — 0 token payant'),
            ),
            const SizedBox(height: 16),
          ],
          if (widget.sandbox != null) ...[
            const Text('SIMULATION — aucun paiement ni appel IA réel.',
              style: TextStyle(color: Colors.orangeAccent,
                fontWeight: FontWeight.bold)),
            const SizedBox(height: DomoliaSpacing.compact),
            const Text('Les clés ou-demo- et leurs soldes sont fictifs. '
              'Ils sont conservés séparément de vos vraies clés.'),
          ] else ...[
            const Text('Fournisseur : OpenUncensored'),
            if (openUncensoredSimulationEnabled) ...[
              const SizedBox(height: DomoliaSpacing.field),
              OutlinedButton.icon(
                key: const ValueKey('ouOpenSandbox'),
                onPressed: _openSandbox,
                icon: const Icon(Icons.science_outlined),
                label: const Text('Tester les paiements sans payer'),
              ),
            ],
          ],
          if (!controller.ready || controller.busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: DomoliaSpacing.compact),
              child: LinearProgressIndicator(),
            ),
          if (controller.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: DomoliaSpacing.compact),
              child: Row(children: [
                const Icon(Icons.error_outline, color: Colors.orangeAccent),
                const SizedBox(width: DomoliaSpacing.compact),
                Expanded(child: Text(controller.error!,
                  style: const TextStyle(color: Colors.orangeAccent))),
              ]),
            ),
          if (controller.notice != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: DomoliaSpacing.compact),
              child: Text(controller.notice!,
                style: const TextStyle(color: DomoliaColors.goldLight)),
            ),
          if (kIsWeb) const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Les achats intégrés ne sont pas disponibles dans le '
              'navigateur. Utilisez l’application Android pour recharger '
              'des crédits. Les clés du navigateur restent locales.')),
          if (active == null)
            const Padding(padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Aucune clé active. Achetez des crédits ou importez votre clé.')),
          if (active != null) ...[
            const SizedBox(height: 12),
            Text('Solde disponible : ${_usd(active.lastBalance?.remainingUsd)}',
              style: const TextStyle(fontSize: 22, color: DomoliaColors.goldLight)),
            if (active.lastBalance != null)
              Text('Consommation en attente : ${_usd(active.lastBalance!.pendingUsd)}'),
            Text('Actualisé : ${active.lastChecked?.toLocal().toString().split(".").first ?? "Jamais"}'),
            const SizedBox(height: DomoliaSpacing.compact),
            OutlinedButton(onPressed: controller.busy ? null :
              () => controller.refresh(active.id),
              child: const Text('Actualiser le solde')),
          ],
          const Divider(),
          const SizedBox(height: DomoliaSpacing.compact),
          const Text('Acheter des crédits', style: TextStyle(
            color: DomoliaColors.goldLight, fontSize: 18)),
          Text(widget.sandbox != null
            ? 'Montants et soldes fictifs. Aucun paiement ne sera lancé.'
            : 'Montants en USD avant taxes éventuelles. '
              'Le prix affiché dans Stripe fait autorité.'),
          const SizedBox(height: DomoliaSpacing.field),
          DropdownButtonFormField<int>(
            key: const ValueKey('ouAmount'),
            initialValue: _amount,
            decoration: const InputDecoration(labelText: 'Montant'),
            items: const [
              DropdownMenuItem(value: 500, child: Text('5 USD')),
              DropdownMenuItem(value: 1000, child: Text('10 USD')),
              DropdownMenuItem(value: 2500, child: Text('25 USD')),
              DropdownMenuItem(value: 5000, child: Text('50 USD')),
            ],
            onChanged: controller.busy ? null : (amount) {
              if (amount != null) setState(() => _amount = amount);
            },
          ),
          const SizedBox(height: DomoliaSpacing.field),
          FilledButton(
            key: const ValueKey('ouCheckout'),
            onPressed: kIsWeb || controller.busy ||
              controller.pending != null || !controller.ready
                ? null : () => _payment(target: active?.id),
            child: Text(widget.sandbox != null ?
              (active == null ? 'Créer un paiement fictif' : 'Recharger fictivement') :
              (active == null ? 'Acheter avec Stripe' : 'Recharger la clé active')),
          ),
          if (active != null) TextButton(
            onPressed: kIsWeb || controller.busy ||
              controller.pending != null ? null : () => _payment(),
            child: const Text('Acheter une nouvelle clé')),
          if (controller.pending != null) ...[
            const Divider(),
            const Text('Paiement en cours', style: TextStyle(
              color: DomoliaColors.goldLight, fontSize: 18)),
            Text('Session enregistrée pour ${_usd(controller.pending!.cents / 100)}.'),
            if (widget.sandbox == null)
              OutlinedButton(onPressed: controller.busy ? null :
                () => launchUrl(controller.pending!.paymentUrl,
                  mode: LaunchMode.externalApplication),
                child: const Text('Reprendre chez Stripe')),
            if (widget.sandbox != null) ...[
              const SizedBox(height: DomoliaSpacing.compact),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton(
                  key: const ValueKey('ouSimulatePaid'),
                  onPressed: controller.busy ? null :
                      () => _simulate(OuCheckoutStatus.paid),
                  child: const Text('Simuler réussite')),
                OutlinedButton(
                  key: const ValueKey('ouSimulateRefused'),
                  onPressed: controller.busy ? null :
                      () => _simulate(OuCheckoutStatus.refused),
                  child: const Text('Simuler refus')),
                OutlinedButton(
                  key: const ValueKey('ouSimulateExpired'),
                  onPressed: controller.busy ? null :
                      () => _simulate(OuCheckoutStatus.expired),
                  child: const Text('Simuler expiration')),
              ]),
            ],
            OutlinedButton(onPressed: controller.busy ? null : _check,
              child: const Text('Vérifier le paiement')),
            TextButton(onPressed: controller.busy ? null : () async {
              final accepted = await _confirm('Suspendre les vérifications ?',
                'Le jeton de récupération et la session seront conservés '
                'dans le coffre sécurisé. Vous pourrez reprendre le suivi à tout moment.');
              if (accepted) {
                _stopPoller();
                await controller.abandonPending();
              }
            }, child: const Text('Suspendre les vérifications')),
          ],
          if (controller.hasEmergencyKey) ...[
            const Divider(),
            const Text('Sauvegarde de secours requise',
              style: TextStyle(color: Colors.orangeAccent)),
            const Text('La clé a été reçue mais son stockage sécurisé a échoué. '
              'Copiez-la maintenant avant de fermer l’application.'),
            FilledButton(onPressed: () async {
              if (!await _confirm('Copier la clé de secours ?',
                'Copiez la clé uniquement dans un emplacement sécurisé.')) {
                return;
              }
              final secret = controller.emergencyKeyForManualRecovery();
              if (secret != null) {
                await Clipboard.setData(ClipboardData(text: secret));
              }
            }, child: const Text('Copier la clé de secours')),
          ],
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const ValueKey('ouImport'),
            onPressed: controller.busy ? null : _import,
            icon: const Icon(Icons.key_outlined),
            label: const Text('J’ai déjà une clé / Changer de clé')),
          const Divider(),
          const SizedBox(height: DomoliaSpacing.compact),
          const Text('Mes clés', style: TextStyle(
            color: DomoliaColors.goldLight, fontSize: 18)),
          const Text('Historique local chiffré. Les soldes affichés sont '
            'ceux de la dernière vérification et peuvent avoir changé.',
            style: TextStyle(color: DomoliaColors.muted)),
          const SizedBox(height: DomoliaSpacing.compact),
          if (controller.keys.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: DomoliaSpacing.field),
              child: Text('Aucune clé enregistrée. Les clés achetées ou '
                'importées apparaîtront ici.'),
            ),
          for (final item in controller.keys) ...[
            _keyCard(item, item.id == active?.id),
            const SizedBox(height: DomoliaSpacing.compact),
          ],
          const SizedBox(height: DomoliaSpacing.section),
          _models(),
          if (widget.sandbox == null && controller.ai.profiles.any((p) =>
              !p.id.startsWith('openuncensored-managed-') &&
              p.apiKey.isNotEmpty)) ...[
            const SizedBox(height: DomoliaSpacing.section),
            const Divider(),
            const SizedBox(height: DomoliaSpacing.compact),
            const Text('Anciens profils IA conservés dans le stockage sécurisé. '
              'Ils ne sont pas supprimés par cette configuration. '
              'Les Livres et Parties avec d’anciennes références restent lisibles.',
              style: TextStyle(color: DomoliaColors.muted)),
          ],
          const SizedBox(height: 16),
        ],
      ));
    },
  );
}
