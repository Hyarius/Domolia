import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../ai/ai_controller.dart';
import '../books/book_library_controller.dart';
import '../books/book_store.dart';
import '../theme/domolia_theme.dart';
import 'backup_service.dart';
import 'portable_backup.dart';

/// One identical backup/restore page in Android and browser builds.
class BackupSettingsPage extends StatefulWidget {
  const BackupSettingsPage({
    super.key,
    required this.books,
    required this.ai,
    required this.onBack,
  });

  final BookLibraryController books;
  final AiConnectionController ai;
  final VoidCallback onBack;

  @override
  State<BackupSettingsPage> createState() => _BackupSettingsPageState();
}

class _BackupSettingsPageState extends State<BackupSettingsPage> {
  bool _busy = false;
  String? _message;

  BackupService get _service => BackupService(
    books: widget.books.store as SqliteBookStore,
    profileStore: widget.ai.store,
  );

  Future<void> _run(Future<void> Function() task) async {
    if (_busy) return;
    setState(() { _busy = true; _message = null; });
    try {
      await widget.ai.initialize();
      await widget.books.initialize();
      await task();
    } on FormatException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (_) {
      // No raw exception: platform errors can contain private local paths.
      if (mounted) {
        setState(() => _message =
            'Opération impossible. Vérifiez le fichier et le stockage local.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() => _run(() async {
    final backup = await _service.capture();
    final data = backup.encode();
    final now = DateTime.now().toUtc();
    final filename = 'Domolia-backup-'
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}.domolia';
    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Sauvegarder mes données',
      fileName: filename,
      type: FileType.custom,
      allowedExtensions: ['domolia'],
      bytes: data,
    );
    if (result == null) return;
    if (mounted) {
      setState(() => _message =
          'Sauvegarde enregistrée : ${backup.books.length} Livres et '
          '${backup.sessions.length} Parties.');
    }
  });

  Future<void> _load() => _run(() async {
    final chosen = await FilePicker.platform.pickFiles(
      dialogTitle: 'Charger mes données',
      type: FileType.any,
      withData: true,
      allowMultiple: false,
    );
    if (chosen == null || !mounted) {
      return;
    }
    final picked = chosen.files.single;
    if (!picked.name.toLowerCase().endsWith('.domolia') ||
        picked.size > PortableBackup.maxBytes ||
        picked.bytes == null) {
      throw const FormatException(
        'Choisissez une sauvegarde .domolia valide (100 Mio maximum).',
      );
    }
    final backup = PortableBackup.decode(Uint8List.fromList(picked.bytes!));
    final collisions = await _service.preview(backup, BackupRestoreMode.merge);
    if (!mounted) return;
    final mode = await showDialog<BackupRestoreMode>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Charger cette sauvegarde ?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${backup.books.length} Livres, '
                '${backup.sessions.length} Parties et '
                '${backup.aiProfiles.length} profils IA.'),
              const SizedBox(height: 10),
              Text('${collisions.bookConflicts} conflit(s) de Livres et '
                '${collisions.sessionConflicts} conflit(s) de Parties à examiner.'),
              const SizedBox(height: 10),
              const Text('Fusionner conserve vos données actuelles. '
                'Les entrées incompatibles reçoivent de nouveaux identifiants.'),
              const SizedBox(height: 8),
              const Text('Remplacer efface vos Livres et Parties actuels, '
                'y compris les diagnostics attachés à ces Parties. '
                'Les configurations IA et leurs secrets locaux sont conservés.'),
              const SizedBox(height: 8),
              const Text('Aucune clé API ni session ChatGPT n’est transférée. '
                'Il faudra reconnecter les profils importés.'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Annuler'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(
              dialogContext, BackupRestoreMode.merge,
            ),
            child: const Text('Fusionner'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              dialogContext, BackupRestoreMode.replace,
            ),
            child: const Text('Remplacer'),
          ),
        ],
      ),
    );
    if (mode == null || !mounted) return;
    if (mode == BackupRestoreMode.replace) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Remplacer toutes les données ?'),
          content: const Text('Les Livres, Parties et diagnostics actuels '
            'seront supprimés. Vérifiez que votre sauvegarde contient '
            'tout ce que vous souhaitez conserver.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Oui, remplacer'),
            ),
          ],
        ),
      );
      if (confirm != true || !mounted) return;
    }
    await _service.restore(backup, mode);
    await widget.ai.reloadProfiles();
    await widget.books.reload();
    if (mounted) {
      setState(() => _message =
          'Restauration terminée : ${backup.books.length} Livres et '
          '${backup.sessions.length} Parties traités. '
          'Vérifiez les connexions IA.');
    }
  });

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _busy ? null : widget.onBack,
            icon: const Icon(Icons.arrow_back),
            label: const Text('Paramètres'),
          ),
        ),
        const SizedBox(height: 14),
        const Text('Données et sauvegardes', style: TextStyle(
          fontSize: 25, color: DomoliaColors.goldLight,
          fontWeight: FontWeight.bold,
        )),
        const SizedBox(height: 14),
        const Text('Vos Livres, couvertures et Parties restent sur '
          'votre appareil ou votre navigateur. Une sauvegarde explicite '
          'permet de les transférer vers un autre appareil.'),
        const SizedBox(height: 14),
        const Text('Attention : la sauvegarde contient vos conversations '
          'en clair. Conservez le fichier dans un endroit privé. '
          'Elle ne contient ni clés API, ni jetons, ni journaux de diagnostic.'),
        const SizedBox(height: 22),
        FilledButton.icon(
          key: const ValueKey('backupSave'),
          onPressed: _busy ? null : _save,
          icon: const Icon(Icons.download_rounded),
          label: const Text('Sauvegarder mes données'),
        ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          key: const ValueKey('backupLoad'),
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.upload_file_rounded),
          label: const Text('Charger mes données'),
        ),
        if (_busy) const Padding(
          padding: EdgeInsets.symmetric(vertical: 18),
          child: LinearProgressIndicator(),
        ),
        if (_message != null) Padding(
          padding: const EdgeInsets.only(top: 22),
          child: Text(_message!, key: const ValueKey('backupMessage')),
        ),
      ],
    ),
  );
}
