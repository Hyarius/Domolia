// ignore_for_file: prefer_interpolation_to_compose_strings
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Job metadata; pixel payloads must never be placed in conversation JSON.
enum IllustrationJobState {
  preparing, generating, available, failed, invalidated,
}

class StoredIllustration {
  const StoredIllustration({
    required this.requestId,
    required this.sessionId,
    required this.intentId,
    required this.sourceHash,
    required this.state,
    required this.provider,
    required this.model,
    required this.createdAtUtc,
    this.prompt = '',
    this.negativePrompt = '',
    this.fileNames = const [],
    this.mimeType,
    this.error,
    this.costUsd,
  });
  final String requestId, sessionId, sourceHash, provider, model, prompt,
      negativePrompt;
  final int intentId;
  final IllustrationJobState state;
  final DateTime createdAtUtc;
  final List<String> fileNames;
  String? get fileName => fileNames.isEmpty ? null : fileNames.first;
  final String? mimeType, error;
  final double? costUsd;

  StoredIllustration copyWith({
    IllustrationJobState? state,
    String? prompt, String? negativePrompt,
    List<String>? fileNames, String? mimeType, String? error,
    double? costUsd,
  }) => StoredIllustration(
    requestId: requestId, sessionId: sessionId, intentId: intentId,
    sourceHash: sourceHash, state: state ?? this.state,
    provider: provider, model: model,
    createdAtUtc: createdAtUtc, prompt: prompt ?? this.prompt,
    negativePrompt: negativePrompt ?? this.negativePrompt,
    fileNames: fileNames ?? this.fileNames,
    mimeType: mimeType ?? this.mimeType,
    error: error ?? this.error, costUsd: costUsd ?? this.costUsd,
  );
}

/// Optional protocol so existing fake BookStores do not break.
abstract interface class IllustrationRecordStore {
  Future<List<StoredIllustration>> listIllustrations(String sessionId);
  /// Returns false if the source has been removed, modified or rewound.
  Future<bool> saveIllustrationIfCurrent(StoredIllustration record);
  /// Full dataset for orphan pruning (foreign keys delete metadata on rewind).
  Future<Set<String>> retainedIllustrationFiles();
}

/// Binary, bounded and non-exportable by default. No inline base64/JSON.
class LocalIllustrationFiles {
  LocalIllustrationFiles({Future<Directory> Function()? root})
      : _root = root ?? _defaultRoot;
  final Future<Directory> Function() _root;

  static Future<Directory> _defaultRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory(path.join(support.path, 'illustrations'));
  }

  static bool _validFileName(String name) =>
      RegExp(r'^img-[a-zA-Z0-9-]{6,90}\.(png|jpg|webp)$')
          .hasMatch(name);

  Future<String> save(String requestId, Uint8List bytes,
      String mimeType) async {
    if (bytes.isEmpty || bytes.length > 16 * 1024 * 1024) {
      throw const FileSystemException('Image invalide ou trop volumineuse.');
    }
    final extension = switch (mimeType) {
      'image/png' => 'png',
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      _ => throw const FormatException('MIME image non pris en charge.'),
    };
    final safeId = requestId.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '');
    if (safeId.length < 6 || safeId.length > 90) {
      throw const FormatException('Identifiant de requête invalide.');
    }
    final name = 'img-' + safeId + '.' + extension;
    final directory = await _root();
    await directory.create(recursive: true);
    final output = File(path.join(directory.path, name));
    final temp = File(output.path + '.tmp');
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(output.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
    return name;
  }

  Future<Uint8List?> read(String name) async {
    if (!_validFileName(name)) return null;
    final file = File(path.join((await _root()).path, name));
    if (!await file.exists() || await file.length() > 16 * 1024 * 1024) {
      return null;
    }
    return file.readAsBytes();
  }

  Future<void> delete(String name) async {
    if (!_validFileName(name)) return;
    final file = File(path.join((await _root()).path, name));
    if (await file.exists()) await file.delete();
  }

  /// Called after loading the database. Never delete a file still referenced
  /// by another request. Interrupted writes leave .tmp files to clean.
  Future<void> pruneOrphans(Set<String> retained) async {
    final directory = await _root();
    if (!await directory.exists()) return;
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = path.basename(entry.path);
      if ((_validFileName(name) && !retained.contains(name)) ||
          (name.startsWith('img-') && name.endsWith('.tmp'))) {
        await entry.delete();
      }
    }
  }
}
