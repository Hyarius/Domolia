import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

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
    this.onBeforeCapture,
    this.onBeforeRestore,
    this.onAfterRestore,
    this.saveArchive,
    this.pickArchive,
    this.backupService,
    this.reloadData,
  });

  final BookLibraryController books;
  final AiConnectionController ai;
  final VoidCallback onBack;
  final Future<void> Function()? onBeforeCapture;
  final Future<void> Function()? onBeforeRestore;
  final VoidCallback? onAfterRestore;

  /// File operations are injectable so widget tests cover the actual UI and
  /// exact selected bytes without invoking a native dialog.
  final Future<bool> Function(Uint8List bytes, String name)? saveArchive;
  final Future<({String name, Uint8List bytes})?> Function()? pickArchive;
  final BackupService? backupService;
  final Future<void> Function()? reloadData;

  @override
  State<BackupSettingsPage> createState() => _BackupSettingsPageState();
}

class _BackupSettingsPageState extends State<BackupSettingsPage> {
  bool _busy = false;
  String? _message;

  BackupService get _service => widget.backupService ?? BackupService(
    books: widget.books.store as SqliteBookStore,
    profileStore: widget.ai.store,
  );

  Future<void> _run(Future<void> Function() task) async {
    if (_busy) return;
    setState(() { _busy = true; _message = null; });
    try {
      if (!widget.ai.initialized) {
        await widget.ai.initialize();
      }
      if (!widget.books.initialized) {
        await widget.books.initialize();
      }
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

  Future<bool> _saveWithPicker(Uint8List bytes, String name) async {
    final output = await FilePicker.platform.saveFile(
      dialogTitle: 'Sauvegarder mes données',
      fileName: name,
      type: FileType.custom,
      allowedExtensions: ['domolia'],
      bytes: bytes,
    );
    // The v10 Web implementation returns null after initiating a browser
    // download; there is no stable destination path to return.
    return kIsWeb || output != null;
  }

  Future<({String name, Uint8List bytes})?> _pickWithPicker() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Charger mes données',
      type: FileType.custom,
      allowedExtensions: ['domolia'],
      withData: kIsWeb,
      withReadStream: !kIsWeb,
      allowMultiple: false,
    );
    if (result == null) return null;
    final file = result.files.single;
    if (file.size > PortableBackup.maxBytes ||
        !file.name.toLowerCase().endsWith('.domolia')) {
      throw const FormatException(
        'Choisissez une sauvegarde .domolia valide (100 Mio maximum).',
      );
    }
    if (file.bytes != null) {
      return (name: file.name, bytes: file.bytes!);
    }
    final stream = file.readStream;
    if (stream == null) {
      throw const FormatException('Fichier sélectionné illisible.');
    }
    // Android may expose files via ContentResolver instead of giving a
    // filesystem path. Read the stream, with a strict bound at each chunk.
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (builder.length + chunk.length > PortableBackup.maxBytes) {
        throw const FormatException('Fichier supérieur à 100 Mio.');
      }
      builder.add(chunk);
    }
    return (name: file.name, bytes: builder.takeBytes());
  }

  Future<void> _save() => _run(() async {
    if (widget.books.legacyAvailable) {
      throw const FormatException(
        'Un ancien narrateur n’a pas encore été converti en Livre. '
        'Ouvrez Livres et importez cet ancien narrateur avant de '
        'sauvegarder, pour ne pas perdre sa configuration.',
      );
    }
    await widget.onBeforeCapture?.call();
    final backup = await _service.capture();
    final data = backup.encode();
    final now = DateTime.now().toUtc();
    final filename = 'Domolia-backup-'
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}.domolia';
    final saved = await (widget.saveArchive?.call(data, filename) ??
        _saveWithPicker(data, filename));
    if (!saved) return;
    if (mounted) {
      setState(() => _message = kIsWeb
          ? 'Téléchargement déclenché. Vérifiez le dossier de téléchargements.'
          : 'Sauvegarde enregistrée : ${backup.books.length} Livres et '
              '${backup.sessions.length} Parties.');
    }
  });

  Future<void> _load() => _run(() async {
    final picked = await (widget.pickArchive?.call() ?? _pickWithPicker());
    if (picked == null || !mounted) return;
    if (!picked.name.toLowerCase().endsWith('.domolia') ||
        picked.bytes.length > PortableBackup.maxBytes) {
      throw const FormatException(
        'Choisissez une sauvegarde .domolia valide (100 Mio maximum).',
      );
    }
    final backup = PortableBackup.decode(picked.bytes);
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
              if (backup.aiProfiles.any((profile) =>
                  profile.requiresReconfiguration))
                Text('${backup.aiProfiles.where((p) =>
                    p.requiresReconfiguration).length} profil(s) IA '
                  'introuvable(s) dans l’appareil source : '
                  'ils devront être reconfigurés.'),
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
              const Text('Les identifiants IA enregistrés par l’application '
                'ne sont pas transférés. Les profils importés devront être '
                'reconnectés. Vérifiez le texte des conversations si vous y '
                'avez saisi des informations sensibles.'),
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
    await widget.onBeforeRestore?.call();
    await _service.restore(backup, mode);
    widget.onAfterRestore?.call();
    await (widget.reloadData?.call() ?? _reloadData());
    if (mounted) {
      setState(() => _message =
          'Restauration terminée : ${backup.books.length} Livres et '
          '${backup.sessions.length} Parties traités. '
          'Vérifiez les connexions IA.');
    }
  });

  Future<void> _reloadData() async {
    await widget.ai.reloadProfiles();
    await widget.books.reload();
  }

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
          'en clair. Les clés et jetons IA enregistrés dans les paramètres, '
          'ainsi que les journaux de diagnostic, sont exclus. Si vous avez '
          'écrit des secrets dans une conversation, ils seront présents '
          'dans le texte exporté. Conservez ce fichier dans un endroit privé.'),
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
