import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../ai/ai_controller.dart';
import '../ai/ai_diagnostics.dart';
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
    this.onExportBookJson, this.onLoadAiDiagnostics, this.onExportAiTrace,
    this.onPurgeAiDiagnostics,
  });
  final BookLibraryController library;
  final AiConnectionController ai;
  final NarrativeChatController chat;
  final String bookId;
  final String sessionId;
  final String? bookTitle;
  final String? sessionTitle;
  final VoidCallback onBack;
  /// Optional test adapter; production uses the Android file picker.
  final Future<void> Function(String fileName, Uint8List bytes)? onExportBookJson;
  /// Waits for queued SQLite diagnostic writes in production.
  final Future<List<StoredAiDiagnostic>> Function()? onLoadAiDiagnostics;
  /// Test adapter; production saves through Android's file picker.
  final Future<void> Function(String fileName, Uint8List bytes)? onExportAiTrace;
  final Future<void> Function()? onPurgeAiDiagnostics;
  @override
  State<ConversationSettingsPage> createState() => _ConversationSettingsPageState();
}

class _ConversationSettingsPageState extends State<ConversationSettingsPage> {
  String? _selected;
  String? _formatterProfile;
  String? _optimizerProfile;
  bool _loaded = false;
  bool _saving = false;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      await widget.ai.initialize();
      final session = await widget.library.session(widget.sessionId);
      if (mounted) {
        setState(() {
          _selected = session?.aiProfileId;
          _formatterProfile = session?.formatterProfileId;
          _optimizerProfile = session?.optimizerProfileId;
          _loaded = true;
        });
      }
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
      if (mounted) { setState(() => _saving = false); }
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
          if (task == 'jsonifier') {
            _formatterProfile = selected;
          } else {
            _optimizerProfile = selected;
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
                    labelText: 'Narrateur RAW — profil de cette Partie'),
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
                const SizedBox(height: 14),
                _taskProfileField(
                  task: 'jsonifier',
                  label: 'JSONificateur — profil de cette Partie',
                  value: _formatterProfile,
                  profiles: profiles,
                  inheritedLabel: 'Hériter des paramètres généraux',
                  additional: const [
                    DropdownMenuItem(
                      value: '#narrator',
                      child: Text('Même IA que le narrateur'),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _taskProfileField(
                  task: 'optimizer',
                  label: 'Optimiseur de Lore — profil de cette Partie',
                  value: _optimizerProfile,
                  profiles: profiles,
                  inheritedLabel: 'Hériter des paramètres généraux',
                  additional: const [
                    DropdownMenuItem(
                      value: '#disabled',
                      child: Text('Désactiver pour cette Partie'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Chaque tâche peut hériter de sa configuration générale '
                  'ou utiliser un profil existant. Le JSONificateur peut '
                  'également réutiliser le narrateur. L’optimisation du Lore '
                  'est facultative et ne modifie jamais le Livre original.',
                  style: TextStyle(color: DomoliaColors.muted),
                ),
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
            label: const Text('Livre (JSON brut)'),
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
          'les phases RAW/JSON et les erreurs encore disponibles. '
          'Il peut contenir des informations personnelles ; '
          'les traces supprimées ne sont pas récupérables.',
          style: TextStyle(color: DomoliaColors.muted),
        ),
      ],
    ),
  );
}
