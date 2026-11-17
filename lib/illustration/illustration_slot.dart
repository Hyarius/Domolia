import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../chat/chat_protocol.dart';
import '../theme/domolia_theme.dart';
import 'illustration_controller.dart';
import 'illustration_records.dart';

class IllustrationSlot extends StatefulWidget {
  const IllustrationSlot({
    super.key, required this.intent, required this.controller,
    required this.onGenerate,
  });
  final ChatIllustrationIntent intent;
  final IllustrationController controller;
  final VoidCallback onGenerate;

  @override
  State<IllustrationSlot> createState() => _IllustrationSlotState();
}

class _IllustrationSlotState extends State<IllustrationSlot> {
  String _loadedRequest = '';
  final Map<String, Future<Uint8List?>> _imageCache = {};

  void _refreshCache() {
    final record = widget.controller.forIntent(widget.intent.id);
    final newRequest = record?.requestId ?? '';
    if (newRequest != _loadedRequest) {
      _loadedRequest = newRequest;
      _imageCache.clear();
    }
  }

  Future<Uint8List?> _image(String name) =>
      _imageCache.putIfAbsent(name,
          () => widget.controller.files.read(name));

  Future<void> _showFullScreen(Uint8List bytes,
      StoredIllustration record) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: SafeArea(
          child: Column(children: [
            Row(children: [
              IconButton(
                tooltip: 'Fermer',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close)),
              const Spacer(),
              IconButton(
                key: const ValueKey('imageExport'),
                tooltip: 'Exporter l’image',
                icon: const Icon(Icons.file_download_outlined),
                onPressed: () async {
                  try {
                    await FilePicker.platform.saveFile(
                      dialogTitle: 'Exporter cette illustration',
                      fileName: 'domolia-illustration.png',
                      type: FileType.custom,
                      allowedExtensions: ['png'],
                      bytes: bytes,
                    );
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Export impossible.')));
                    }
                  }
                }),
            ]),
            Expanded(child: Center(
              child: InteractiveViewer(
                minScale: 0.5, maxScale: 5,
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
            )),
            ExpansionTile(
              title: const Text('Prompt et modèle'),
              children: [
                Padding(padding: const EdgeInsets.all(12),
                  child: SelectableText('Fournisseur : ' + record.provider +
                    '\nModèle : ' + record.model +
                    '\nCoût connu : ' +
                    (record.costUsd == null ? 'inconnu'
                     : record.costUsd.toString() + ' USD') +
                    '\n\n' + record.prompt)),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _refreshCache();
    final record = widget.controller.forIntent(widget.intent.id);
    final working = widget.controller.isBusy(widget.intent.id);
    final available = record?.state == IllustrationJobState.available &&
        record!.fileNames.isNotEmpty;
    return Container(
      key: ValueKey('imageSlot-' + widget.intent.id.toString()),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(4, 4, 4, 20),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: DomoliaColors.goldDark),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Illustration',
            style: TextStyle(color: DomoliaColors.goldLight,
                fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(widget.intent.description,
            style: const TextStyle(color: DomoliaColors.cream)),
          if (available) ...[
            const SizedBox(height: 10),
            for (final file in record.fileNames)
              FutureBuilder<Uint8List?>(
                future: _image(file),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('Chargement de l’image…'),
                    );
                  }
                  final bytes = snapshot.data;
                  if (bytes == null) {
                    return const Text('Fichier image introuvable.');
                  }
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      key: const ValueKey('chatGeneratedImage'),
                      onTap: () => _showFullScreen(bytes, record),
                      child: Image.memory(
                        bytes, fit: BoxFit.contain,
                        height: 300, width: double.infinity,
                        errorBuilder: (_, _, _) =>
                          const Text('Impossible de décoder l’image.'),
                      ),
                    ),
                  );
                },
              ),
            TextButton.icon(
              key: const ValueKey('imageRegenerate'),
              onPressed: working ? null : widget.onGenerate,
              icon: const Icon(Icons.refresh),
              label: const Text('Régénérer (nouvelle facturation)'),
            ),
          ] else if (working ||
              record?.state == IllustrationJobState.preparing ||
              record?.state == IllustrationJobState.generating) ...[
            const SizedBox(height: 10),
            Row(children: [
              const SizedBox(width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              Text(record?.state == IllustrationJobState.generating
                  ? 'Génération de l’image…'
                  : 'Préparation de la mise en scène…'),
            ]),
          ] else ...[
            if (record?.state == IllustrationJobState.failed) ...[
              const SizedBox(height: 8),
              Text(record?.error ?? 'Génération interrompue.',
                style: const TextStyle(color: Colors.redAccent)),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('imageGenerate'),
              onPressed: working ? null : widget.onGenerate,
              icon: const Icon(Icons.brush_outlined),
              label: Text(record == null
                  ? 'Générer l’illustration'
                  : 'Réessayer (nouvelle facturation possible)'),
            ),
          ],
        ],
      ),
    );
  }
}
