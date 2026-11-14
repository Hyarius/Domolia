import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../ai/ai_controller.dart';
import '../ai/ai_provider.dart';
import '../theme/domolia_theme.dart';
import 'book_definition.dart';
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
  State<BookEditorPage> createState() => _BookEditorPageState();
}

class _BookEditorPageState extends State<BookEditorPage> {
  late BookDefinition _book;
  late final TextEditingController _title;
  late final TextEditingController _style;
  late final TextEditingController _openings;
  Timer? _saveDelay;
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
    _saveDelay?.cancel();
    _saveDelay = Timer(const Duration(milliseconds: 500), _save);
  }

  void _show(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<bool> _save() async {
    try {
      final updated = _book.copyWith(
        title: _title.text.trim(),
        narrativeStyle: _style.text.trim(),
        openingMessages: _openings.text.split('\n')
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty).toList(),
      );
      await widget.library.save(updated);
      _book = updated;
      return true;
    } on FormatException catch (error) {
      _show(error.message);
      return false;
    } catch (_) {
      _show('Impossible de sauvegarder ce Livre.');
      return false;
    }
  }

  Future<void> _chooseCover() async {
    try {
      final chosen = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
        withData: true,
      );
      if (chosen == null) return;
      final file = chosen.files.single;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty ||
          bytes.length > BookDefinition.maxCoverBytes) {
        throw const FormatException('Image inaccessible ou supérieure à 1 Mo.');
      }
      final suffix = file.extension?.toLowerCase();
      final mime = switch (suffix) {
        'png' => 'image/png',
        'jpg' || 'jpeg' => 'image/jpeg',
        'webp' => 'image/webp',
        _ => throw const FormatException('Type d’image invalide.'),
      };
      final next = _book.copyWith(
        coverBase64: base64Encode(bytes), coverMime: mime,
      );
      await widget.library.save(next);
      if (mounted) setState(() => _book = next);
    } on FormatException catch (error) {
      _show(error.message);
    } catch (_) {
      _show('Impossible de charger la couverture.');
    }
  }

  Future<void> _toggleNsfw(bool enabled) async {
    final nextTags = {..._book.tags};
    if (enabled) {
      nextTags.add('nsfw');
    } else {
      nextTags.remove('nsfw');
    }
    final next = _book.copyWith(tags: nextTags);
    try {
      await widget.library.save(next);
      if (mounted) setState(() => _book = next);
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
                  ),
              ],
            ),
          ),
        ),
      );
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
                onPressed: _save,
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
          Expanded(child: ListView(
            key: ValueKey('bookTab-$_tab'),
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 26),
            children: switch (_tab) {
              0 => _bookTab(),
              1 => _narratorTab(),
              _ => _systemTab(),
            },
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
    const SizedBox(height: 18),
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
    const SizedBox(height: 8),
    OutlinedButton.icon(
      onPressed: null,
      icon: Icon(Icons.auto_awesome_outlined),
      label: Text('Générer une couverture — à venir'),
    ),
    const SizedBox(height: 18),
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
    const SizedBox(height: 22),
    Text('Niveau de détail : ${_book.detailLevel} / 5',
      style: const TextStyle(
        fontSize: 18, color: DomoliaColors.goldLight)),
    Slider(
      key: const ValueKey('bookDetailSlider'),
      min: 1, max: 5, divisions: 4,
      label: BookDefinition.detailNames[_book.detailLevel - 1],
      value: _book.detailLevel.toDouble(),
      onChanged: (value) {
        final updated = _book.copyWith(detailLevel: value.round());
        setState(() => _book = updated);
        widget.library.save(updated).catchError((Object _) {
          _show('Impossible de sauver le niveau de détail.');
        });
      },
    ),
    Text(BookDefinition.detailNames[_book.detailLevel - 1],
      style: const TextStyle(fontWeight: FontWeight.bold)),
    const SizedBox(height: 5),
    Text(BookDefinition.detailInstruction(_book.detailLevel)),
    const SizedBox(height: 18),
    const Text(
      'Le protocole technique NDJSON est géré par Domolia et non éditable.',
      style: TextStyle(color: DomoliaColors.muted)),
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
    const SizedBox(height: 18),
    const Text('Configuration IA', style: TextStyle(
      color: DomoliaColors.goldLight, fontSize: 18)),
    const SizedBox(height: 8),
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
