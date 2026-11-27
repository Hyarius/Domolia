import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'book_definition.dart';

typedef BookFileWriter = Future<void> Function(String name, Uint8List bytes);

Future<void> exportBookFile(BookDefinition book, void Function(String) notify,
    {BookFileWriter? writer}) async {
  try {
    final bytes = Uint8List.fromList(utf8.encode(book.exportJson()));
    final stem = book.title.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final name = '${stem.isEmpty ? 'livre' : stem}.json';
    if (writer != null) {
      await writer(name, bytes);
    } else {
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: 'Exporter le Livre',
        fileName: name,
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: bytes,
      );
      if (saved == null) return;
    }
    notify('Livre exporté.');
  } catch (_) {
    notify('Impossible d’exporter le Livre.');
  }
}
