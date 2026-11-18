import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../ai/ai_diagnostics.dart';
import '../ai/ai_provider.dart';
import '../theme/domolia_theme.dart';
import '../illustration/illustration_controller.dart';
import '../illustration/illustration_slot.dart';
import '../illustration/illustration_records.dart';
import 'chat_controller.dart';
import 'chat_protocol.dart';

class GroupChatPage extends StatefulWidget {
  const GroupChatPage({
    super.key,
    required this.controller,
    required this.onOpenSettings,
    this.bookTitle,
    this.sessionTitle,
    this.onLoadDiagnostics,
    this.onPurgeDiagnostics,
    this.onExportDiagnostic,
    this.illustrations,
    this.onOpenImageSettings,
  });

  final NarrativeChatController controller;
  final IllustrationController? illustrations;
  final VoidCallback? onOpenImageSettings;
  final VoidCallback onOpenSettings;
  final String? bookTitle;
  final String? sessionTitle;
  final Future<List<StoredAiDiagnostic>> Function()? onLoadDiagnostics;
  final Future<void> Function()? onPurgeDiagnostics;
  /// Test adapter; production uses Android's file picker.
  final Future<void> Function(String, Map<String, dynamic>)? onExportDiagnostic;

  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends State<GroupChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  int? _lastTimelineEventId;
  int? _highlightedMessageId;
  bool _imageDialogOpen = false;

  @override
  void initState() {
    super.initState();
    _observeInitialTimeline();
    widget.controller.addListener(_onChatChanged);
  }

  @override
  void didUpdateWidget(covariant GroupChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChatChanged);
      _observeInitialTimeline();
      widget.controller.addListener(_onChatChanged);
    }
  }

  void _observeInitialTimeline() {
    final timeline = widget.controller.timeline;
    _lastTimelineEventId = timeline.isEmpty ? null : timeline.last.id;
    if (timeline.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToLatest());
    }
  }

  void _jumpToLatest() {
    if (!mounted || !_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  void _onChatChanged() {
    final timeline = widget.controller.timeline;
    final last = timeline.isEmpty ? null : timeline.last;
    if (last?.id == _lastTimelineEventId) return;
    _lastTimelineEventId = last?.id;

    if (last is ChatIllustrationIntent && widget.illustrations != null) {
      // Text-only direction pass. No image generation occurs here.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(widget.illustrations!.prepare(last.id));
      });
    }

    // Keep the freshly sent player message in view, but never jump to the
    // END of a newly committed AI answer. Long answers begin where reading
    // left off, regardless of the number of bubbles generated.
    if (last is ChatEntry && last.speaker == ChatSpeaker.player) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToLatest());
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChatChanged);
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  void _send() {
    final value = _input.text.trim();
    if (value.isEmpty || widget.controller.busy) return;
    _input.clear();
    setState(() {});
    widget.controller.send(value);
  }

  void _showExportMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _saveDiagnostic(String name, Map<String, dynamic> data) async {
    try {
      if (widget.onExportDiagnostic != null) {
        await widget.onExportDiagnostic!(name, data);
        _showExportMessage('Export JSON enregistré.');
        return;
      }
      final content = Uint8List.fromList(
        utf8.encode(const JsonEncoder.withIndent('  ').convert(data)),
      );
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: 'Exporter pour diagnostic',
        fileName: name,
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: content,
      );
      if (saved != null) _showExportMessage('Export JSON enregistré.');
    } catch (_) {
      _showExportMessage('Impossible d’exporter le diagnostic JSON.');
    }
  }

  /// Export only the exact HTTP request which produced the tapped bubble.
  Future<void> _exportAiMessage(ChatEntry entry) async {
    try {
      final choices = <StoredAiDiagnostic>[];
      final last = widget.controller.lastExchange;
      if (last != null) {
        choices.add(StoredAiDiagnostic(
          id: 'latest', sessionId: '', createdAtUtc: last.createdAtUtc,
          content: last.exportJson(),
        ));
      }
      if (widget.onLoadDiagnostics != null) {
        choices.addAll(await widget.onLoadDiagnostics!());
      }
      if (!mounted) return;
      StoredAiDiagnostic? selected;
      for (final candidate in choices) {
        if (candidate.containsMessage(entry.id)) {
          selected = candidate;
          break;
        }
      }
      if (selected == null) {
        _showExportMessage('Aucun diagnostic conservé pour ce message IA '
            '(conservation désactivée ou traces purgées).');
        return;
      }
      await _saveDiagnostic(
        'domolia-message-${entry.id}-requete-reponse.json',
        selected.data,
      );
    } catch (_) {
      _showExportMessage('Impossible de lire le diagnostic de ce message.');
    }
  }

  /// Expose the original literary HTTP exchange for the same player turn,
  /// independently from the formatter exchange used by bubble export.
  Future<void> _exportNarratorRaw(ChatEntry entry) async {
    final playerId = widget.controller.playerIdForAiMessage(entry.id);
    if (playerId == null) return;
    try {
      final choices = <StoredAiDiagnostic>[];
      final last = widget.controller.lastExchange;
      if (last != null) {
        choices.add(StoredAiDiagnostic(
          id: 'latest', sessionId: '', createdAtUtc: last.createdAtUtc,
          content: last.exportJson(),
        ));
      }
      if (widget.onLoadDiagnostics != null) {
        choices.addAll(await widget.onLoadDiagnostics!());
      }
      if (!mounted) return;
      StoredAiDiagnostic? selected;
      for (final candidate in choices) {
        if (candidate.isNarratorForTurn(playerId)) {
          selected = candidate;
          break;
        }
      }
      if (selected == null) {
        _showExportMessage('Aucun diagnostic RAW conservé pour ce tour '
            '(traces purgées ou conservation désactivée).');
        return;
      }
      await _saveDiagnostic(
        'domolia-tour-$playerId-narrateur-raw.json',
        selected.data,
      );
    } catch (_) {
      _showExportMessage('Impossible de lire le diagnostic RAW.');
    }
  }

  Future<void> _editPlayerMessage(ChatEntry entry) async {
    final updated = await showDialog<String>(
      context: context,
      builder: (_) => _PlayerMessageEditor(initialText: entry.text),
    );
    if (updated == null || !mounted) return;
    if (!widget.controller.editPlayerMessage(entry.id, updated)) {
      _showExportMessage('Impossible de modifier ce message.');
      return;
    }
    _showExportMessage(
      'Message modifié. Utilisez « Reprendre ici » pour recalculer la suite.',
    );
  }

  Future<bool> _confirmRewind({
    required String title, required String message,
  }) async {
    return await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title), content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Continuer'),
          ),
        ],
      ),
    ) ?? false;
  }

  Future<void> _resumeAt(ChatEntry entry) async {
    if (!await _confirmRewind(
      title: 'Reprendre ici ?',
      message: 'Tous les messages et changements de scène après ce message '
          'seront supprimés. Une nouvelle réponse IA sera générée '
          'à partir de votre texte actuel.',
    )) {
      return;
    }
    await widget.controller.resumeFromPlayerMessage(entry.id);
  }

  Future<void> _regenerateAt(ChatEntry entry) async {
    if (!await _confirmRewind(
      title: 'Régénérer cette réponse ?',
      message: 'La réponse IA complète de ce tour (y compris les autres '
          'bulles et changements de scène), ainsi que toute la suite, '
          'sera remplacée par une nouvelle génération.',
    )) {
      return;
    }
    await widget.controller.regenerateFromAiMessage(entry.id);
  }

  Future<void> _showMessageActions(ChatEntry entry) async {
    if (entry.inProgress || widget.controller.busy) return;
    final isPlayer = entry.speaker == ChatSpeaker.player;
    setState(() => _highlightedMessageId = entry.id);
    try {
      await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            ListTile(
              title: Text(isPlayer ? 'Mon message' : entry.name),
              subtitle: Text(entry.text,
                maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            if (!widget.controller.hasSceneChangeBefore(entry.id)) 
              ListTile(
                key: const ValueKey('chatActionStartScene'),
                leading: const Icon(Icons.segment),
                title: const Text('Commencer une scène ici'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  widget.controller.startSceneAt(entry.id);
                },
              )
            else
              ListTile(
                key: const ValueKey('chatActionRemoveScene'),
                leading: const Icon(Icons.remove),
                title: const Text('Supprimer le changement de scène'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  widget.controller.removeSceneBefore(entry.id);
                },
              ),
            ListTile(
              key: const ValueKey('chatActionCopy'),
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Copier'),
              onTap: () async {
                Navigator.pop(sheetContext);
                final text = isPlayer || entry.speaker == ChatSpeaker.narrator
                    ? entry.text : _characterText(entry.text, entry.name);
                await Clipboard.setData(ClipboardData(text: text));
                _showExportMessage('Texte copié.');
              },
            ),
            if (isPlayer) ...[
              ListTile(
                key: const ValueKey('chatActionEdit'),
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Éditer'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await _editPlayerMessage(entry);
                },
              ),
              ListTile(
                key: const ValueKey('chatActionResume'),
                leading: const Icon(Icons.history_rounded),
                title: const Text('Reprendre ici'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await _resumeAt(entry);
                },
              ),
            ] else ...[
              ListTile(
                key: const ValueKey('chatActionIllustrate'),
                leading: const Icon(Icons.brush_outlined),
                title: const Text('Illustrer'),
                subtitle: const Text('Ajouter une intention d’image après ce passage'),
                enabled: widget.controller.canIllustrateMessage(entry.id),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  try {
                    final added =
                        await widget.controller.illustrateMessage(entry.id);
                    _showExportMessage(added
                        ? 'Illustration proposée.'
                        : 'Impossible d’illustrer ce passage.');
                  } catch (_) {
                    _showExportMessage(
                        'Impossible d’enregistrer l’illustration.');
                  }
                },
              ),
              ListTile(
                key: const ValueKey('chatActionRegenerate'),
                leading: const Icon(Icons.refresh_rounded),
                title: const Text('Régénérer'),
                enabled: widget.controller.canRegenerateFromAiMessage(entry.id),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await _regenerateAt(entry);
                },
              ),
              ListTile(
                key: const ValueKey('chatActionExport'),
                leading: const Icon(Icons.file_download_outlined),
                title: const Text('Exporter'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await _exportAiMessage(entry);
                },
              ),
              if (widget.controller.playerIdForAiMessage(entry.id) != null)
                ListTile(
                  key: const ValueKey('chatActionExportNarratorRaw'),
                  leading: const Icon(Icons.article_outlined),
                  title: const Text('Exporter le narrateur RAW'),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    await _exportNarratorRaw(entry);
                  },
                ),
            ],
          ],
        ),
        ),
      ),
      );
    } finally {
      if (mounted) setState(() => _highlightedMessageId = null);
    }
  }


  Future<void> _generateImage(int intentId) async {
    final illustrations = widget.illustrations;
    if (illustrations == null || illustrations.isBusy(intentId) ||
        _imageDialogOpen) {
      return;
    }
    final current = illustrations.forIntent(intentId);
    if (current == null) {
      await illustrations.prepare(intentId);
      return;
    }
    if (current.state == IllustrationJobState.ready) {
      _showExportMessage('Validez la description avant de générer l’image.');
      return;
    }
    _imageDialogOpen = true;
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Générer cette illustration ?'),
          content: Text(
            illustrations.forIntent(intentId)?.state ==
                    IllustrationJobState.approved
                ? 'La description est validée. Seule la génération '
                    'd’image sera lancée ; elle peut être facturée. '
                    'Coût inconnu. Aucun nouvel essai n’est automatique.'
                : 'La préparation IA et la génération d’image peuvent '
                    'être facturées. Coût inconnu. '
                    'Aucun nouvel essai n’est automatique.'),
          actions: [
            if (widget.onOpenImageSettings != null)
              TextButton.icon(
                key: const ValueKey('imageConfirmSettings'),
                onPressed: () {
                  Navigator.pop(dialogContext, false);
                  widget.onOpenImageSettings?.call();
                },
                icon: const Icon(Icons.tune_rounded),
                label: const Text('Réglages'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              key: const ValueKey('imageConfirmGenerate'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Générer'),
            ),
          ],
        ),
      );
      if (accepted == true && mounted) {
        // Non-blocking; controller checks double clicks and rewind races.
        illustrations.generate(intentId);
      }
    } finally {
      _imageDialogOpen = false;
    }
  }

  Future<void> _illustrateLatest() async {
    final illustrations = widget.illustrations;
    if (illustrations == null) return;
    final intent = illustrations.lastUnillustratedIntent;
    if (intent != null) {
      final state = illustrations.forIntent(intent)?.state;
      if (state == IllustrationJobState.approved) {
        await _generateImage(intent);
      } else if (state == IllustrationJobState.ready) {
        _showExportMessage('Validez la description dans l’encart image.');
      } else {
        await illustrations.prepare(intent);
      }
      return;
    }
    final messageId = illustrations.lastAiMessageWithoutIntent;
    if (messageId == null ||
        !widget.controller.canIllustrateMessage(messageId)) {
      _showExportMessage('Aucune scène récente à illustrer.');
      return;
    }
    if (_imageDialogOpen) return;
    _imageDialogOpen = true;
    bool create;
    try {
      create = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Créer une intention visuelle ?'),
          content: const Text('La narration ne contient pas d’intention '
            'non générée. Créer une proposition après le dernier '
            'message IA, sans rien inventer ?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              key: const ValueKey('imageCreateIntent'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Créer l’intention'),
            ),
          ],
        ),
      ) ?? false;
    } finally {
      _imageDialogOpen = false;
    }
    if (!create || !mounted) return;
    try {
      final inserted = await widget.controller.illustrateMessage(messageId);
      if (!inserted || !mounted) return;
      final nextIntent = illustrations.lastUnillustratedIntent;
      if (nextIntent != null) await illustrations.prepare(nextIntent);
    } catch (_) {
      _showExportMessage('Impossible de créer l’intention d’image.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = widget.controller;
    return AnimatedBuilder(
      animation: Listenable.merge([
        chat, if (widget.illustrations != null) widget.illustrations!,
      ]),
      builder: (context, _) {
        final transcript = chat.timeline;
        final illustrationStatus = widget.illustrations?.activityLabel;
        final illustrationError = widget.illustrations?.error;
        return SafeArea(
          child: Column(
            children: [
              Expanded(
                child: transcript.isEmpty
                    ? _EmptyConversation(onOpenSettings: widget.onOpenSettings)
                    : ListView.builder(
                        key: const ValueKey('groupChatTranscript'),
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(14, 22, 14, 22),
                        itemCount: transcript.length,
                        itemBuilder: (context, index) {
                          final entry = transcript[index];
                          if (entry is ChatSceneChange) {
                            return _SceneDivider(
                              key: ValueKey('chat-scene-${entry.id}'),
                            );
                          }
                          if (entry is ChatIllustrationIntent) {
                            return widget.illustrations == null
                                ? _IllustrationPlaceholder(
                                  key: ValueKey('chat-illustration-${entry.id}'),
                                  intent: entry,
                                )
                                : IllustrationSlot(
                                  key: ValueKey('chat-illustration-${entry.id}'),
                                  intent: entry,
                                  controller: widget.illustrations!,
                                  onGenerate: () => _generateImage(entry.id),
                                );
                          }
                          final bubble = entry as ChatEntry;
                          return _ChatBubble(
                            key: ValueKey('chat-entry-${bubble.id}'),
                            entry: bubble,
                            highlighted: bubble.id == _highlightedMessageId,
                            onLongPress: bubble.inProgress
                                ? null : () => _showMessageActions(bubble),
                          );
                        },
                      ),
              ),
              if (chat.busy)
                const Padding(
                  key: ValueKey('chatWritingIndicator'),
                  padding: EdgeInsets.fromLTRB(18, 8, 18, 8),
                  child: Row(
                    children: [
                      Icon(Icons.edit_note_rounded,
                        color: DomoliaColors.goldLight, size: 22),
                      SizedBox(width: 8),
                      Text('Le narrateur écrit…',
                        style: TextStyle(color: DomoliaColors.goldLight,
                          fontStyle: FontStyle.italic)),
                      SizedBox(width: 10),
                      SizedBox(width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 1.5,
                          color: DomoliaColors.goldDark)),
                    ],
                  ),
                ),
              if (illustrationStatus != null)
                Padding(
                  key: const ValueKey('chatIllustratorIndicator'),
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
                  child: Row(
                    children: [
                      const Icon(Icons.brush_rounded,
                        color: DomoliaColors.goldLight, size: 22),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(illustrationStatus,
                          style: const TextStyle(
                            color: DomoliaColors.goldLight,
                            fontStyle: FontStyle.italic,
                          )),
                      ),
                      const SizedBox(width: 10),
                      const SizedBox(width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 1.5,
                          color: DomoliaColors.goldDark)),
                    ],
                  ),
                ),
              if (illustrationError != null)
                Container(
                  key: const ValueKey('chatIllustrationErrorBanner'),
                  padding: const EdgeInsets.fromLTRB(16, 9, 12, 9),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4B2525),
                    border: Border.all(color: const Color(0xFFC87979)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline,
                        size: 20, color: Color(0xFFFFC7C7)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text('Illustration : $illustrationError',
                          style: const TextStyle(color: Color(0xFFFFE0E0))),
                      ),
                      if (widget.onOpenImageSettings != null)
                        IconButton(
                          key: const ValueKey('chatIllustrationOpenSettings'),
                          tooltip: 'Paramètres de génération d’images',
                          onPressed: widget.onOpenImageSettings,
                          icon: const Icon(Icons.tune_rounded,
                            color: Color(0xFFFFE0E0)),
                        ),
                      IconButton(
                        key: const ValueKey('chatIllustrationDismissError'),
                        tooltip: 'Masquer l’erreur d’illustration',
                        onPressed: widget.illustrations!.dismissError,
                        icon: const Icon(Icons.close,
                          color: Color(0xFFFFE0E0)),
                      ),
                    ],
                  ),
                ),
              if (chat.error != null)
                Container(
                  key: const ValueKey('chatErrorBanner'),
                  padding: const EdgeInsets.fromLTRB(16, 9, 12, 9),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4B2525),
                    border: Border.all(color: const Color(0xFFC87979)),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.error_outline,
                        size: 20,
                        color: Color(0xFFFFC7C7),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              chat.errorKind?.label ?? 'Narration interrompue',
                              key: const ValueKey('chatErrorCategory'),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Color(0xFFFFE0E0),
                              ),
                            ),
                            Text(
                              chat.error!,
                              style: const TextStyle(color: Color(0xFFFFE0E0)),
                            ),
                          ],
                        ),
                      ),
                      if (!chat.busy)
                        TextButton(
                          key: const ValueKey('chatRetry'),
                          onPressed: chat.retry,
                          child: const Text('Réessayer'),
                        ),
                    ],
                  ),
                ),
              Container(
                decoration: const BoxDecoration(
                  color: DomoliaColors.surface,
                  border: Border(
                    top: BorderSide(color: DomoliaColors.border),
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('groupChatInput'),
                        controller: _input,
                        minLines: 1,
                        maxLines: 4,
                        enabled: !chat.busy,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(
                          hintText: 'Écrivez une action ou un dialogue…',
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 15,
                            vertical: 11,
                          ),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 9),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.illustrations != null)
                          IconButton(
                            key: const ValueKey('chatIllustrateLastScene'),
                            tooltip: 'Illustrer la dernière scène',
                            icon: const Icon(Icons.brush_outlined),
                            onPressed: _illustrateLatest,
                          ),
                    SizedBox(
                      height: 49,
                      width: 49,
                      child: chat.busy
                          ? IconButton.filled(
                              key: const ValueKey('groupChatStop'),
                              tooltip: 'Arrêter la génération',
                              onPressed: chat.stop,
                              icon: const Icon(Icons.stop_rounded),
                            )
                          : IconButton.filled(
                              key: const ValueKey('groupChatSend'),
                              tooltip: 'Envoyer le message',
                              onPressed: _input.text.trim().isEmpty ? null : _send,
                              icon: const Icon(Icons.arrow_upward_rounded),
                            ),
                    ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The text field owns its controller for the full route transition.
class _PlayerMessageEditor extends StatefulWidget {
  const _PlayerMessageEditor({required this.initialText});

  final String initialText;

  @override
  State<_PlayerMessageEditor> createState() => _PlayerMessageEditorState();
}

class _PlayerMessageEditorState extends State<_PlayerMessageEditor> {
  late final TextEditingController _controller;
  bool _invalid = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = _controller.text.trim();
    if (value.isEmpty || value.length > 4000) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Éditer mon message'),
    content: TextField(
      key: const ValueKey('chatEditMessageInput'),
      controller: _controller,
      autofocus: true,
      minLines: 2,
      maxLines: 7,
      maxLength: 4000,
      decoration: InputDecoration(
        labelText: 'Votre message',
        errorText: _invalid
            ? 'Saisissez un texte (4 000 caractères max).' : null,
      ),
      onChanged: (_) {
        if (_invalid) setState(() => _invalid = false);
      },
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Annuler'),
      ),
      FilledButton(
        onPressed: _save,
        child: const Text('Enregistrer'),
      ),
    ],
  );
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation({required this.onOpenSettings});
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.auto_stories_outlined,
                size: 52,
                color: DomoliaColors.goldDark,
              ),
              const SizedBox(height: 16),
              const Text(
                'Une histoire à plusieurs voix',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: DomoliaColors.goldLight,
                  fontWeight: FontWeight.w700,
                  fontSize: 20,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Décrivez votre première action. La narration apparaît '
                'sous forme de texte, tandis que les personnages disposent '
                'de leurs propres bulles de dialogue.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: DomoliaColors.cream,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: onOpenSettings,
                icon: const Icon(Icons.tune_rounded),
                label: const Text('Choisir une connexion IA'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A quiet full-width gray rule, without a label, avatar or chat bubble.
class _SceneDivider extends StatelessWidget {
  const _SceneDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Changement de scène',
      child: Container(
        key: const ValueKey('chatSceneDivider'),
        margin: const EdgeInsets.symmetric(vertical: 22, horizontal: 2),
        height: 2,
        decoration: BoxDecoration(
          color: const Color(0xFF7B8785),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// An intent is an inline placeholder, not a message or a generated image.
class _IllustrationPlaceholder extends StatelessWidget {
  const _IllustrationPlaceholder({super.key, required this.intent});
  final ChatIllustrationIntent intent;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Illustration proposée : ${intent.description}',
    child: Container(
      key: const ValueKey('chatIllustrationPlaceholder'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(4, 4, 4, 20),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DomoliaColors.goldDark),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.image_outlined,
              size: 23, color: DomoliaColors.goldLight),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Illustration suggérée',
                  style: TextStyle(color: DomoliaColors.goldLight,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(intent.description,
                  style: const TextStyle(color: DomoliaColors.cream)),
              const SizedBox(height: 6),
              const Text('Génération indisponible pour le moment',
                  style: TextStyle(color: DomoliaColors.goldLight,
                      fontSize: 12)),
            ],
          )),
        ],
      ),
    ),
  );
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    super.key, required this.entry, this.onLongPress,
    this.highlighted = false,
  });
  final ChatEntry entry;
  final VoidCallback? onLongPress;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final isPlayer = entry.speaker == ChatSpeaker.player;
    final color = switch (entry.speaker) {
      ChatSpeaker.player => DomoliaColors.gold,
      ChatSpeaker.narrator => DomoliaColors.goldLight,
      ChatSpeaker.character => DomoliaColors.cream,
    };

    if (entry.speaker == ChatSpeaker.narrator) {
      // Narration is prose without a participant label, avatar, or bubble.
      return GestureDetector(
        onLongPress: onLongPress,
        child: Container(
          key: highlighted
              ? ValueKey('chatHighlightedMessage-${entry.id}') : null,
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 22),
          decoration: highlighted ? BoxDecoration(
            color: DomoliaColors.goldDark.withValues(alpha: 0.2),
            border: Border.all(color: DomoliaColors.goldDark),
            borderRadius: BorderRadius.circular(10),
          ) : null,
          child: Text(entry.text,
            key: const ValueKey('chatNarrationText'),
            style: TextStyle(
              color: DomoliaColors.cream,
              fontSize: 15, height: 1.55,
              fontStyle: entry.inProgress
                  ? FontStyle.italic : FontStyle.normal,
            ),
          ),
        ),
      );
    }
    return GestureDetector(
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ChatAvatar(entry: entry),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 3, bottom: 6),
                  child: Row(
                    children: [
                      Text(
                        entry.name,
                        key: const ValueKey('chatSpeakerName'),
                        style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      if (!isPlayer && entry.status?.isNotEmpty == true)
                        Flexible(
                          child: Text(
                            ' - ${entry.status}',
                            key: const ValueKey('chatSpeakerStatus'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: DomoliaColors.cream,
                              fontSize: 12,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Container(
                  key: highlighted
                      ? ValueKey('chatHighlightedMessage-${entry.id}') : null,
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: highlighted
                        ? DomoliaColors.goldDark.withValues(alpha: 0.3)
                        : isPlayer
                        ? const Color(0xFF624E20)
                        : entry.speaker == ChatSpeaker.narrator
                            ? DomoliaColors.surface
                            : DomoliaColors.raisedSurface,
                    borderRadius: const BorderRadius.only(
                      topRight: Radius.circular(16),
                      bottomLeft: Radius.circular(16),
                      bottomRight: Radius.circular(16),
                      topLeft: Radius.circular(4),
                    ),
                    border: Border.all(
                      color: highlighted
                          ? DomoliaColors.goldLight
                          : isPlayer
                          ? DomoliaColors.goldDark
                          : DomoliaColors.border,
                    ),
                  ),
                  child: Text(
                    isPlayer ? entry.text : _characterText(entry.text, entry.name),
                    key: const ValueKey('chatBubbleText'),
                    style: TextStyle(
                      color: DomoliaColors.cream,
                      fontSize: 15,
                      height: 1.45,
                      fontStyle: entry.inProgress
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }
}

/// UI-only compatibility for older saved bubbles. New JSONification stores
/// already-clean speeches; the literary RAW is always available separately.
String _characterText(String text, String name) {
  var visible = text.trim();
  final prefix = RegExp('^${RegExp.escape(name)}' r'\s*[:：]\s*',
      caseSensitive: false);
  visible = visible.replaceFirst(prefix, '');
  return visible.replaceAll('«', '').replaceAll('»', '').trim();
}

class _ChatAvatar extends StatelessWidget {
  const _ChatAvatar({required this.entry});
  final ChatEntry entry;

  @override
  Widget build(BuildContext context) {
    if (entry.speaker == ChatSpeaker.narrator) {
      return CircleAvatar(
        key: const ValueKey('chatNarratorAvatar'),
        radius: 21,
        backgroundColor: DomoliaColors.raisedSurface,
        child: ClipOval(
          child: Image.asset(
            'assets/images/domolia_emblem.png',
            width: 37,
            height: 37,
            fit: BoxFit.cover,
            semanticLabel: 'Avatar du narrateur',
          ),
        ),
      );
    }
    if (entry.speaker == ChatSpeaker.player) {
      return const CircleAvatar(
        key: ValueKey('chatPlayerAvatar'),
        radius: 21,
        backgroundColor: Color(0xFF705720),
        child: Icon(
          Icons.person_outline_rounded,
          color: DomoliaColors.goldLight,
        ),
      );
    }

    const palette = [
      Color(0xFF3C6659),
      Color(0xFF6B516D),
      Color(0xFF536A8D),
      Color(0xFF735B43),
      Color(0xFF6E5151),
    ];
    final hash = entry.name.runes.fold<int>(0, (a, b) => a + b);
    return CircleAvatar(
      key: const ValueKey('chatCharacterAvatar'),
      radius: 21,
      backgroundColor: palette[hash % palette.length],
      child: Text(
        entry.name.substring(0, 1).toUpperCase(),
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 19,
          color: DomoliaColors.cream,
        ),
      ),
    );
  }
}
