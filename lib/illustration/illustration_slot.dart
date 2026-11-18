// ignore_for_file: prefer_interpolation_to_compose_strings
import 'package:flutter/services.dart';

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

  Future<void> _exportPrompt(BuildContext context,
      StoredIllustration record) async {
    try {
      final safeId = record.requestId.replaceAll(
        RegExp(r'[^A-Za-z0-9_-]'), '_');
      await FilePicker.platform.saveFile(
        dialogTitle: 'Exporter le prompt de l’illustration',
        fileName: 'domolia-prompt-$safeId.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: record.exportPromptBytes(),
      );
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Export du prompt impossible.')));
      }
    }
  }

  Future<void> _showFullScreen(Uint8List bytes,
      StoredIllustration record) async {
    if (!mounted) return;
    final extension = switch (record.mimeType) {
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      _ => 'png',
    };
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
                key: const ValueKey('imagePromptExport'),
                tooltip: 'Exporter le prompt (JSON)',
                onPressed: () => _exportPrompt(context, record),
                icon: const Icon(Icons.description_outlined),
              ),
              IconButton(
                key: const ValueKey('imageExport'),
                tooltip: 'Exporter l’image',
                icon: const Icon(Icons.file_download_outlined),
                onPressed: () async {
                  try {
                    await FilePicker.platform.saveFile(
                      dialogTitle: 'Exporter cette illustration',
                      fileName: 'domolia-illustration.$extension',
                      type: FileType.custom,
                      allowedExtensions: [extension],
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
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.5),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText('Fournisseur : ' + record.provider +
                    '\nModèle : ' + record.model +
                    '\nCoût connu : ' +
                    (record.costUsd == null ? 'inconnu'
                     : record.costUsd.toString() + ' USD') +
                    '\nNegative prompt : ' +
                    (record.negativePrompt.isEmpty
                       ? '(aucun)' : record.negativePrompt) +
                    '\n\nPrompt final :\n' + record.prompt),
                  ),
                ),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  Future<bool> _approvePrompt() async {
    try {
      await widget.controller.approvePrompt(widget.intent.id);
      return true;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Validation impossible : $error')));
      }
      return false;
    }
  }

  Future<void> _editPrompt(String initial) async {
    final input = TextEditingController(text: initial);
    try {
      final edited = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Modifier la description visuelle'),
          content: SizedBox(
            width: 520,
            child: TextField(
              key: const ValueKey('imagePromptEditor'),
              controller: input, maxLines: 12, maxLength: 6000,
              decoration: const InputDecoration(
                hintText: 'Décris le sujet, l’action, le décor et le cadrage.'),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Annuler')),
            FilledButton(
              key: const ValueKey('imageSavePrompt'),
              onPressed: () => Navigator.pop(dialogContext, input.text),
              child: const Text('Enregistrer')),
          ],
        ),
      );
      if (edited != null) {
        await widget.controller.editPrompt(widget.intent.id, edited);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Modification impossible : $error')));
      }
    } finally {
      input.dispose();
    }
  }

  void _showPromptActions(String prompt, IllustrationJobState? state) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            key: const ValueKey('imageActionGenerate'),
            leading: const Icon(Icons.brush_outlined),
            title: const Text('Générer cette image'),
            onTap: () async {
              Navigator.pop(sheet);
              if (state == null) {
                await widget.controller.prepare(widget.intent.id);
                return;
              }
              if (state == IllustrationJobState.ready &&
                  !await _approvePrompt()) {
                return;
              }
              widget.onGenerate();
            },
          ),
          ListTile(
            key: const ValueKey('imageActionRegeneratePrompt'),
            leading: const Icon(Icons.refresh),
            title: const Text('Régénérer le prompt'),
            enabled: state == IllustrationJobState.ready ||
                state == IllustrationJobState.approved,
            onTap: () {
              Navigator.pop(sheet);
              widget.controller.prepare(widget.intent.id, regenerate: true);
            },
          ),
          ListTile(
            key: const ValueKey('imageActionEditPrompt'),
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Éditer le prompt'),
            enabled: state == IllustrationJobState.ready ||
                state == IllustrationJobState.approved,
            onTap: () {
              Navigator.pop(sheet);
              _editPrompt(prompt);
            },
          ),
          ListTile(
            key: const ValueKey('imageActionCopyPrompt'),
            leading: const Icon(Icons.copy),
            title: const Text('Copier le prompt'),
            onTap: () {
              Clipboard.setData(ClipboardData(text: prompt));
              Navigator.pop(sheet);
            },
          ),
        ]),
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
    final prepared = record?.state == IllustrationJobState.ready;
    final approved = record?.state == IllustrationJobState.approved;
    final prompt = record?.prompt.isNotEmpty == true
        ? record!.prompt : widget.intent.description;
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
          GestureDetector(
            key: const ValueKey('imagePromptText'),
            onLongPress: working ? null :
                () => _showPromptActions(prompt, record?.state),
            child: Text(prompt,
              style: const TextStyle(color: DomoliaColors.cream)),
          ),
          if (!working && (prepared || approved)) ...[
            const SizedBox(height: 8),
            Text(prepared ? 'Description à valider'
                : 'Description validée',
              style: const TextStyle(color: DomoliaColors.goldLight)),
            Wrap(spacing: 6, children: [
              TextButton.icon(
                key: const ValueKey('imageEditPrompt'),
                onPressed: () => _editPrompt(prompt),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Éditer')),
              TextButton.icon(
                key: const ValueKey('imageRegeneratePrompt'),
                onPressed: () => widget.controller.prepare(
                    widget.intent.id, regenerate: true),
                icon: const Icon(Icons.refresh),
                label: const Text('Refaire le prompt')),
              if (prepared)
                FilledButton.icon(
                  key: const ValueKey('imageApprovePrompt'),
                  onPressed: _approvePrompt,
                  icon: const Icon(Icons.check),
                  label: const Text('Valider la description')),
            ]),
          ],
          if (available) ...[
            const SizedBox(height: 10),
            for (final file in record.fileNames)
              FutureBuilder<Uint8List?>(
                future: _image(file),
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
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
              Expanded(
                child: Text(
                  record?.state == IllustrationJobState.generating
                      ? 'Génération de l’image…'
                      : 'Préparation de la mise en scène…',
                ),
              ),
            ]),
          ] else if (prepared) ...[
            const SizedBox(height: 8),
            const Text('Valide ou modifie le prompt avant la génération.'),
          ] else ...[
            if (record?.state == IllustrationJobState.failed) ...[
              const SizedBox(height: 8),
              Text(record?.error ?? 'Génération interrompue.',
                style: const TextStyle(color: Colors.redAccent)),
            ],
            const SizedBox(height: 8),
            if (approved ||
                (record?.state == IllustrationJobState.failed &&
                    record?.prompt.isNotEmpty == true))
              OutlinedButton.icon(
                key: const ValueKey('imageGenerate'),
                onPressed: working ? null : widget.onGenerate,
                icon: const Icon(Icons.brush_outlined),
                label: Text(approved
                    ? 'Générer l’illustration'
                    : 'Réessayer (nouvelle facturation possible)'),
              )
            else
              OutlinedButton.icon(
                key: const ValueKey('imagePreparePrompt'),
                onPressed: working ? null :
                    () => widget.controller.prepare(widget.intent.id),
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('Préparer la description IA'),
              ),
          ],
        ],
      ),
    );
  }
}
