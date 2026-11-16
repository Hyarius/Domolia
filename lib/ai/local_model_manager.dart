import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_model_catalog.dart';

/// Installs one private GGUF at a time, preserving the currently installed
/// model if a replacement download fails or is canceled.
class LocalModelManager extends ChangeNotifier {
  LocalModelManager({
    http.Client? client,
    Directory? modelRoot,
    List<LocalModelVariant> catalog = localModelVariants,
  })  : _client = client ?? http.Client(),
        _modelRoot = modelRoot,
        catalog = catalog;

  static const _enabledKey = 'local-model-enabled';
  static const _variantKey = 'local-model-variant';
  static const _digestKey = 'local-model-sha256';
  static const _nativeStageKey = 'ministral-local-inference-stage';

  // Used by previous releases. Preserve these keys for one-way migration.
  static const _legacyEnabledKey = 'ministral-local-narrator-enabled';
  static const _legacyVariantKey = 'ministral-local-model-variant';

  final http.Client _client;
  final Directory? _modelRoot;
  final List<LocalModelVariant> catalog;
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

  LocalModelVariant get recommended => catalog.first;
  LocalModelVariant? get installedVariant {
    for (final v in catalog) {
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

  Future<Directory> _modelDirectory(LocalModelVariant variant) async {
    final root = _modelRoot ?? await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, 'models', variant.storageFolder));
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file(LocalModelVariant variant) async =>
      File(p.join((await _modelDirectory(variant)).path, variant.filename));

  Future<bool> _validHeaderAndSize(File file, LocalModelVariant variant) async {
    if (!await file.exists() || await file.length() != variant.bytes) {
      return false;
    }
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
    final id = prefs.getString(_variantKey) ??
        prefs.getString(_legacyVariantKey);
    LocalModelVariant? variant;
    for (final candidate in catalog) {
      if (candidate.id == id) variant = candidate;
    }
    if (variant != null) {
      final file = await _file(variant);
      if (await _validHeaderAndSize(file, variant)) {
        installedId = variant.id;
        _installedPath = file.path;
      }
    }
    final interruptedStage = prefs.getString(_nativeStageKey);
    if (interruptedStage != null) {
      error = 'Une opération native précédente a été interrompue '
          '($interruptedStage). Mode local désactivé par précaution. '
          'Consultez les journaux de Domolia et réessayez manuellement.';
      await prefs.setBool(_enabledKey, false);
      await prefs.remove(_nativeStageKey);
    }
    enabled = ready && (prefs.getBool(_enabledKey) ??
        prefs.getBool(_legacyEnabledKey) ?? false);
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

  /// Survives native crashes; does not contain prompts or user content.
  Future<void> markNativeStage(String stage) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_nativeStageKey, stage)) {
      throw StateError('Impossible de journaliser le début du traitement natif.');
    }
  }

  Future<void> clearNativeStage() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_nativeStageKey);
  }

  /// Called only after user confirmation, and only when no local generation
  /// is active. The old model stays on disk until replacement is validated.
  Future<void> install(LocalModelVariant variant) async {
    await initialize();
    if (installing) throw StateError('Installation déjà en cours.');
    if (!catalog.contains(variant)) {
      throw ArgumentError.value(variant.id, 'variant', 'Modèle non référencé.');
    }
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
      // Pauses local routing; there is never an automatic paid fallback
      // during the same inference request.
      await setEnabledForInstall();
      final target = await _file(variant);
      partial = File('${target.path}.part');
      if (await partial.exists()) await partial.delete();

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
          if (_cancel || _disposed) throw StateError('Téléchargement annulé.');
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

      final digest = (await sha256.bind(partial.openRead()).first).toString();
      if (variant.sha256 != null &&
          digest.toLowerCase() != variant.sha256!.toLowerCase()) {
        throw StateError('Empreinte SHA-256 différente de la source officielle.');
      }

      final previous = installedVariant;
      final previousPath = _installedPath;
      if (await target.exists()) await target.delete();
      await partial.rename(target.path);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_digestKey, digest);
      await prefs.setString(_variantKey, variant.id);
      // From this point on, the new model is canonical.
      installedId = variant.id;
      _installedPath = target.path;
      if (previous != null && previous.id != variant.id &&
          previousPath != null) {
        try {
          final oldFile = File(previousPath);
          if (await oldFile.exists()) await oldFile.delete();
        } catch (_) {
          // A stale old file is safer than losing the newly installed model.
        }
      }
    } catch (failure) {
      error = failure is StateError
          ? failure.message : 'Téléchargement interrompu.';
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
    _notify();
  }

  void cancelInstallation() {
    _cancel = true;
  }

  Future<void> remove() async {
    await initialize();
    if (installing) throw StateError('Annulez d’abord le téléchargement.');
    await setEnabled(false);
    for (final variant in catalog) {
      final file = await _file(variant);
      if (await file.exists()) await file.delete();
      final part = File('${file.path}.part');
      if (await part.exists()) await part.delete();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_digestKey);
    await prefs.remove(_variantKey);
    await prefs.remove(_legacyVariantKey);
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
