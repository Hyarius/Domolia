import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import '../theme/domolia_theme.dart';
import 'app_logger.dart';

class AppLogsPage extends StatefulWidget {
  const AppLogsPage({super.key, this.logger, this.onBack});
  final AppLogger? logger;
  final VoidCallback? onBack;
  @override
  State<AppLogsPage> createState() => _AppLogsPageState();
}
class _AppLogsPageState extends State<AppLogsPage> {
  late final AppLogger _logger = widget.logger ?? AppLogger.current;
  List<AppLogEntry> _entries = [];
  AppLogLevel? _filter;
  String _search = '';
  bool _loading = false;

  @override
  void initState() { super.initState(); _refresh(); }
  Future<void> _refresh() async {
    setState(() => _loading = true);
    final entries = await _logger.entries();
    if (!mounted) return;
    setState(() { _entries = entries; _loading = false; });
  }
  void _show(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)));
  }
  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: await _logger.snapshot()));
    _show('Logs copiés dans le presse-papiers.');
  }
  Future<void> _export() async {
    try {
      final data = await _logger.snapshot();
      final location = await FilePicker.platform.saveFile(
        dialogTitle: 'Exporter les logs',
        fileName: 'domolia-logs.jsonl',
        type: FileType.custom, allowedExtensions: ['jsonl'],
        bytes: Uint8List.fromList(utf8.encode(data)),
      );
      if (location != null) _show('Logs exportés.');
    } catch (error, stackTrace) {
      AppLogger.error('Échec de l’export du journal', component: 'logs',
          error: error, stackTrace: stackTrace);
      _show('Impossible d’exporter les logs.');
    }
  }
  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Effacer les logs ?'),
        content: const Text('Les Livres, Parties et diagnostics IA resteront intacts.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Effacer')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _logger.clear();
    await _refresh();
    _show('Logs effacés.');
  }
  void _details(AppLogEntry entry) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${entry.level.name.toUpperCase()} — ${entry.component}'),
        content: SingleChildScrollView(child: SelectableText([
          entry.timestamp.toLocal().toIso8601String(), entry.message,
          if (entry.details.isNotEmpty) jsonEncode(entry.details),
          if (entry.errorType != null) 'Exception : ${entry.errorType}',
          if (entry.stackTrace != null) entry.stackTrace!,
        ].join('\n\n'))),
        actions: [TextButton(onPressed: () => Navigator.pop(context),
            child: const Text('Fermer'))],
      ),
    );
  }
  @override
  Widget build(BuildContext context) {
    final query = _search.toLowerCase();
    final filtered = _entries.where((entry) =>
      (_filter == null || entry.level == _filter) &&
      (entry.message.toLowerCase().contains(query) ||
       entry.component.toLowerCase().contains(query) ||
       entry.level.name.contains(query))).toList();
    return SafeArea(child: Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: Row(children: [
          if (widget.onBack != null) IconButton(
            tooltip: 'Retour', icon: const Icon(Icons.arrow_back),
            onPressed: widget.onBack),
          const Expanded(child: Text('Logs', style: TextStyle(
            color: DomoliaColors.goldLight, fontSize: 24,
            fontWeight: FontWeight.bold))),
          IconButton(tooltip: 'Actualiser', onPressed: _refresh,
              icon: const Icon(Icons.refresh)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(key: const ValueKey('logsCopy'), onPressed: _copy,
              icon: const Icon(Icons.copy), label: const Text('Copier')),
          OutlinedButton.icon(key: const ValueKey('logsExport'), onPressed: _export,
              icon: const Icon(Icons.file_upload_outlined),
              label: const Text('Exporter')),
          OutlinedButton.icon(key: const ValueKey('logsClear'), onPressed: _clear,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Effacer les logs')),
        ]),
      ),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Expanded(child: TextField(key: const ValueKey('logsSearch'),
            decoration: const InputDecoration(labelText: 'Rechercher'),
            onChanged: (value) => setState(() => _search = value))),
          const SizedBox(width: 12),
          DropdownButton<AppLogLevel?>(
            key: const ValueKey('logsLevel'), value: _filter,
            items: [
              const DropdownMenuItem(value: null, child: Text('Tous')),
              for (final level in AppLogLevel.values)
                DropdownMenuItem(value: level,
                    child: Text(level.name.toUpperCase())),
            ],
            onChanged: (value) => setState(() => _filter = value)),
        ])),
      if (_logger.failedOperations > 0)
        const Text('Des opérations du journal ont échoué.',
            style: TextStyle(color: DomoliaColors.goldLight)),
      if (_loading) const LinearProgressIndicator(),
      Expanded(child: ListView.builder(
        key: const ValueKey('logsList'), itemCount: filtered.length,
        itemBuilder: (context, index) {
          final entry = filtered[index];
          return ListTile(
            key: ValueKey('logEntry-$index'), dense: true,
            leading: Text(entry.level.name.toUpperCase(),
              style: const TextStyle(color: DomoliaColors.goldLight, fontSize: 10)),
            title: Text(entry.message, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${entry.timestamp.toLocal().toIso8601String()} · ${entry.component}',
              maxLines: 2),
            onTap: () => _details(entry),
          );
        },
      )),
    ]));
  }
}
