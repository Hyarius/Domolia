import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../ai/ai_controller.dart';
import '../books/book_library_controller.dart';
import '../chat/chat_controller.dart';
import '../chat/chat_exports.dart';
import '../theme/domolia_theme.dart';

/// Conversation-level settings only select already configured AI profiles.
class ConversationSettingsPage extends StatefulWidget {
  const ConversationSettingsPage({
    super.key, required this.library, required this.ai,
    required this.chat, required this.bookId, required this.sessionId,
    this.bookTitle, this.sessionTitle, required this.onBack,
  });
  final BookLibraryController library;
  final AiConnectionController ai;
  final NarrativeChatController chat;
  final String bookId;
  final String sessionId;
  final String? bookTitle;
  final String? sessionTitle;
  final VoidCallback onBack;
  @override
  State<ConversationSettingsPage> createState() => _ConversationSettingsPageState();
}

class _ConversationSettingsPageState extends State<ConversationSettingsPage> {
  String? _selected;
  bool _loaded = false;
  bool _saving = false;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      await widget.ai.initialize();
      final session = await widget.library.session(widget.sessionId);
      if (mounted) setState(() {
        _selected = session?.aiProfileId;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _loaded = true);
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

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ListView(
      key: const ValueKey('conversationSettings'),
      padding: const EdgeInsets.all(22),
      children: [
        Row(children: [
          IconButton(tooltip: 'Retour à la conversation',
              onPressed: widget.onBack, icon: const Icon(Icons.arrow_back)),
          const Expanded(child: Text('Paramètres de la conversation',
            style: TextStyle(color: DomoliaColors.goldLight,
                fontSize: 21, fontWeight: FontWeight.bold))),
        ]),
        const SizedBox(height: 24),
        const Text('Connexion IA', style: TextStyle(
            color: DomoliaColors.goldLight, fontSize: 18)),
        if (!_loaded) const LinearProgressIndicator()
        else AnimatedBuilder(
          animation: widget.ai,
          builder: (context, _) {
            final profiles = widget.ai.profiles;
            final exists = _selected == null ||
                profiles.any((profile) => profile.id == _selected);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!exists) const Text(
                  'La configuration précédente a été supprimée.',
                  style: TextStyle(color: DomoliaColors.goldLight)),
                DropdownButtonFormField<String>(
                  key: ValueKey(_selected ?? 'conversationDefaultProfile'),
                  initialValue: exists ? _selected ?? '' : '',
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Profil IA de cette Partie'),
                  items: [
                    const DropdownMenuItem(value: '',
                        child: Text('Profil par défaut du Livre')),
                    for (final profile in profiles)
                      DropdownMenuItem(value: profile.id,
                          child: Text(profile.name,
                              overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: _saving ? null : _setProfile,
                ),
                const SizedBox(height: 12),
                const Text('Choisissez un profil IA déjà configuré. '
                  'La création des profils reste dans les paramètres généraux.',
                  style: TextStyle(color: DomoliaColors.muted)),
              ],
            );
          },
        ),
        const SizedBox(height: 28),
        const Divider(),
        const SizedBox(height: 14),
        const Text('Historique', style: TextStyle(
            color: DomoliaColors.goldLight, fontSize: 18)),
        const SizedBox(height: 14),
        FilledButton.icon(
          key: const ValueKey('conversationExport'),
          onPressed: _export,
          icon: const Icon(Icons.file_download_outlined),
          label: const Text('Exporter la conversation'),
        ),
      ],
    ),
  );
}
