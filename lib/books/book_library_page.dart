import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/domolia_theme.dart';
import 'book_definition.dart';
import 'book_library_controller.dart';

/// Responsive grid of installed books. File sharing is explicitly initiated
/// by the player; no private sessions or AI settings are exported.
class BookLibraryPage extends StatefulWidget {
  const BookLibraryPage({
    super.key,
    required this.library,
    required this.onOpen,
  });

  final BookLibraryController library;
  final ValueChanged<BookDefinition> onOpen;

  @override
  State<BookLibraryPage> createState() => _BookLibraryPageState();
}

class _BookLibraryPageState extends State<BookLibraryPage> {
  @override
  void initState() {
    super.initState();
    widget.library.initialize();
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  Future<void> _create() async {
    try {
      final book = await widget.library.create();
      widget.onOpen(book);
    } catch (_) {
      _message('Impossible de créer le Livre.');
    }
  }

  Future<void> _import() async {
    try {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (selection == null || selection.files.isEmpty) return;
      final item = selection.files.single;
      if (item.size > BookDefinition.maxJsonBytes ||
          item.bytes == null) {
        throw const FormatException('Fichier trop volumineux ou inaccessible.');
      }
      final book = await widget.library.importBook(
        utf8.decode(item.bytes!, allowMalformed: false),
      );
      if (mounted) {
        _message('Livre importé. Sélectionnez votre connexion IA.');
        widget.onOpen(book);
      }
    } catch (error) {
      _message(error is FormatException ? error.message :
          'Impossible d’importer le fichier JSON.');
    }
  }

  Future<void> _export(BookDefinition book) async {
    try {
      final content = Uint8List.fromList(utf8.encode(book.exportJson()));
      final filename = book.title.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: 'Exporter le Livre',
        fileName: '${filename.isEmpty ? 'livre' : filename}.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: content,
      );
      if (saved != null) _message('Définition du Livre exportée.');
    } catch (_) {
      _message('Export JSON impossible.');
    }
  }

  Future<void> _delete(BookDefinition book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Supprimer ce Livre ?'),
        content: Text(
          '« ${book.title} » et toutes ses parties locales seront supprimés.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.library.remove(book.id);
    } catch (_) {
      _message('Impossible de supprimer le Livre.');
    }
  }

  Future<void> _migrateLegacy() async {
    try {
      final book = await widget.library.createFromLegacy();
      if (book != null) widget.onOpen(book);
    } catch (_) {
      _message('Migration de l’ancien narrateur impossible.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.library,
      builder: (context, _) {
        final books = widget.library.books;
        return SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Livres', style: TextStyle(
                      fontSize: 26, fontWeight: FontWeight.bold,
                      color: DomoliaColors.goldLight,
                    )),
                    const SizedBox(height: 12),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      FilledButton.icon(
                        key: const ValueKey('bookCreate'),
                        onPressed: _create,
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Créer un Livre'),
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey('bookImport'),
                        onPressed: _import,
                        icon: const Icon(Icons.file_upload_outlined),
                        label: const Text('Importer JSON'),
                      ),
                    ]),
                    if (widget.library.legacyAvailable)
                      ListTile(
                        leading: const Icon(Icons.auto_stories_outlined),
                        title: const Text('Récupérer mon ancien narrateur'),
                        subtitle: const Text(
                          'Créer une seule fois un Livre depuis vos anciens réglages.',
                        ),
                        onTap: _migrateLegacy,
                      ),
                  ],
                ),
              ),
              Expanded(
                child: !widget.library.initialized
                    ? const Center(child: CircularProgressIndicator())
                    : books.isEmpty
                        ? Center(child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.menu_book_outlined,
                                  size: 74, color: DomoliaColors.goldDark),
                                const SizedBox(height: 18),
                                const Text('Votre bibliothèque est vide',
                                  style: TextStyle(fontSize: 20,
                                    color: DomoliaColors.goldLight)),
                                const SizedBox(height: 10),
                                const Text(
                                  'Créez votre premier Livre ou importez '
                                  'une histoire partagée au format JSON.',
                                  textAlign: TextAlign.center,
                                ),
                                if (widget.library.error != null)
                                  Padding(padding: const EdgeInsets.all(12),
                                    child: Text(widget.library.error!)),
                              ],
                            ),
                          ))
                        : GridView.builder(
                            key: const ValueKey('booksGrid'),
                            padding: const EdgeInsets.all(16),
                            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 210,
                              mainAxisSpacing: 16,
                              crossAxisSpacing: 12,
                              childAspectRatio: 0.59,
                            ),
                            itemCount: books.length,
                            itemBuilder: (context, index) {
                              final book = books[index];
                              return Card(
                                key: ValueKey('book-${book.id}'),
                                color: DomoliaColors.surface,
                                clipBehavior: Clip.antiAlias,
                                child: Column(children: [
                                  Expanded(
                                    child: InkWell(
                                      onTap: () => widget.onOpen(book),
                                      child: SizedBox(
                                        width: double.infinity,
                                        child: BookCover(book: book),
                                      ),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                                    child: Text(book.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: DomoliaColors.goldLight,
                                      )),
                                  ),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      IconButton(
                                        tooltip: 'Ouvrir ${book.title}',
                                        onPressed: () => widget.onOpen(book),
                                        constraints: const BoxConstraints(minWidth: 36, minHeight: 40),
                                        padding: EdgeInsets.zero,
                                        icon: const Icon(Icons.tune_rounded),
                                      ),
                                      IconButton(
                                        tooltip: 'Exporter ${book.title}',
                                        onPressed: () => _export(book),
                                        constraints: const BoxConstraints(minWidth: 36, minHeight: 40),
                                        padding: EdgeInsets.zero,
                                        icon: const Icon(Icons.file_download_outlined),
                                      ),
                                      IconButton(
                                        tooltip: 'Supprimer ${book.title}',
                                        onPressed: () => _delete(book),
                                        constraints: const BoxConstraints(minWidth: 36, minHeight: 40),
                                        padding: EdgeInsets.zero,
                                        icon: const Icon(Icons.delete_outline),
                                      ),
                                    ],
                                  ),
                                ]),
                              );
                            },
                          ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class BookCover extends StatelessWidget {
  const BookCover({super.key, required this.book});
  final BookDefinition book;

  @override
  Widget build(BuildContext context) {
    if (book.coverBase64 != null) {
      return Image.memory(
        base64Decode(book.coverBase64!),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        semanticLabel: 'Couverture de ${book.title}',
      );
    }
    return ColoredBox(
      color: DomoliaColors.raisedSurface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_stories_rounded,
              size: 58, color: DomoliaColors.goldDark),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(book.title, textAlign: TextAlign.center,
                maxLines: 3, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: DomoliaColors.goldLight)),
            ),
          ],
        ),
      ),
    );
  }
}
