import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The only automatically offered model is an opt-in, SHA256-pinned download.
/// Uncensored is a model author's claim, not a guarantee of content support.
/// Download is never started automatically or embedded in the APK.
class LocalModelManager extends ChangeNotifier {
  LocalModelManager({http.Client? client}) : _client = client ?? http.Client();

  static const modelId = 'qwen3-0.6b-uncensored-q4km';
  static const modelName = 'Qwen3 0.6B Uncensored — Q4_K_M';
  static const modelSource =
      'https://huggingface.co/Null-Guard/Qwen3-0.6B-Uncensored-GGUF';
  static const modelUrl =
      '$modelSource/resolve/main/model-Q4_K_M.gguf';
  static const modelSha256 =
      '9f32e486dd220100dd4fe8762ca798df56f8b030782bcd4ee1f4acf4f0c1838a';
  static const fileName = 'qwen3-0.6b-uncensored-q4km.gguf';
  // Reject HTML, truncated responses and excessive downloads.
  static const minimumBytes = 300 * 1024 * 1024;
  static const maximumBytes = 550 * 1024 * 1024;

  final http.Client _client;
  bool _closed = false;
  bool _cancel = false;
  bool _verified = false;
  bool downloading = false;
  int receivedBytes = 0;
  int? expectedBytes;
  String? error;
  String? _location;

  bool get ready => _verified;
  double? get progress => expectedBytes == null || expectedBytes == 0
      ? null : (receivedBytes / expectedBytes!).clamp(0.0, 1.0);
  String? get verifiedPath => _verified ? _location : null;

  void _notify() { if (!_closed) notifyListeners(); }

  Future<File> _target() async {
    final directory = Directory(p.join(
        (await getApplicationSupportDirectory()).path, 'local_models'));
    await directory.create(recursive: true);
    return File(p.join(directory.path, fileName));
  }

  /// Checks the complete local file before its first use on every app launch.
  /// Never trusts existence alone or reads ~400 MB into application RAM.
  Future<bool> verifyInstalled() async {
    if (downloading) return false;
    if (kIsWeb || !Platform.isAndroid) {
      error = 'Le moteur local est actuellement réservé à Android.';
      _notify();
      return false;
    }
    if (_verified) return true;
    final target = await _target();
    if (!await target.exists()) return false;
    final valid = await _verifyFile(target);
    _verified = valid;
    _location = valid ? target.path : null;
    if (!valid) error = 'Modèle local incomplet ou empreinte invalide.';
    _notify();
    return valid;
  }

  Future<bool> _verifyFile(File file) async {
    final length = await file.length();
    if (length < minimumBytes || length > maximumBytes) return false;
    final reader = await file.open();
    try {
      final header = await reader.read(4);
      if (header.length != 4 || header[0] != 71 || header[1] != 71 ||
          header[2] != 85 || header[3] != 70) return false; // GGUF
    } finally {
      await reader.close();
    }
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == modelSha256;
  }

  /// Streams to a temporary file; partial downloads are not runnable.
  /// Requires an explicit user action in LocalAiPage.
  Future<void> downloadRecommended() async {
    if (downloading) return;
    if (kIsWeb || !Platform.isAndroid) {
      throw const FileSystemException('IA locale disponible sur Android uniquement.');
    }
    downloading = true;
    _cancel = false;
    error = null;
    receivedBytes = 0;
    expectedBytes = null;
    _notify();
    File? temp;
    try {
      final target = await _target();
      temp = File('${target.path}.partial');
      if (await temp.exists()) await temp.delete();
      final request = http.Request('GET', Uri.parse(modelUrl));
      final response = await _client.send(request);
      if (response.statusCode != 200) {
        throw StateError('Téléchargement du modèle refusé (HTTP ${response.statusCode}).');
      }
      expectedBytes = response.contentLength;
      if (expectedBytes != null && expectedBytes! > maximumBytes) {
        throw StateError('Fichier modèle anormalement volumineux.');
      }
      final output = temp.openWrite();
      try {
        await for (final chunk in response.stream) {
          if (_cancel) throw StateError('Téléchargement annulé.');
          receivedBytes += chunk.length;
          if (receivedBytes > maximumBytes) {
            throw StateError('Taille maximale du modèle dépassée.');
          }
          output.add(chunk);
          if (receivedBytes % (1024 * 1024) < chunk.length) _notify();
        }
      } finally {
        await output.flush();
        await output.close();
      }
      if (_cancel) throw StateError('Téléchargement annulé.');
      if (!await _verifyFile(temp)) {
        throw StateError('Empreinte SHA-256 du modèle incorrecte.');
      }
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
      _verified = true;
      _location = target.path;
      error = null;
    } catch (failure) {
      _verified = false;
      _location = null;
      error = failure is StateError ? failure.message
          : 'Échec du téléchargement du modèle local.';
      rethrow;
    } finally {
      if (temp != null && await temp.exists()) await temp.delete();
      downloading = false;
      _notify();
    }
  }

  void cancelDownload() { _cancel = true; }

  Future<void> deleteModel() async {
    if (downloading) throw StateError('Annulez le téléchargement en cours.');
    final target = await _target();
    if (await target.exists()) await target.delete();
    _verified = false;
    _location = null;
    error = null;
    _notify();
  }

  @override
  void dispose() {
    _closed = true;
    _cancel = true;
    _client.close();
    super.dispose();
  }
}
