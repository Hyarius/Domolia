import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../ai/ai_controller.dart';
import '../ai/ai_diagnostics.dart';
import '../ai/ai_usage.dart';
import '../ai/ai_provider.dart';
import '../ai/ai_task_routing.dart';
import '../books/book_library_controller.dart';
import '../chat/chat_controller.dart';
import '../chat/chat_protocol.dart';
import '../chat/chat_exports.dart';
import '../theme/domolia_theme.dart';
import '../illustration/image_preferences.dart';

/// Conversation-level settings only select already configured AI profiles.
class ConversationSettingsPage extends StatefulWidget {
  const ConversationSettingsPage({
    super.key, required this.library, required this.ai,
    required this.chat, required this.bookId, required this.sessionId,
    this.bookTitle, this.sessionTitle, required this.onBack,
    this.onExportBookJson, this.onLoadAiDiagnostics, this.onExportAiTrace,
    this.onPurgeAiDiagnostics, this.onLoadAiUsage,
    this.taskRouting, this.onOpenMemory, this.imagePreferences,
    this.showBackButton = true,
  });
  final BookLibraryController library;
  final AiConnectionController ai;
  final NarrativeChatController chat;
  final String bookId;
  final String sessionId;
  final String? bookTitle;
  final String? sessionTitle;
  final VoidCallback onBack;
  final bool showBackButton;
  /// Optional test adapter; production uses the Android file picker.
  final Future<void> Function(String fileName, Uint8List bytes)? onExportBookJson;
  /// Waits for queued SQLite diagnostic writes in production.
  final Future<List<StoredAiDiagnostic>> Function()? onLoadAiDiagnostics;
  /// Test adapter; production saves through Android's file picker.
  final Future<void> Function(String fileName, Uint8List bytes)? onExportAiTrace;
  final Future<void> Function()? onPurgeAiDiagnostics;
  final Future<List<AiUsageRecord>> Function()? onLoadAiUsage;
  final AiTaskRouting? taskRouting;
  final VoidCallback? onOpenMemory;
  final ImagePreferences? imagePreferences;
  @override
  State<ConversationSettingsPage> createState() => _ConversationSettingsPageState();
}

class _ConversationSettingsPageState extends State<ConversationSettingsPage> {
  String? _selected;

  String? _memoryProfile;
  bool _memoryEnabled = true;
  String? _inheritedNarratorProfile;
  bool _toolCallingEnabled = true;
  IllustrationMode? _illustrationModeOverride;
  int _cachedLoreCharacters = 0;
  Map<AiNarrativeTask, AiTaskGenerationOverride> _generationOverrides = {};
  List<AiUsageRecord> _usageRecords = const [];
  bool _loaded = false;
  bool _loadFailed = false;
  bool _saving = false;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      await widget.ai.initialize();
      final session = await widget.library.session(widget.sessionId);
      final bookProfile = await widget.library.profileFor(widget.bookId);
      List<AiUsageRecord> usage = const [];
      try { usage = await widget.onLoadAiUsage?.call() ?? const []; }
      catch (_) { /* Accounting must not block configuration. */ }
      if (mounted) {
        setState(() {
          _selected = session?.aiProfileId;

          _memoryProfile = session?.memoryProfileId;
          _memoryEnabled = session?.memoryEnabled ?? true;
          _toolCallingEnabled = session?.toolCallingEnabled ?? true;
          _illustrationModeOverride = session?.illustrationModeOverride;
          _inheritedNarratorProfile = bookProfile;
          _cachedLoreCharacters = session?.optimizedLore?.length ?? 0;
          _usageRecords = usage;
          _generationOverrides = Map.of(session?.generationOverrides ?? {});
          _loaded = true;
          _loadFailed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loaded = true;
          _loadFailed = true;
        });
        _notify('Impossible de charger les paramètres de cette Partie.');
      }
    }
  }

  void _notify(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)));
    }
  }

  Future<void> _setProfile(String? id) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final selected = id == '' ? null : id;
      await widget.library.setSessionProfile(widget.sessionId, selected);
      if (mounted) setState(() => _selected = selected);
      _notify('Connexion IA de cette Partie enregistrée.');
    } catch (_) {
      _notify('Impossible de sauvegarder cette connexion.');
    } finally {
      if (mounted) { setState(() => _saving = false); }
    }
  }

  Future<void> _setToolCallingEnabled(bool enabled) async {
    if (_saving || widget.chat.busy) return;
    setState(() => _saving = true);
    try {
      await widget.library.setSessionToolCallingEnabled(widget.sessionId, enabled);
      if (mounted) setState(() => _toolCallingEnabled = enabled);
    } catch (_) {
      _notify('Impossible de sauvegarder les consultations IA.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setIllustrationMode(String? selected) async {
    if (_saving || widget.chat.busy) return;
    setState(() => _saving = true);
    try {
      final value = selected == null || selected.isEmpty
          ? null : IllustrationMode.values.byName(selected);
      await widget.library.setSessionIllustrationMode(widget.sessionId, value);
      widget.chat.setIllustrationMode(value ??
          widget.library.byId(widget.bookId)?.illustrationMode ??
          IllustrationMode.disabled);
      if (mounted) setState(() => _illustrationModeOverride = value);
    } catch (_) {
      _notify('Impossible de sauvegarder le mode d’illustration.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setMemoryEnabled(bool enabled) async {
    if (_saving || widget.chat.busy) return;
    setState(() => _saving = true);
    try {
      await widget.library.setSessionMemoryEnabled(widget.sessionId, enabled);
      if (mounted) setState(() => _memoryEnabled = enabled);
    } catch (_) {
      _notify('Impossible de modifier l’extraction automatique.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setTaskProfile(String task, String? value) async {
    if (_saving || widget.chat.busy) return;
    setState(() => _saving = true);
    try {
      final selected = value == '' ? null : value;
      await widget.library.setSessionTaskProfile(
        widget.sessionId, task, selected,
      );
      if (mounted) {
        setState(() {
          if (task == 'memory') {
            _memoryProfile = selected;
          }
        });
      }
      _notify('Profil de tâche enregistré pour cette Partie.');
    } catch (_) {
      _notify('Impossible de sauvegarder le profil de cette tâche.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setGeneration(AiNarrativeTask task,
      AiTaskGenerationOverride options) async {
    if (_saving || widget.chat.busy) return;
    setState(() => _saving = true);
    try {
      await widget.library.setSessionGenerationOverride(
          widget.sessionId, task, options);
      if (mounted) {
        setState(() {
          _generationOverrides = Map.of(_generationOverrides);
          if (options.isEmpty) {
            _generationOverrides.remove(task);
          } else {
            _generationOverrides[task] = options;
          }
        });
      }
      _notify('Paramètres de génération enregistrés pour cette Partie.');
    } catch (_) {
      _notify('Impossible de sauvegarder les paramètres de génération.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _taskGenerationControls(AiNarrativeTask task) {
    final options = _generationOverrides[task] ??
        const AiTaskGenerationOverride();
    final inherited = widget.taskRouting?.generationFor(task) ??
        AiTaskGenerationSettings.defaults(task);
    final title = switch (task) {
      AiNarrativeTask.narrator => 'Narrateur',
      AiNarrativeTask.jsonifier => 'JSONificateur',
      AiNarrativeTask.optimizer => 'Optimiseur de Lore',
      AiNarrativeTask.memory => 'Extraction mémoire',
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: DomoliaSpacing.compact),
      Text(title, style: const TextStyle(color: DomoliaColors.goldLight)),
      const SizedBox(height: DomoliaSpacing.compact),
      DropdownButtonFormField<int>(
        key: ValueKey('conversationTokens-${task.name}-${options.maxOutputTokens ?? 0}'),
        initialValue: options.maxOutputTokens ?? 0,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Budget maximal de sortie (tokens)'),
        items: [
          DropdownMenuItem(value: 0,
              child: Text('Hériter (${inherited.maxOutputTokens})')),
          for (final count in AiTaskGenerationSettings.tokenChoices)
            DropdownMenuItem(value: count, child: Text('$count tokens')),
        ],
        onChanged: _saving || widget.chat.busy ? null : (count) {
          if (count != null) {
            _setGeneration(task, options.copyWith(
              maxOutputTokens: count == 0 ? null : count,
              clearMaxOutputTokens: count == 0,
            ));
          }
        },
      ),
      const SizedBox(height: DomoliaSpacing.field),
      DropdownButtonFormField<String>(
        key: ValueKey('conversationReasoning-${task.name}-${options.reasoningEffort ?? ""}'),
        initialValue: options.reasoningEffort ?? '',
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Effort de raisonnement (ChatGPT)'),
        items: [
          DropdownMenuItem(value: '',
            child: Text('Hériter (${inherited.reasoningEffort})')),
          for (final effort in AiTaskGenerationSettings.reasoningChoices)
            DropdownMenuItem(value: effort, child: Text(
              effort == 'auto' ? 'Automatique (Luna)' :
              effort == 'provider' ? 'Défaut fournisseur' :
              effort.toUpperCase())),
        ],
        onChanged: _saving || widget.chat.busy ? null : (effort) {
          if (effort != null) {
            _setGeneration(task, options.copyWith(
              reasoningEffort: effort.isEmpty ? null : effort,
              clearReasoningEffort: effort.isEmpty,
            ));
          }
        },
      ),
    ]);
  }

  /// Revert this Party's overrides, not its narrative or Live Memory.
  Future<void> _resetToBookSettings() async {
    if (_saving || !_loaded || _loadFailed || widget.chat.busy ||
        widget.chat.pendingRaw != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Revenir aux réglages du Livre ?'),
        content: const Text(
          'Les surcharges de cette Partie (profils IA, mémoire, '
          'consultations, budgets et illustrations) seront retirées. '
          'Les réglages du Livre ou de l’application seront utilisés.\\n\\n'
          'Le récit, les souvenirs, les images et le Livre ne seront '
          'pas modifiés.'),
        actions: [
          TextButton(
            key: const ValueKey('conversationResetCancel'),
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            key: const ValueKey('conversationResetConfirm'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Rétablir'),
          ),
        ],
      ),
    ) ?? false;
    if (!confirmed || !mounted || _saving || widget.chat.busy ||
        widget.chat.pendingRaw != null) return;

    setState(() => _saving = true);
    ImageGenerationOptions? previousImageOverride;
    var imageOverrideRemoved = false;
    try {
      final preferences = widget.imagePreferences;
      if (preferences != null) {
        previousImageOverride = await preferences.overrideFor(widget.sessionId);
        await preferences.saveParty(widget.sessionId, null);
        imageOverrideRemoved = true;
      }
      try {
        await widget.library.resetSessionSettings(widget.sessionId);
      } catch (_) {
        // Undo the preference change if the durable session update failed.
        if (imageOverrideRemoved && previousImageOverride != null) {
          await preferences!.saveParty(widget.sessionId, previousImageOverride);
        }
        rethrow;
      }
      widget.chat.setIllustrationMode(
          widget.library.byId(widget.bookId)?.illustrationMode ??
              IllustrationMode.disabled);
      await _load();
      _notify('Réglages de la Partie rétablis depuis le Livre.');
    } catch (_) {
      _notify('Impossible de rétablir les réglages de cette Partie.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _recompileLore() async {
    if (_saving || widget.chat.busy || widget.chat.pendingRaw != null) {
      _notify('Terminez la génération en cours avant de recompiler le Lore.');
      return;
    }
    setState(() => _saving = true);
    try {
      // Invalidate both the live cache and its persisted copy, even after an
      // app restart. The next narrative RAW rebuilds the context just once.
      await widget.library.saveOptimizedLore(widget.sessionId, '', '');
      if (!widget.chat.requestLoreRecompilation()) {
        throw StateError('Une génération est en cours.');
      }
      if (mounted) setState(() => _cachedLoreCharacters = 0);
      _notify('Contexte de départ à préparer localement au prochain message.');
    } catch (_) {
      _notify('Impossible de réinitialiser le cache de Lore.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _export() async {
    var scope = ChatExportScope.complete;
    var quantity = '3';
    var invalid = false;
    final selection = await showDialog<(ChatExportScope, int)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Exporter la conversation'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<ChatExportScope>(
              key: const ValueKey('chatExportScope'),
              initialValue: scope,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Portée de l’export'),
              items: const [
                DropdownMenuItem(value: ChatExportScope.complete,
                    child: Text('Toute la conversation')),
                DropdownMenuItem(value: ChatExportScope.lastScenes,
                    child: Text('X dernières scènes')),
                DropdownMenuItem(value: ChatExportScope.lastMessages,
                    child: Text('X derniers messages')),
              ],
              onChanged: (value) {
                if (value != null) update(() { scope = value; invalid = false; });
              },
            ),
            if (scope != ChatExportScope.complete) TextFormField(
              key: const ValueKey('chatExportCount'),
              initialValue: quantity,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'Nombre',
                  errorText: invalid ? 'Entre 1 et 50 000' : null),
              onChanged: (value) => quantity = value,
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Annuler')),
            FilledButton(onPressed: () {
              final count = scope == ChatExportScope.complete
                  ? 1 : int.tryParse(quantity);
              if (count == null || count < 1 || count > 50000) {
                update(() => invalid = true);
                return;
              }
              Navigator.pop(dialogContext, (scope, count));
            }, child: const Text('Exporter')),
          ],
        ),
      ),
    );
    if (selection == null) return;
    try {
      final payload = exportConversation(
        widget.chat.timeline,
        scope: selection.$1, count: selection.$2,
        bookTitle: widget.bookTitle, sessionTitle: widget.sessionTitle,
      );
      final bytes = Uint8List.fromList(
          utf8.encode(const JsonEncoder.withIndent('  ').convert(payload)));
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: 'Exporter la conversation',
        fileName: 'domolia-conversation.json',
        type: FileType.custom, allowedExtensions: ['json'],
        bytes: bytes,
      );
      if (saved != null) _notify('Conversation exportée.');
    } catch (_) {
      _notify('Impossible d’exporter cette conversation.');
    }
  }

  /// Export the canonical Book definition, not this session or its AI profile.
  Future<void> _exportBook() async {
    try {
      final book = widget.library.byId(widget.bookId);
      if (book == null) {
        _notify('Livre introuvable.');
        return;
      }
      final bytes = Uint8List.fromList(utf8.encode(book.exportJson()));
      final safeName = book.title.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final fileName = '${safeName.isEmpty ? 'livre' : safeName}.json';
      if (widget.onExportBookJson != null) {
        await widget.onExportBookJson!(fileName, bytes);
        _notify('Livre exporté.');
        return;
      }
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: 'Exporter le Livre (JSON brut)',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: bytes,
      );
      if (saved != null) _notify('Livre exporté.');
    } catch (_) {
      _notify('Impossible d’exporter le Livre.');
    }
  }

  Future<void> _purgeAiDiagnostics() async {
    if (widget.chat.busy || widget.onPurgeAiDiagnostics == null) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Purger les diagnostics ?'),
        content: const Text('Supprimer définitivement les requêtes '
          'et réponses IA de cette Partie ? Le récit et les RAW '
          'sauvegardés seront conservés.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Purger')),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    try {
      await widget.onPurgeAiDiagnostics!();
      widget.chat.forgetLastExchange();
      _notify('Diagnostics de cette Partie supprimés.');
    } catch (_) {
      _notify('Impossible de purger les diagnostics.');
    }
  }

  Future<void> _exportAiTrace() async {
    try {
      final diagnostics = widget.onLoadAiDiagnostics == null
          ? await widget.library.diagnostics(widget.sessionId)
          : await widget.onLoadAiDiagnostics!();
      if (!mounted) return;
      final payload = exportAiPipelineTrace(
        widget.chat.timeline,
        widget.chat.rawGenerations,
        diagnostics,
        latestExchange: widget.chat.lastExchange,
        bookTitle: widget.bookTitle,
        sessionTitle: widget.sessionTitle,
      );
      final bytes = Uint8List.fromList(
        utf8.encode(const JsonEncoder.withIndent('  ').convert(payload)),
      );
      // Raw provider responses can be large; keep Android file export bounded.
      if (bytes.length > 32 * 1024 * 1024) {
        _notify('Diagnostic trop volumineux (32 Mio maximum).');
        return;
      }
      const fileName = 'domolia-diagnostic-ia.json';
      if (widget.onExportAiTrace != null) {
        await widget.onExportAiTrace!(fileName, bytes);
        _notify('Diagnostic IA exporté.');
        return;
      }
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: 'Exporter les échanges IA',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: bytes,
      );
      if (saved != null) _notify('Diagnostic IA exporté.');
    } catch (_) {
      _notify('Impossible d’exporter les échanges IA.');
    }
  }

  Widget _taskProfileField({
    required String task,
    required String label,
    required String? value,
    required List<AiProfile> profiles,
    required String inheritedLabel,
    required List<DropdownMenuItem<String>> additional,
  }) {
    final selected = value ?? '';
    final known = selected.isEmpty ||
        additional.any((item) => item.value == selected) ||
        profiles.any((profile) => profile.id == selected);
    return DropdownButtonFormField<String>(
      key: ValueKey('conversationTask-$task-${known ? selected : "missing"}'),
      initialValue: known ? selected : '',
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        helperText: known ? null :
            'Le profil précédemment choisi a été supprimé.',
      ),
      items: [
        DropdownMenuItem(value: '', child: Text(inheritedLabel)),
        ...additional,
        for (final profile in profiles)
          DropdownMenuItem(
            value: profile.id,
            child: Text(profile.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: _saving || widget.chat.busy
          ? null : (value) => _setTaskProfile(task, value),
    );
  }

  Widget _usageSection() {
    final summary = AiUsageSummary(_usageRecords);
    final all = summary.total;
    String tokens(AiUsageTotals value) {
      if (value.calls == 0) return '—';
      final count = value.measuredTokens.toString();
      return value.unknownTokens == 0
          ? count : '$count+ (partiel)';
    }
    String cost(AiUsageTotals value) {
      if (value.calls == 0 || value.unknownCost == value.calls) {
        return 'indisponible';
      }
      final label = value.knownCostUsd.toStringAsFixed(5);
      return value.unknownCost == 0 ? '$label USD' : '≥ $label USD';
    }
    Widget item(String label, AiUsageTotals value, {bool bold = false}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            SizedBox(width: 112, child: Text(label,
              style: TextStyle(fontWeight:
                  bold ? FontWeight.bold : FontWeight.normal))),
            Expanded(child: Text(tokens(value), textAlign: TextAlign.right)),
            const SizedBox(width: 12),
            SizedBox(width: 110, child: Text(cost(value),
              textAlign: TextAlign.right, style:
                  const TextStyle(fontSize: 12))),
          ]),
        );
    final turns = widget.chat.messages.where(
        (m) => m.speaker == ChatSpeaker.player).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Consommation IA', style: TextStyle(
          color: DomoliaColors.goldLight, fontSize: 18)),
      const SizedBox(height: 6),
      for (final task in AiUsageSummary.tasks)
        item(task, summary.forTask(task)),
      const Divider(),
      item('Total', all, bold: true),
      const SizedBox(height: 8),
      Text('${all.calls} appels IA · ${all.toolCalls} consultations d’outils · '
          '${all.errors} erreurs · ${all.estimatedUsage} usages estimés · '
          '${turns == 0 ? '—' : (all.measuredTokens / turns).round().toString()} '
          'tokens connus/tour',
        style: const TextStyle(color: DomoliaColors.muted)),
      const SizedBox(height: 6),
      Text('Entrée connue : ${all.measuredInput} · Sortie connue : ${all.measuredOutput} · '
          'Cache déclaré : ${all.cachedTokensKnown} · '
          'Raisonnement déclaré : ${all.reasoningTokensKnown}',
        style: const TextStyle(color: DomoliaColors.muted, fontSize: 12)),
      const SizedBox(height: 6),
      Text('Usage fournisseur : ${all.providerReportedUsage}/${all.calls} appels · '
           'JSON envoyé : ${all.requestBytesKnown} octets connus',
        style: const TextStyle(color: DomoliaColors.muted, fontSize: 12)),
      const SizedBox(height: 6),
      const Text('Tokens : déclarés par le fournisseur si disponibles, '
           'sinon diagnostics ou valeurs inconnues. '
          'Un « + » signale des appels sans usage disponible. '
          'Le coût est affiché seulement si le fournisseur le fournit ; '
          '« ≥ » signifie que le total est incomplet. '
          'Les anciens appels et les diagnostics purgés avant cette version '
          'ne sont pas reconstitués.',
        style: TextStyle(color: DomoliaColors.muted, fontSize: 12)),
      Align(alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: widget.onLoadAiUsage == null ? null : () async {
            final records = await widget.onLoadAiUsage!();
            if (mounted) setState(() => _usageRecords = records);
          },
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Actualiser la consommation'),
        )),
    ]);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ListView(
      key: const ValueKey('conversationSettings'),
      padding: const EdgeInsets.all(22),
      children: [
        Row(children: [
          if (widget.showBackButton)
             IconButton(tooltip: 'Retour à la conversation',
              onPressed: widget.onBack, icon: const Icon(Icons.arrow_back)),
          const Expanded(child: Text('Paramètres de la conversation',
            style: TextStyle(color: DomoliaColors.goldLight,
                fontSize: 21, fontWeight: FontWeight.bold))),
        ]),
        const SizedBox(height: 24),
        const Text('Narration et illustrations', style: TextStyle(
            color: DomoliaColors.goldLight, fontSize: 18)),
        if (!_loaded)
          const LinearProgressIndicator()
        else if (_loadFailed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: DomoliaSpacing.field),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Les réglages de cette Partie sont indisponibles. '
                  'Aucune modification ne sera appliquée.',
                  style: TextStyle(color: DomoliaColors.cream)),
                const SizedBox(height: DomoliaSpacing.field),
                OutlinedButton.icon(
                  key: const ValueKey('conversationSettingsRetry'),
                  onPressed: () {
                    setState(() => _loaded = false);
                    _load();
                  },
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Réessayer'),
                ),
              ],
            ),
          )
        else AnimatedBuilder(
          animation: widget.ai,
          builder: (context, _) {
            final profiles = widget.ai.profiles;
            final exists = _selected == null ||
                profiles.any((profile) => profile.id == _selected);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('conversationResetToBook'),
                  onPressed: _saving || widget.chat.busy ||
                      widget.chat.pendingRaw != null
                      ? null : _resetToBookSettings,
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: const Text('Rétablir les réglages du Livre'),
                ),
                const SizedBox(height: DomoliaSpacing.field),
                if (!exists) const Text(
                  'La configuration précédente a été supprimée.',
                  style: TextStyle(color: DomoliaColors.goldLight)),
                DropdownButtonFormField<String>(
                  key: ValueKey(_selected ?? 'conversationDefaultProfile'),
                  initialValue: exists ? _selected ?? '' : '',
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Narrateur — profil de cette Partie'),
                  items: [
                    const DropdownMenuItem(value: '',
                        child: Text('Profil par défaut du Livre')),
                    for (final profile in profiles)
                      DropdownMenuItem(value: profile.id,
                          child: Text(profile.name,
                              overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: _saving || widget.chat.busy
                      ? null : _setProfile,
                ),
                const SizedBox(height: DomoliaSpacing.field),
                DropdownButtonFormField<String>(
                  key: ValueKey('conversationIllustration-${_illustrationModeOverride?.name ?? "book"}'),
                  initialValue: _illustrationModeOverride?.name ?? '',
                  isExpanded: true,
                  decoration: const InputDecoration(
                      labelText: 'Illustrations de cette Partie'),
                  items: [
                    DropdownMenuItem(value: '',
                        child: Text('Hériter du Livre')),
                    const DropdownMenuItem(value: 'disabled',
                        child: Text('Désactivées')),
                    const DropdownMenuItem(value: 'suggestions',
                        child: Text('Suggestions')),
                    const DropdownMenuItem(value: 'automatic',
                        child: Text('Automatique (préparation uniquement)')),
                  ],
                  onChanged: _saving || widget.chat.busy
                      ? null : _setIllustrationMode,
                ),
                const SizedBox(height: DomoliaSpacing.section),
                const Divider(),
                const SizedBox(height: DomoliaSpacing.compact),
                const Text('Mémoire narrative', style: TextStyle(
                  color: DomoliaColors.goldLight, fontSize: 18)),
                const SizedBox(height: DomoliaSpacing.field),
                SwitchListTile(
                  key: const ValueKey('conversationMemoryEnabled'),
                  title: const Text('Mémoire automatique'),
                  subtitle: const Text('Une extraction IA supplémentaire '
                      'peut être facturée après chaque tour validé. '
                      'Désactiver ne supprime pas les souvenirs.'),
                  value: _memoryEnabled,
                  onChanged: _saving || widget.chat.busy
                      ? null : _setMemoryEnabled,
                ),
                const SizedBox(height: DomoliaSpacing.field),
                _taskProfileField(
                  task: 'memory',
                  label: 'Mémoire — profil de cette Partie',
                  value: _memoryProfile,
                  profiles: profiles,
                  inheritedLabel: 'Profil mémoire par défaut',
                  additional: const [
                    DropdownMenuItem(value: '#disabled',
                        child: Text('Désactiver cette tâche')),
                    DropdownMenuItem(value: '#narrator',
                        child: Text('Même IA que le narrateur')),
                  ],
                ),
                const SizedBox(height: DomoliaSpacing.field),
                OutlinedButton.icon(
                  key: const ValueKey('conversationOpenMemory'),
                  onPressed: widget.onOpenMemory,
                  icon: const Icon(Icons.auto_stories_outlined),
                  label: const Text('Consulter et corriger la mémoire'),
                ),
                const SizedBox(height: DomoliaSpacing.field),
                Builder(builder: (context) {
                  final inherited = widget.taskRouting?.profileFor(
                    AiNarrativeTask.narrator,
                  );
                  final chosen = _selected ?? inherited ?? _inheritedNarratorProfile;
                  final profile = [
                    for (final p in profiles) if (p.id == chosen) p,
                  ];
                  final supported = profile.isNotEmpty &&
                      profile.first.toolCallingCompatibility ==
                          AiToolCallingCompatibility.supported;
                  return SwitchListTile(
                    key: const ValueKey('conversationToolCalling'),
                    title: const Text('Consultations du Lore et de l’historique'),
                    subtitle: Text(!supported
                        ? 'Modèle non confirmé compatible : mode classique utilisé.'
                        : 'Le narrateur peut consulter des souvenirs à la demande.'),
                    value: _toolCallingEnabled,
                    onChanged: _saving || widget.chat.busy
                        ? null : _setToolCallingEnabled,
                  );
                }),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: DomoliaSpacing.compact),
                ExpansionTile(
                  key: const ValueKey('conversationAdvancedSettings'),
                  title: const Text('Réglages IA avancés'),
                  subtitle: const Text('Budgets et contexte du Livre'),
                  children: [
                for (final task in AiNarrativeTask.active) ...[
                  _taskGenerationControls(task),
                  const SizedBox(height: DomoliaSpacing.field),
                ],
                const SizedBox(height: 12),
                Text(
                  _cachedLoreCharacters > 0
                      ? 'Contexte de départ : $_cachedLoreCharacters caractères '
                        'préparés localement pour cette Partie.'
                      : 'Contexte de départ préparé automatiquement au premier tour.',
                  key: const ValueKey('conversationLoreCacheStatus'),
                  style: const TextStyle(color: DomoliaColors.muted),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  key: const ValueKey('conversationRecompileLore'),
                  onPressed: _saving || widget.chat.busy ||
                      widget.chat.pendingRaw != null ? null : _recompileLore,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Repréparer le contexte au prochain message'),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Le contexte est préparé localement. Cette action '
                  'ne consomme aucun crédit IA.',
                  style: TextStyle(color: DomoliaColors.muted),
                ),
                  ],
                ),
              ],
            );
          },
        ),
 
        const SizedBox(height: DomoliaSpacing.section),
        const Divider(),
        const SizedBox(height: DomoliaSpacing.compact),
        _usageSection(),
        const SizedBox(height: DomoliaSpacing.section),
        const Divider(),
        const SizedBox(height: DomoliaSpacing.compact),
        const Text('Exports et historique', style: TextStyle(
            color: DomoliaColors.goldLight, fontSize: 18)),
        const SizedBox(height: DomoliaSpacing.field),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            key: const ValueKey('conversationExport'),
            onPressed: _export,
            icon: const Icon(Icons.file_download_outlined),
            label: const Text('Exporter la conversation'),
          ),
          OutlinedButton.icon(
            key: const ValueKey('bookRawExport'),
            onPressed: _exportBook,
            icon: const Icon(Icons.menu_book_outlined),
            label: const Text('Exporter le Livre (JSON)'),
          ),
          OutlinedButton.icon(
            key: const ValueKey('aiPipelineExport'),
            onPressed: _exportAiTrace,
            icon: const Icon(Icons.bug_report_outlined),
            label: const Text('Exporter les échanges IA'),
          ),
        ]),
        const SizedBox(height: 18),
        OutlinedButton.icon(
          key: const ValueKey('conversationPurgeDiagnostics'),
          onPressed: widget.chat.busy || widget.onPurgeAiDiagnostics == null
              ? null : _purgeAiDiagnostics,
          icon: const Icon(Icons.delete_outline),
          label: const Text('Purger les diagnostics de cette Partie'),
        ),
        const SizedBox(height: 10),
        const Text(
          'Le Livre contient son Lore et ses paramètres narratifs. '
          'Le diagnostic IA regroupe les requêtes, les réponses brutes, '
          'et les erreurs encore disponibles. '
          'Il peut contenir des informations personnelles ; '
          'les traces supprimées ne sont pas récupérables.',
          style: TextStyle(color: DomoliaColors.muted),
        ),
      ],
    ),
  );
}
