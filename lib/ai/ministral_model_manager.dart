import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The official Mistral AI GGUF text weights, without the vision projector.
/// Only one downloaded variant is retained to save device storage.
class MinistralVariant {
  const MinistralVariant({
    required this.id,
    required this.name,
    required this.filename,
    required this.bytes,
  });
  final String id;
  final String name;
  final String filename;
  final int bytes;
  String get downloadUrl =>
      'https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF/'
      'resolve/main/$filename';
}

const ministralVariants = <MinistralVariant>[
  MinistralVariant(
    id: 'ministral-3-3b-q4',
    name: 'Ministral 3 3B — Q4_K_M (recommandé, 2,15 Go)',
    filename: 'Ministral-3-3B-Instruct-2512-Q4_K_M.gguf',
    bytes: 2147023008,
  ),
  MinistralVariant(
    id: 'ministral-3-3b-q5',
    name: 'Ministral 3 3B — Q5_K_M (2,47 Go)',
    filename: 'Ministral-3-3B-Instruct-2512-Q5_K_M.gguf',
    bytes: 2474178720,
  ),
];

/// Explicit, private, one-model-at-a-time installation and opt-in routing.
/// This class never calls an AI endpoint or silently downloads a model.
class MinistralModelManager extends ChangeNotifier {
  MinistralModelManager({http.Client? client})
      : _client = client ?? http.Client();

  static const _enabledKey = 'ministral-local-narrator-enabled';
  static const _variantKey = 'ministral-local-model-variant';
  static const _digestKey = 'ministral-local-model-sha256';
  final http.Client _client;
  bool _disposed = false;
  bool _cancel = false;
  bool _initialized = false;
  bool installing = false;
  bool enabled = false;
  int downloadedBytes = 0;
  int? totalBytes;
  String? error;
  String? installedId;
  String? _installedPath;

  MinistralVariant get recommended => ministralVariants.first;
  MinistralVariant? get installedVariant {
    for (final v in ministralVariants) {
      if (v.id == installedId) return v;
    }
    return null;
  }
  String? get installedPath => _installedPath;
  bool get ready => _installedPath != null && installedVariant != null;
  double? get progress => totalBytes == null || totalBytes == 0
      ? null : (downloadedBytes / totalBytes!).clamp(0.0, 1.0).toDouble();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<Directory> _modelDirectory() async {
    final dir = Directory(p.join(
        (await getApplicationSupportDirectory()).path, 'models', 'ministral'));
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file(MinistralVariant variant) async =>
      File(p.join((await _modelDirectory()).path, variant.filename));

  Future<bool> _validHeaderAndSize(File file, MinistralVariant variant) async {
    if (!await file.exists() || await file.length() != variant.bytes) return false;
    final handle = await file.open();
    try {
      final magic = await handle.read(4);
      return magic.length == 4 &&
          magic[0] == 0x47 && magic[1] == 0x47 &&
          magic[2] == 0x55 && magic[3] == 0x46; // GGUF
    } finally {
      await handle.close();
    }
  }

  Future<void> initialize() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_variantKey);
    final variant = ministralVariants.where((v) => v.id == id).firstOrNull;
    if (variant != null) {
      final file = await _file(variant);
      if (await _validHeaderAndSize(file, variant)) {
        installedId = variant.id;
        _installedPath = file.path;
      }
    }
    enabled = ready && (prefs.getBool(_enabledKey) ?? false);
    _initialized = true;
    _notify();
  }

  Future<void> setEnabled(bool next) async {
    await initialize();
    if (installing || (next && !ready)) {
      throw StateError('Installez un modèle local avant de l’activer.');
    }
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(_enabledKey, next)) {
      throw StateError('Impossible de sauvegarder le mode local.');
    }
    enabled = next;
    _notify();
  }

  /// User confirms replacement in the UI before this function is called.
  /// Old weights are deleted *before* downloading, to minimize peak storage.
  /// A failure leaves local mode disabled; there is no paid fallback.
  Future<void> install(MinistralVariant variant) async {
    await initialize();
    if (installing) throw StateError('Installation déjà en cours.');
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw StateError('Installation locale disponible sur Android uniquement.');
    }
    installing = true;
    _cancel = false;
    error = null;
    downloadedBytes = 0;
    totalBytes = variant.bytes;
    _notify();
    File? partial;
    try {
      await setEnabledForInstall();
      for (final v in ministralVariants) {
        final current = await _file(v);
        if (await current.exists()) await current.delete();
        final part = File('${current.path}.part');
        if (await part.exists()) await part.delete();
      }
      installedId = null;
      _installedPath = null;
      final target = await _file(variant);
      partial = File('${target.path}.part');
      final request = http.Request('GET', Uri.parse(variant.downloadUrl));
      final response = await _client.send(request);
      if (response.statusCode != 200) {
        throw StateError('Téléchargement impossible (HTTP ${response.statusCode}).');
      }
      if (response.contentLength != null &&
          response.contentLength != variant.bytes) {
        throw StateError('Taille du modèle distante inattendue.');
      }
      final sink = partial.openWrite();
      try {
        await for (final chunk in response.stream) {
          if (_cancel || _disposed) {
            throw StateError('Téléchargement annulé.');
          }
          downloadedBytes += chunk.length;
          if (downloadedBytes > variant.bytes) {
            throw StateError('Le téléchargement dépasse la taille prévue.');
          }
          sink.add(chunk);
          if (downloadedBytes % (4 * 1024 * 1024) < chunk.length) _notify();
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      if (_cancel || !await _validHeaderAndSize(partial, variant)) {
        throw StateError('Modèle incomplet ou invalide.');
      }
      // Record a digest for later local corruption checking. The download uses
      // HTTPS on Mistral's official repository; the digest is TOFU, NOT a
      // cryptographically pinned upstream checksum.
      final digest = (await sha256.bind(partial.openRead()).first).toString();
      await partial.rename(target.path);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_digestKey, digest);
      await prefs.setString(_variantKey, variant.id);
      installedId = variant.id;
      _installedPath = target.path;
    } catch (e) {
      error = e is StateError ? e.message : 'Téléchargement interrompu.';
      rethrow;
    } finally {
      if (partial != null && await partial.exists()) await partial.delete();
      installing = false;
      _notify();
    }
  }

  Future<void> setEnabledForInstall() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, false);
    enabled = false;
  }

  void cancelInstallation() {
    _cancel = true;
  }

  Future<void> remove() async {
    await initialize();
    if (installing) throw StateError('Annulez d’abord le téléchargement.');
    await setEnabled(false);
    for (final variant in ministralVariants) {
      final file = await _file(variant);
      if (await file.exists()) await file.delete();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_digestKey);
    await prefs.remove(_variantKey);
    installedId = null;
    _installedPath = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel = true;
    _client.close();
    super.dispose();
  }
}
