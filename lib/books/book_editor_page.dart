import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../ai/ai_controller.dart';
import '../ai/ai_provider.dart';
import '../theme/domolia_theme.dart';
import '../logging/app_logger.dart';
import 'book_cover_loader.dart';
import 'book_definition.dart';
import 'book_lore.dart';
import 'book_lore_tab.dart';
import 'book_library_controller.dart';
import 'book_library_page.dart';
import 'book_session.dart';

class BookEditorPage extends StatefulWidget {
  const BookEditorPage({
    super.key,
    required this.book,
    required this.library,
    required this.ai,
    required this.onPlay,
  });

  final BookDefinition book;
  final BookLibraryController library;
  final AiConnectionController ai;
  final Future<void> Function(BookDefinition book, BookSession session) onPlay;

  @override
  State<BookEditorPage> createState() => BookEditorPageState();
}

class BookEditorPageState extends State<BookEditorPage> {
  late BookDefinition _book;
  late final TextEditingController _title;
  late final TextEditingController _style;
  late final TextEditingController _openings;
  Timer? _saveDelay;
  Future<void> _saveTail = Future<void>.value();
  int _editRevision = 0;
  int _savedRevision = 0;
  String? _profileId;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _book = widget.book;
    _title = TextEditingController(text: _book.title);
    _style = TextEditingController(text: _book.narrativeStyle);
    _openings = TextEditingController(text: _book.openingMessages.join('\n'));
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    await widget.ai.initialize();
    final id = await widget.library.profileFor(_book.id);
    if (mounted) setState(() => _profileId = id);
  }

  @override
  void dispose() {
    _saveDelay?.cancel();
    _title.dispose();
    _style.dispose();
    _openings.dispose();
    super.dispose();
  }

  void _queueSave() {
    _editRevision++;
    _saveDelay?.cancel();
    _saveDelay = Timer(const Duration(milliseconds: 500), () {
      _save();
    });
  }

  // Every Book write uses the same queue. Persist a snapshot of the latest
  // in-memory state so autosaves cannot overwrite lore, covers or settings.
  Future<void> _persist(BookDefinition Function(BookDefinition) change) {
    final next = change(_book);
    final revision = ++_editRevision;
    if (mounted) setState(() => _book = next);
    final pending = _saveTail.then((_) => widget.library.save(next));
    _saveTail = pending.then<void>((_) {}, onError: (Object error, StackTrace stackTrace) {});
    return pending.then((_) {
      if (mounted) setState(() => _savedRevision = revision);
    });
  }

  /// The host asks before leaving. Pending edits are saved or explicitly discarded.
  Future<bool> prepareToLeave() async {
    _saveDelay?.cancel();
    await _saveTail;
    if (_savedRevision == _editRevision) return true;
    if (await _save() && _savedRevision == _editRevision) return true;
    if (!mounted) return false;
    return await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Modifications non enregistrées'),
        content: const Text(
          'Impossible d’enregistrer les dernières modifications. '
          'Voulez-vous quitter sans les conserver ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Rester'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Quitter sans enregistrer'),
          ),
        ],
      ),
    ) ?? false;
  }

  void _show(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<bool> _save() async {
    _saveDelay?.cancel();
    final title = _title.text.trim();
    final style = _style.text.trim();
    final openings = _openings.text.split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty).toList();
    try {
      await _persist((current) => current.copyWith(
        title: title,
        narrativeStyle: style,
        openingMessages: openings,
      ));
      return true;
    } on FormatException catch (error) {
      _show(error.message);
      return false;
    } catch (failure, stackTrace) {
      AppLogger.error('Échec de sauvegarde dans l’éditeur', component: 'books',
          error: failure, stackTrace: stackTrace);
      _show('Impossible de sauvegarder ce Livre.');
      return false;
    }
  }

  Future<void> _saveLore(BookLore lore) async {
    _saveDelay?.cancel();
    final title = _title.text.trim();
    final style = _style.text.trim();
    final openings = _openings.text.split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty).toList();
    await _persist((current) => current.copyWith(
      title: title,
      narrativeStyle: style,
      openingMessages: openings,
      lore: lore,
    ));
  }

  Future<void> _chooseCover() async {
    AppLogger.info('Ouverture du sélecteur de couverture', component: 'cover');
    try {
      final chosen = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
        withData: true,
      );
      if (chosen == null || chosen.files.isEmpty) {
        AppLogger.info('Sélection de couverture annulée', component: 'cover');
        return;
      }
      final data = await BookCoverLoader.load(chosen.files.single);
      AppLogger.debug('Sauvegarde de la couverture', component: 'cover');
      await _persist((current) => current.copyWith(
        coverBase64: data.base64, coverMime: data.mime,
      ));
      AppLogger.info('Couverture enregistrée', component: 'cover');
    } on FormatException catch (failure) {
      AppLogger.warning('Couverture rejetée', component: 'cover',
        details: {'reason': failure.message});
      _show(failure.message);
    } catch (failure, stackTrace) {
      AppLogger.error('Chargement de couverture échoué', component: 'cover',
        error: failure, stackTrace: stackTrace);
      _show('Impossible de charger la couverture. Consultez Paramètres → Logs.');
    }
  }

  Future<void> _toggleNsfw(bool enabled) async {
    try {
      await _persist((current) {
        final nextTags = {...current.tags};
        if (enabled) {
          nextTags.add('nsfw');
        } else {
          nextTags.remove('nsfw');
        }
        return current.copyWith(tags: nextTags);
      });
    } catch (_) {
      _show('Impossible d’enregistrer le mode.');
    }
  }

  Future<void> _bind(String? id) async {
    try {
      await widget.library.setProfile(_book.id, id);
      if (mounted) setState(() => _profileId = id);
    } catch (_) {
      _show('Impossible de sélectionner cette configuration IA.');
    }
  }

  Future<void> _play() async {
    _saveDelay?.cancel();
    if (!await _save()) return;
    try {
      final sessions = await widget.library.sessions(_book.id);
      if (!mounted) return;
      final selection = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 440),
            child: ListView(
              shrinkWrap: true,
              children: [
                const Padding(
                  padding: EdgeInsets.all(18),
                  child: Text('Choisir une partie', style: TextStyle(
                    fontSize: 20, color: DomoliaColors.goldLight)),
                ),
                ListTile(
                  key: const ValueKey('bookNewSession'),
                  leading: const Icon(Icons.add_circle_outline),
                  title: const Text('Nouvelle partie indépendante'),
                  onTap: () => Navigator.pop(context, 'new'),
                ),
                for (final session in sessions)
                  ListTile(
                    key: ValueKey('bookSession-${session.id}'),
                    leading: const Icon(Icons.history),
                    title: Text(session.title),
                    subtitle: Text('${session.timeline.length} événements'),
                    onTap: () => Navigator.pop(context, session.id),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: ValueKey('bookPurgeSession-${session.id}'),
                          tooltip: 'Purger les diagnostics de ${session.title}',
                          icon: const Icon(Icons.cleaning_services_outlined),
                          onPressed: () async {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (dialogContext) => AlertDialog(
                                title: const Text('Purger les diagnostics ?'),
                                content: Text(
                                  'Supprimer les traces IA de « ${session.title} » ? '
                                  'Les messages et les scènes restent enregistrés.',
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
                            if (confirmed != true || !context.mounted) return;
                            try {
                              await widget.library.clearDiagnostics(session.id);
                              _show('Diagnostics de cette partie purgés.');
                            } catch (_) {
                              _show('Impossible de purger les diagnostics.');
                            }
                          },
                        ),
                        IconButton(
                          key: ValueKey('bookDeleteSession-${session.id}'),
                          tooltip: 'Supprimer ${session.title}',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (dialogContext) => AlertDialog(
                                title: const Text('Supprimer cette partie ?'),
                                content: Text(
                                  '« ${session.title} » et son historique seront '
                                  'supprimés définitivement.'),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(dialogContext, false),
                                    child: const Text('Annuler'),
                                  ),
                                  FilledButton(
                                    onPressed: () => Navigator.pop(dialogContext, true),
                                    child: const Text('Supprimer'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed != true || !context.mounted) return;
                            try {
                              await widget.library.deleteSession(session.id);
                              if (context.mounted) {
                                Navigator.pop(context, 'deleted');
                              }
                            } catch (_) {
                              _show('Impossible de supprimer cette partie.');
                            }
                          },
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      if (selection == 'deleted') {
        // The chosen part is removed from storage, never opened.
        // The next tap reloads the current list from SQLite.
        return;
      }
      if (selection == null || !mounted) return;
      final selected = selection == 'new'
          ? await widget.library.newSession(_book)
          : sessions.firstWhere((session) => session.id == selection);
      await widget.onPlay(_book, selected);
    } catch (_) {
      _show('Impossible de charger les parties de ce Livre.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DomoliaColors.background,
      bottomNavigationBar: NavigationBar(
        key: const ValueKey('bookTabs'),
        selectedIndex: _tab,
        onDestinationSelected: (tab) => setState(() => _tab = tab),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined), label: 'Livre'),
          NavigationDestination(
            icon: Icon(Icons.auto_stories_outlined), label: 'Lore'),
          NavigationDestination(
            icon: Icon(Icons.edit_note_rounded), label: 'Narrateur'),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined), label: 'Système'),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
            child: Row(children: [
              Expanded(child: Text(_book.title,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: DomoliaColors.goldLight,
                  fontSize: 22, fontWeight: FontWeight.bold,
                ))),
              TextButton.icon(
                key: const ValueKey('bookSave'),
                onPressed: () async {
                  if (await _save()) _show('Livre enregistré.');
                },
                icon: const Icon(Icons.save_outlined),
                label: const Text('Sauver'),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: FilledButton.icon(
              key: const ValueKey('bookPlay'),
              onPressed: _play,
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Commencer ou reprendre une partie'),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(child: IndexedStack(
            index: _tab,
            children: [
              ListView(
                key: const ValueKey('bookTab-0'),
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 26),
                children: _bookTab(),
              ),
              ListView(
                key: const ValueKey('bookTab-1'),
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 26),
                children: [BookLoreTab(
                  key: const ValueKey('bookLoreTab'),
                  lore: _book.lore,
                  onSave: _saveLore,
                )],
              ),
              ListView(
                key: const ValueKey('bookTab-2'),
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 26),
                children: _narratorTab(),
              ),
              ListView(
                key: const ValueKey('bookTab-3'),
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 26),
                children: _systemTab(),
              ),
            ],
          )),
        ]),
      ),
    );
  }

  List<Widget> _bookTab() => [
    TextField(
      key: const ValueKey('bookTitle'),
      controller: _title,
      maxLength: 120,
      decoration: const InputDecoration(labelText: 'Titre du Livre'),
      onChanged: (_) => _queueSave(),
    ),
    const SizedBox(height: DomoliaSpacing.section),
    const Text('Couverture', style: TextStyle(
      fontSize: 18, color: DomoliaColors.goldLight)),
    const SizedBox(height: 12),
    Center(child: SizedBox(
      width: 155, height: 220, child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BookCover(book: _book),
      ),
    )),
    const SizedBox(height: 12),
    OutlinedButton.icon(
      key: const ValueKey('bookChooseCover'),
      onPressed: _chooseCover,
      icon: const Icon(Icons.photo_library_outlined),
      label: const Text('Choisir une image locale'),
    ),
    const SizedBox(height: DomoliaSpacing.compact),
    const SizedBox(height: DomoliaSpacing.section),
    SwitchListTile(
      key: const ValueKey('bookNsfw'),
      value: _book.nsfw,
      onChanged: _toggleNsfw,
      title: const Text('NSFW'),
      subtitle: const Text(
        'Préférence de contenu adulte. Les règles de votre IA restent applicables.',
      ),
    ),
  ];

  List<Widget> _narratorTab() => [
    TextField(
      key: const ValueKey('bookNarrativeStyle'),
      controller: _style,
      maxLines: 9,
      minLines: 4,
      maxLength: 8000,
      decoration: const InputDecoration(
        labelText: 'Style narratif',
        helperText: 'Instructions narratives propres à ce Livre',
      ),
      onChanged: (_) => _queueSave(),
    ),
    const SizedBox(height: DomoliaSpacing.section),
    Text('Niveau de détail : ${_book.detailLevel} / 5',
      style: const TextStyle(
        fontSize: 18, color: DomoliaColors.goldLight)),
    Slider(
      key: const ValueKey('bookDetailSlider'),
      min: 1, max: 5, divisions: 4,
      label: BookDefinition.detailNames[_book.detailLevel - 1],
      value: _book.detailLevel.toDouble(),
      onChanged: (value) {
        final level = value.round();
        if (level == _book.detailLevel) return;
        unawaited(_persist((current) =>
          current.copyWith(detailLevel: level)).catchError((Object _) {
            _show('Impossible de sauver le niveau de détail.');
          }));
      },
    ),
    Text(BookDefinition.detailNames[_book.detailLevel - 1],
      style: const TextStyle(fontWeight: FontWeight.bold)),
    const SizedBox(height: 5),
    Text(BookDefinition.detailInstruction(_book.detailLevel)),
    const SizedBox(height: 18),

  ];

  List<Widget> _systemTab() => [
    TextField(
      key: const ValueKey('bookOpenings'),
      controller: _openings,
      minLines: 4, maxLines: 9, maxLength: 30000,
      decoration: const InputDecoration(
        labelText: 'Premiers messages possibles',
        helperText: 'Une ouverture par ligne, sélectionnée sans appel IA',
      ),
      onChanged: (_) => _queueSave(),
    ),
    const SizedBox(height: DomoliaSpacing.section),
    const Text('Configuration IA', style: TextStyle(
      color: DomoliaColors.goldLight, fontSize: 18)),
    const SizedBox(height: DomoliaSpacing.field),
    AnimatedBuilder(
      animation: widget.ai,
      builder: (context, _) {
        final profiles = widget.ai.profiles;
        final missing = _profileId != null &&
            !profiles.any((p) => p.id == _profileId);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              key: const ValueKey('bookAiProfile'),
              initialValue: _profileId ?? '',
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Connexion IA locale',
              ),
              items: [
                const DropdownMenuItem(value: '',
                  child: Text('Aucune — choisir une configuration')),
                if (missing)
                  DropdownMenuItem(value: _profileId,
                    child: const Text('Configuration supprimée')),
                for (final profile in profiles)
                  DropdownMenuItem(value: profile.id,
                    child: Text(profile.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (id) => _bind(id == '' ? null : id),
            ),
            if (missing)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text(
                  'Cette configuration IA a été supprimée. '
                  'Sélectionnez-en une nouvelle avant de jouer.',
                  style: TextStyle(color: Color(0xFFFFC7C7)),
                ),
              ),
            if (_book.nsfw && !missing) _nsfwWarning(profiles),
          ],
        );
      },
    ),
  ];

  Widget _nsfwWarning(List<AiProfile> profiles) {
    AiProfile? profile;
    for (final candidate in profiles) {
      if (candidate.id == _profileId) profile = candidate;
    }
    if (profile == null) return const SizedBox.shrink();
    return switch (profile.nsfwCompatibility) {
      AiNsfwCompatibility.supported => const SizedBox.shrink(),
      AiNsfwCompatibility.unsupported => const Padding(
        padding: EdgeInsets.only(top: 12),
        child: Text('Cette configuration IA ne prend pas en charge le mode NSFW.',
          style: TextStyle(color: Color(0xFFFFC7C7))),
      ),
      AiNsfwCompatibility.unknown => const Padding(
        padding: EdgeInsets.only(top: 12),
        child: Text(
          'Compatibilité NSFW inconnue : elle n’est pas garantie.',
          style: TextStyle(color: DomoliaColors.muted)),
      ),
    };
  }
}
