import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../ai/ai_diagnostics.dart';
import '../theme/domolia_theme.dart';
import 'chat_controller.dart';
import 'chat_protocol.dart';
import 'chat_exports.dart';

enum _ChatExportAction { conversation, requestAndResponse, purgeDiagnostics }

class _TranscriptChoice {
  const _TranscriptChoice(this.scope, this.count);
  final ChatExportScope scope;
  final int count;
}

class GroupChatPage extends StatefulWidget {
  const GroupChatPage({
    super.key,
    required this.controller,
    required this.onOpenSettings,
    this.bookTitle,
    this.sessionTitle,
    this.onLoadDiagnostics,
    this.onPurgeDiagnostics,
  });

  final NarrativeChatController controller;
  final VoidCallback onOpenSettings;
  final String? bookTitle;
  final String? sessionTitle;
  final Future<List<StoredAiDiagnostic>> Function()? onLoadDiagnostics;
  final Future<void> Function()? onPurgeDiagnostics;

  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends State<GroupChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scrollToLatest);
  }

  @override
  void didUpdateWidget(covariant GroupChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_scrollToLatest);
      widget.controller.addListener(_scrollToLatest);
    }
  }

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scrollToLatest);
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

  Future<void> _exportConversation() async {
    var scope = ChatExportScope.complete;
    var invalid = false;
    var number = '3';
    final choice = await showDialog<_TranscriptChoice>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Exporter la conversation'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<ChatExportScope>(
                  key: const ValueKey('chatExportScope'),
                  initialValue: scope,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Portée de l’export'),
                  items: const [
                    DropdownMenuItem(
                      value: ChatExportScope.complete,
                      child: Text('Toute la conversation'),
                    ),
                    DropdownMenuItem(
                      value: ChatExportScope.lastScenes,
                      child: Text('X dernières scènes'),
                    ),
                    DropdownMenuItem(
                      value: ChatExportScope.lastMessages,
                      child: Text('X derniers messages'),
                    ),
                  ],
                  onChanged: (selected) {
                    if (selected != null) {
                      setDialogState(() {
                        scope = selected;
                        invalid = false;
                      });
                    }
                  },
                ),
                if (scope != ChatExportScope.complete) ...[
                  const SizedBox(height: 14),
                  TextFormField(
                    key: const ValueKey('chatExportCount'),
                    initialValue: number,
                    onChanged: (value) => number = value,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Nombre',
                      errorText: invalid ? 'Entre 1 et 50 000' : null,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Annuler'),
              ),
              FilledButton(
                onPressed: () {
                  final count = scope == ChatExportScope.complete
                      ? 1 : int.tryParse(number);
                  if (count == null || count < 1 || count > 50000) {
                    setDialogState(() => invalid = true);
                    return;
                  }
                  Navigator.pop(dialogContext, _TranscriptChoice(scope, count));
                },
                child: const Text('Exporter'),
              ),
            ],
          ),
        ),
      );
    if (choice == null || !mounted) return;
    final data = exportConversation(
      widget.controller.timeline,
      scope: choice.scope,
      count: choice.count,
      bookTitle: widget.bookTitle,
      sessionTitle: widget.sessionTitle,
    );
    await _saveDiagnostic(
      'domolia-conversation-${DateTime.now().millisecondsSinceEpoch}.json',
      data,
    );
  }

  Future<void> _exportExchange() async {
    try {
      final saved = await (widget.onLoadDiagnostics?.call() ??
          Future<List<StoredAiDiagnostic>>.value([]));
      final choices = <StoredAiDiagnostic>[...saved];
      final exchange = widget.controller.lastExchange;
      if (exchange != null &&
          !choices.any((d) => d.createdAtUtc == exchange.createdAtUtc)) {
        choices.insert(0, StoredAiDiagnostic(
          id: 'latest',
          sessionId: '',
          createdAtUtc: exchange.createdAtUtc,
          content: exchange.exportJson(),
        ));
      }
      if (choices.isEmpty) {
        _showExportMessage('Aucune requête IA enregistrée dans cette conversation.');
        return;
      }
      if (!mounted) return;
      StoredAiDiagnostic? selected;
      if (choices.length == 1) {
        selected = choices.single;
      } else {
        selected = await showModalBottomSheet<StoredAiDiagnostic>(
          context: context,
          isScrollControlled: true,
          builder: (sheetContext) => SafeArea(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 460),
              child: ListView(
                shrinkWrap: true,
                children: [
                  const ListTile(
                    title: Text('Choisir une requête IA'),
                    subtitle: Text('Les échanges les plus récents apparaissent en premier.'),
                  ),
                  for (final item in choices)
                    ListTile(
                      key: ValueKey('aiTrace-${item.id}'),
                      leading: const Icon(Icons.description_outlined),
                      title: Text(item.model,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${item.createdAtUtc.toLocal()} · '
                        'HTTP ${item.statusCode?.toString() ?? "—"}'),
                      onTap: () => Navigator.pop(sheetContext, item),
                    ),
                ],
              ),
            ),
          ),
        );
      }
      if (selected == null) return;
      await _saveDiagnostic(
        'domolia-requete-reponse-${selected.createdAtUtc.microsecondsSinceEpoch}.json',
        selected.data,
      );
    } catch (_) {
      _showExportMessage('Impossible de lire les diagnostics IA enregistrés.');
    }
  }

  Future<void> _purgeDiagnostics() async {
    if (widget.controller.busy || widget.onPurgeDiagnostics == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Purger les diagnostics ?'),
        content: const Text(
          'Supprimer définitivement les requêtes et réponses IA '
          'enregistrées pour cette partie ? Les messages et les scènes '
          'de la conversation seront conservés.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Purger'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.onPurgeDiagnostics!();
      widget.controller.forgetLastExchange();
      _showExportMessage('Diagnostics de cette partie supprimés.');
    } catch (_) {
      _showExportMessage('Impossible de purger les diagnostics.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = widget.controller;
    return AnimatedBuilder(
      animation: chat,
      builder: (context, _) {
        final transcript = [
          ...chat.timeline,
          if (chat.preview != null) chat.preview!,
        ];
        return SafeArea(
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 13),
                decoration: const BoxDecoration(
                  color: DomoliaColors.surface,
                  border: Border(
                    bottom: BorderSide(color: DomoliaColors.border),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.forum_outlined,
                      color: DomoliaColors.goldLight,
                      size: 27,
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Conversation de groupe',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: DomoliaColors.goldLight,
                            ),
                          ),
                          Text(
                            'Vous · Narrateur · Personnages',
                            style: TextStyle(
                              fontSize: 12,
                              color: DomoliaColors.muted,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    PopupMenuButton<_ChatExportAction>(
                      key: const ValueKey('chatExportMenu'),
                      tooltip: 'Options de la conversation',
                      icon: const Icon(Icons.ios_share_outlined,
                        color: DomoliaColors.goldLight),
                      onSelected: (action) {
                        switch (action) {
                          case _ChatExportAction.conversation:
                            _exportConversation();
                          case _ChatExportAction.requestAndResponse:
                            _exportExchange();
                          case _ChatExportAction.purgeDiagnostics:
                            _purgeDiagnostics();
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: _ChatExportAction.conversation,
                          child: Text('Exporter la conversation'),
                        ),
                        PopupMenuItem(
                          value: _ChatExportAction.requestAndResponse,
                          enabled: !chat.busy &&
                              (chat.lastExchange != null ||
                                  widget.onLoadDiagnostics != null),
                          child: const Text('Requête IA + réponse brute'),
                        ),
                        PopupMenuItem(
                          value: _ChatExportAction.purgeDiagnostics,
                          enabled: !chat.busy &&
                              widget.onPurgeDiagnostics != null,
                          child: const Text('Purger les diagnostics'),
                        ),
                      ],
                    ),
                    IconButton(
                      tooltip: 'Configurer le fournisseur IA',
                      onPressed: widget.onOpenSettings,
                      icon: const Icon(
                        Icons.tune_rounded,
                        color: DomoliaColors.goldLight,
                      ),
                    ),
                  ],
                ),
              ),
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
                          return _ChatBubble(
                            key: ValueKey('chat-entry-${entry.id}'),
                            entry: entry as ChatEntry,
                          );
                        },
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
                        child: Text(
                          chat.error!,
                          style: const TextStyle(color: Color(0xFFFFE0E0)),
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
              if (!chat.busy &&
                  chat.error == null &&
                  chat.messages.any((m) => m.speaker != ChatSpeaker.player))
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const ValueKey('chatRegenerate'),
                    onPressed: chat.regenerate,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Régénérer'),
                  ),
                ),
              if (chat.modelUsed != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 5, 18, 5),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Modèle : ${chat.modelUsed!}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: DomoliaColors.muted,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      if (chat.promptTokens != null ||
                          chat.completionTokens != null)
                        Text(
                          'Tokens : ${chat.promptTokens?.toString() ?? '—'} / ${chat.completionTokens?.toString() ?? '—'}',
                          style: const TextStyle(
                            color: DomoliaColors.muted,
                            fontSize: 11,
                          ),
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
                              onPressed: _send,
                              icon: const Icon(Icons.arrow_upward_rounded),
                            ),
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
                'Décrivez votre première action. Le narrateur et les '
                'personnages apparaîtront chacun avec leur avatar '
                'et leur propre bulle de dialogue.',
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

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({super.key, required this.entry});
  final ChatEntry entry;

  @override
  Widget build(BuildContext context) {
    final isPlayer = entry.speaker == ChatSpeaker.player;
    final color = switch (entry.speaker) {
      ChatSpeaker.player => DomoliaColors.gold,
      ChatSpeaker.narrator => DomoliaColors.goldLight,
      ChatSpeaker.character => DomoliaColors.cream,
    };

    return Padding(
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
                  child: Text(
                    entry.name,
                    key: const ValueKey('chatSpeakerName'),
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: isPlayer
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
                      color: isPlayer
                          ? DomoliaColors.goldDark
                          : DomoliaColors.border,
                    ),
                  ),
                  child: Text(
                    entry.text,
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
    );
  }
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
