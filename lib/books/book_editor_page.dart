import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../ai/ai_controller.dart';
import '../ai/ai_provider.dart';
import '../theme/domolia_theme.dart';
import '../chat/narrative_tuning_editor.dart';
import '../chat/narrator.dart';
import '../chat/chat_protocol.dart';
import '../logging/app_logger.dart';
import '../illustration/image_preferences.dart';
import 'book_cover_loader.dart';
import 'book_cover_generation.dart';
import '../illustration/image_providers.dart';
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
    this.initialTab = 0,
    this.imagePreferences,
  });

  final BookDefinition book;
  final BookLibraryController library;
  final AiConnectionController ai;
  final Future<void> Function(BookDefinition book, BookSession session) onPlay;
  final int initialTab;
  final ImagePreferences? imagePreferences;

  @override
  State<BookEditorPage> createState() => BookEditorPageState();
}

class BookEditorPageState extends State<BookEditorPage> {
  late BookDefinition _book;
  late final TextEditingController _title;
  late final TextEditingController _style;
  late final TextEditingController _keywords;
  late final TextEditingController _openings;
  late final TextEditingController _visualStyle;
  late final TextEditingController _negativePrompt;
  Timer? _saveDelay;
  Future<void> _saveTail = Future<void>.value();
  int _editRevision = 0;
  int _savedRevision = 0;
  String? _profileId;
  bool _coverBusy = false;
  late int _tab;

  @override
  void initState() {
    super.initState();
    _book = widget.book;
    _tab = widget.initialTab;
    _title = TextEditingController(text: _book.title);
    _style = TextEditingController(text: _book.narrativeStyle);
    _keywords = TextEditingController(
        text: _book.tuning.styleKeywords.join(', '));
    _openings = TextEditingController(text: _book.openingMessages.join('\n'));
    _visualStyle = TextEditingController(text: _book.illustrationSettings.style);
    _negativePrompt =
        TextEditingController(text: _book.illustrationSettings.negativePrompt);
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
    _keywords.dispose();
    _openings.dispose();
    _visualStyle.dispose();
    _negativePrompt.dispose();
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
    if (_coverBusy) {
      _show('Une couverture est en cours de génération. '
          'Attendez sa sauvegarde avant de quitter le Livre.');
      return false;
    }
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
        tuning: current.tuning.copyWith(
          styleKeywords: NarrativeTuning.parseKeywords(_keywords.text)),
        illustrationSettings: current.illustrationSettings.copyWith(
          style: _visualStyle.text.trim(),
          negativePrompt: _negativePrompt.text.trim()),
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
      tuning: current.tuning.copyWith(
        styleKeywords: NarrativeTuning.parseKeywords(_keywords.text)),
      illustrationSettings: current.illustrationSettings.copyWith(
        style: _visualStyle.text.trim(),
        negativePrompt: _negativePrompt.text.trim()),
      lore: lore,
    ));
  }

  Future<void> _generateCover() async {
    if (_coverBusy) return;
    if (!await _save() || !mounted) return;

    // The editor opens with the Book's portable JSON value, not an
    // ephemeral global preference. Cancelling does not change the Book.
    final description = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _BookCoverPromptDialog(
        initialPrompt: _book.illustrationSettings.coverPrompt,
        replacingCover: _book.coverBase64 != null,
      ),
    );
    if (description == null || !mounted) return;
    try {
      await _persist((current) => current.copyWith(
        illustrationSettings: current.illustrationSettings.copyWith(
          coverPrompt: description)));
    } on FormatException catch (failure) {
      _show(failure.message);
      return;
    } catch (failure, stackTrace) {
      AppLogger.error('Sauvegarde de description de couverture échouée',
          component: 'cover', error: failure, stackTrace: stackTrace);
      _show('Impossible d’enregistrer la description de couverture.');
      return;
    }

    // Save the text even if no image API is configured, so the author
    // can return to it later without an unwanted network operation.
    if (widget.imagePreferences == null) {
      _show('Génération d’image non configurée. '
          'Ouvrez les réglages des IA graphiques.');
      return;
    }

    final snapshot = _book;
    setState(() => _coverBusy = true);
    try {
      await widget.ai.initialize();
      await widget.imagePreferences!.initialize();
      final generator = BookCoverGenerator();
      final generated = await generator.generate(
        book: snapshot,
        connection: widget.imagePreferences!.application,
        profiles: widget.ai.profiles);
      if (!mounted) return;
      if (BookCoverGenerator.buildPrompt(_book) !=
          BookCoverGenerator.buildPrompt(snapshot)) {
        _show('Le Livre a été modifié pendant la génération. '
            'La couverture n’a pas été remplacée.');
        return;
      }
      await _persist((current) => current.copyWith(
        coverMime: generated.cover.mime,
        coverBase64: generated.cover.base64));
      final price = generated.costUsd == null
          ? 'inconnu' : '${generated.costUsd} USD';
      _show('Couverture générée et enregistrée. Coût signalé : $price.');
    } on ImageGenerationFailure catch (failure) {
      _show(failure.message);
    } on FormatException catch (failure) {
      _show(failure.message);
    } catch (failure, stackTrace) {
      AppLogger.error('Génération de couverture échouée',
        component: 'cover', error: failure, stackTrace: stackTrace);
      _show('Impossible de générer la couverture. '
          'Vérifiez les réglages graphiques et vos crédits.');
    } finally {
      if (mounted) setState(() => _coverBusy = false);
    }
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
    if (_coverBusy) {
      _show('Une couverture est en cours de génération.');
      return;
    }
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
            key: ValueKey('bookNav-0'),
            icon: Icon(Icons.menu_book_outlined), label: 'Livre'),
          NavigationDestination(
            key: ValueKey('bookNav-1'),
            icon: Icon(Icons.auto_stories_outlined), label: 'Lore'),
          NavigationDestination(
            key: ValueKey('bookNav-2'),
            icon: Icon(Icons.edit_note_rounded), label: 'Narrateur'),
          NavigationDestination(
            key: ValueKey('bookNav-3'),
            icon: Icon(Icons.settings_outlined), label: 'Système'),
          NavigationDestination(
            key: ValueKey('bookNav-4'),
            icon: Icon(Icons.palette_outlined), label: 'Images'),
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
              ListView(
                key: const ValueKey('bookTab-4'),
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 26),
                children: _illustrationTab(),
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
      onPressed: _coverBusy ? null : _chooseCover,
      icon: const Icon(Icons.photo_library_outlined),
      label: const Text('Choisir une image locale'),
    ),
    const SizedBox(height: DomoliaSpacing.compact),
    OutlinedButton.icon(
      key: const ValueKey('bookGenerateCover'),
      onPressed: _coverBusy ? null : _generateCover,
      icon: const Icon(Icons.auto_awesome_outlined),
      label: const Text('Générer une couverture avec l’IA'),
    ),
    if (_coverBusy)
      const Padding(
        key: ValueKey('bookCoverGenerating'),
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          SizedBox(width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 12),
          Expanded(child: Text('Illustrateur dessine la couverture…')),
        ]),
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
    const SizedBox(height: DomoliaSpacing.section),
    NarrativeTuningEditor(
      keyPrefix: 'bookNarrator',
      tuning: _book.tuning,
      keywordsController: _keywords,
      onTuningChanged: (tuning) {
        setState(() => _book = _book.copyWith(tuning: tuning));
        _queueSave();
      },
      onKeywordsChanged: () {
        setState(() {});
        _queueSave();
      },
    ),
  ];

  List<Widget> _illustrationTab() => [
    const Text('Direction artistique du Livre',
      style: TextStyle(fontSize: 19, color: DomoliaColors.goldLight,
        fontWeight: FontWeight.bold)),
    const SizedBox(height: 8),
    const Text('Ces options appartiennent au Livre et sont incluses dans '
      'son export. Le fournisseur, la clé API et le modèle restent '
      'configurés dans les réglages des IA graphiques.'),
    const SizedBox(height: DomoliaSpacing.section),
    DropdownButtonFormField<IllustrationMode>(
      key: ValueKey('bookIllustration-${_book.illustrationMode.name}'),
      initialValue: _book.illustrationMode,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Illustrations du Livre'),
      items: const [
        DropdownMenuItem(value: IllustrationMode.disabled,
            child: Text('Désactivées')),
        DropdownMenuItem(value: IllustrationMode.suggestions,
            child: Text('Suggestions (sans génération)')),
        DropdownMenuItem(value: IllustrationMode.automatic,
            child: Text('Automatique (préparation uniquement)')),
      ],
      onChanged: (mode) {
        if (mode == null || mode == _book.illustrationMode) return;
        unawaited(_persist((current) =>
            current.copyWith(illustrationMode: mode)).catchError((Object _) {
          _show('Impossible de sauvegarder les illustrations.');
        }));
      },
    ),
    const SizedBox(height: DomoliaSpacing.section),
    TextField(
      key: const ValueKey('bookImageStyle'),
      controller: _visualStyle, maxLength: 160,
      minLines: 2, maxLines: 4,
      decoration: const InputDecoration(
        labelText: 'Style graphique',
        helperText: 'Direction artistique commune aux illustrations du Livre'),
      onChanged: (_) => _queueSave(),
    ),
    const SizedBox(height: DomoliaSpacing.section),
    TextField(
      key: const ValueKey('bookImageNegativePrompt'),
      controller: _negativePrompt, maxLength: 1500,
      minLines: 3, maxLines: 7,
      decoration: const InputDecoration(
        labelText: 'Éléments à éviter (negative prompt)',
        helperText: 'Par exemple : texte, sous-titres, bulles, '
          'filigranes et signatures. Les modèles peuvent encore produire '
          'des éléments indésirables.'),
      onChanged: (_) => _queueSave(),
    ),
    const SizedBox(height: DomoliaSpacing.section),
    DropdownButtonFormField<String>(
      key: const ValueKey('bookImageSize'),
      initialValue: _book.illustrationSettings.size,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Taille / format'),
      items: [
        for (final size in BookIllustrationSettings.supportedSizes)
          DropdownMenuItem(value: size, child: Text(size)),
      ],
      onChanged: (size) {
        if (size == null || size == _book.illustrationSettings.size) return;
        unawaited(_persist((book) => book.copyWith(
          illustrationSettings:
              book.illustrationSettings.copyWith(size: size))).catchError(
          (Object _) => _show('Impossible de sauvegarder le format.')));
      },
    ),
    const SizedBox(height: DomoliaSpacing.section),
    DropdownButtonFormField<String>(
      key: const ValueKey('bookImageQuality'),
      initialValue: _book.illustrationSettings.quality ?? 'auto',
      decoration: const InputDecoration(labelText: 'Qualité graphique'),
      items: [
        const DropdownMenuItem(value: 'auto',
          child: Text('Défaut du fournisseur')),
        for (final quality in BookIllustrationSettings.supportedQualities)
          DropdownMenuItem(value: quality, child: Text(quality)),
      ],
      onChanged: (quality) {
        if (quality == null) return;
        unawaited(_persist((book) => book.copyWith(
          illustrationSettings: book.illustrationSettings.copyWith(
            quality: quality, clearQuality: quality == 'auto'))).catchError(
          (Object _) => _show('Impossible de sauvegarder la qualité.')));
      },
    ),
    const SizedBox(height: DomoliaSpacing.section),
    DropdownButtonFormField<int>(
      key: const ValueKey('bookImageCount'),
      initialValue: _book.illustrationSettings.count,
      decoration: const InputDecoration(labelText: 'Images par demande'),
      items: [
        for (var count = 1; count <= 4; count++)
          DropdownMenuItem(value: count, child: Text('$count')),
      ],
      onChanged: (count) {
        if (count == null || count == _book.illustrationSettings.count) return;
        unawaited(_persist((book) => book.copyWith(
          illustrationSettings: book.illustrationSettings.copyWith(
            count: count))).catchError(
          (Object _) => _show('Impossible de sauvegarder le nombre d’images.')));
      },
    ),
    const SizedBox(height: DomoliaSpacing.section),
    const Text('Certaines combinaisons de format, qualité et quantité '
      'peuvent ne pas être prises en charge par le modèle API sélectionné. '
      'Domolia affiche alors une erreur avant de lancer une génération '
      'facturable.'),
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

class _BookCoverPromptDialog extends StatefulWidget {
  const _BookCoverPromptDialog({
    required this.initialPrompt,
    required this.replacingCover,
  });

  final String initialPrompt;
  final bool replacingCover;

  @override
  State<_BookCoverPromptDialog> createState() => _BookCoverPromptDialogState();
}

class _BookCoverPromptDialogState extends State<_BookCoverPromptDialog> {
  late final TextEditingController _description;

  @override
  void initState() {
    super.initState();
    _description = TextEditingController(text: widget.initialPrompt);
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Description de la couverture'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Décrivez ce que l’illustrateur doit dessiner. '
            'Cette description vient du JSON du Livre et y sera '
            'enregistrée si vous confirmez.'),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('bookCoverDescription'),
            controller: _description,
            minLines: 4,
            maxLines: 8,
            maxLength: 2000,
            autofocus: false,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Image à générer',
              hintText: 'Personnages visibles, décor, ambiance, cadrage…'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          const Text('Le style graphique et les éléments à exclure '
            'proviennent aussi des paramètres du Livre.'),
          const SizedBox(height: 8),
          Text('Génération facturable : coût avant requête inconnu. '
            'Une seule image sera demandée. '
            '${widget.replacingCover ? "L’ancienne couverture sera remplacée uniquement après succès." : ""}'),
        ],
      ),
    ),
    actions: [
      TextButton(
        key: const ValueKey('bookCoverCancel'),
        onPressed: () => Navigator.pop(context),
        child: const Text('Annuler'),
      ),
      FilledButton(
        key: const ValueKey('bookCoverConfirmGeneration'),
        onPressed: _description.text.trim().isEmpty ||
                _description.text.length > 2000
            ? null : () => Navigator.pop(context, _description.text.trim()),
        child: const Text('Générer la couverture'),
      ),
    ],
  );
}
