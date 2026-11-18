import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../ai/ai_provider.dart';
import '../ai/ai_storage.dart';
import '../ai/openuncensored_vault.dart';
import '../logging/app_logger.dart';

/// Factory reset of *local* Domolia data. API keys remain in encrypted storage.
/// No purchase, text generation or image generation is performed by this service.
class AppResetService {
  AppResetService({
    AiProfileStore? profiles,
    OuVaultStore? vault,
    Future<void> Function()? closeDatabase,
    Future<void> Function()? clearLocalData,
    Future<void> Function()? clearPreferences,
    Future<void> Function()? clearOtherSecureEntries,
  }) : _profiles = profiles ?? SecureAiProfileStore(),
       _vault = vault ?? SecureOuVaultStore(),
       _closeDatabase = closeDatabase ?? (() async {}),
       _clearLocalData = clearLocalData ?? _deleteLocalData,
       _clearPreferences = clearPreferences ?? _deletePreferences,
       _clearOtherSecureEntries =
           clearOtherSecureEntries ?? _deleteOtherSecureEntries;

  final AiProfileStore _profiles;
  final OuVaultStore _vault;
  final Future<void> Function() _closeDatabase;
  final Future<void> Function() _clearLocalData;
  final Future<void> Function() _clearPreferences;
  final Future<void> Function() _clearOtherSecureEntries;

  /// The only secure records retained are the sanitized API profile collection
  /// and the OpenUncensored key history. All OAuth sessions are discarded.
  static Future<void> _deleteOtherSecureEntries() async {
    const keep = {
      'domolia.ai.profiles.v2',
      'domolia.openuncensored.vault.v1',
    };
    const storage = FlutterSecureStorage();
    final entries = await storage.readAll();
    for (final key in entries.keys) {
      if (!keep.contains(key)) await storage.delete(key: key);
    }
  }

  static Future<void> _deletePreferences() async {
    if (!await (await SharedPreferences.getInstance()).clear()) {
      throw StateError('Impossible d’effacer les préférences locales.');
    }
  }

  static Future<void> _deleteLocalData() async {
    // This directory contains SQLite (including WAL files), illustrations,
    // logs and previously downloaded APK updates. Do not touch exported files
    // outside Domolia's private directories.
    await AppLogger.current.clear();
    final support = await getApplicationSupportDirectory();
    final database = path.join(support.path, 'domolia_books.sqlite');
    await deleteDatabase(database);
    for (final root in [
      support,
      await getTemporaryDirectory(),
    ]) {
      if (!await root.exists()) continue;
      await for (final item in root.list(followLinks: false)) {
        if (item is File) {
          await item.delete();
        } else if (item is Directory) {
          await item.delete(recursive: true);
        } else if (item is Link) {
          await item.delete();
        }
      }
    }
  }

  /// Preflight reads are completed before any deletion. A pending checkout
  /// blocks reset: its one-time claim token must not be lost.
  Future<void> reset() async {
    final oldVault = await _vault.read();
    if (oldVault.pending != null) {
      throw StateError('Un paiement OpenUncensored est en attente. '
          'Terminez sa vérification avant de réinitialiser.');
    }
    final previous = await _profiles.read();
    final savedCustom = (previous?.profiles ?? const <AiProfile>[])
        .where((profile) => profile.kind == AiProviderKind.customAi &&
            profile.apiKey.trim().isNotEmpty)
        .toList();

    final active = oldVault.find(oldVault.activeKeyId) ??
        (oldVault.keys.isEmpty ? null : oldVault.keys.first);
    final defaultOuKey = active?.secret ??
        savedCustom.where((profile) =>
          profile.baseUrl.replaceFirst(RegExp(r'/+$'), '') ==
              defaultAiBaseUrl).map((profile) => profile.apiKey).firstOrNull ?? '';

    final restoredProfiles = <AiProfile>[
      AiProfile(
        id: 'default', name: 'OpenUncensored',
        baseUrl: defaultAiBaseUrl, model: defaultAiModel,
        apiKey: defaultOuKey,
      ),
    ];
    var collision = 0;
    for (final profile in savedCustom) {
      // Skip only credentials already retained by the vault or the default
      // profile. Never silently drop a different key under a managed ID.
      final alreadyRetained = (profile.apiKey == defaultOuKey &&
          profile.baseUrl.replaceFirst(RegExp(r'/+
    final restoredVault = OuVaultState(
      keys: [
        for (final key in oldVault.keys)
          StoredOuKey(
            id: key.id, secret: key.secret,
            addedAt: key.addedAt, name: key.name,
          ),
      ],
      activeKeyId: active?.id,
    );

    // Persist credentials *before* erasing other stores. Never deleteAll()
    // in secure storage: a failed rewrite could permanently lose API keys.
    await _vault.write(restoredVault);
    await _profiles.write(AiProfilesState(
      profiles: restoredProfiles, selectedId: 'default',
    ));
    await _clearOtherSecureEntries();
    await _closeDatabase();
    await _clearLocalData();
    await _clearPreferences();
  }
}
), '') ==
              defaultAiBaseUrl) ||
          oldVault.keys.any((key) => key.secret == profile.apiKey);
      if (alreadyRetained) continue;
      var id = profile.id;
      while (restoredProfiles.any((saved) => saved.id == id)) {
        id = 'retained-profile-${collision++}';
      }
      restoredProfiles.add(AiProfile(
        id: id, name: profile.name,
        baseUrl: profile.baseUrl, model: profile.model,
        apiKey: profile.apiKey,
      ));
    }
    final restoredVault = OuVaultState(
      keys: [
        for (final key in oldVault.keys)
          StoredOuKey(
            id: key.id, secret: key.secret,
            addedAt: key.addedAt, name: key.name,
          ),
      ],
      activeKeyId: active?.id,
    );

    // Persist credentials *before* erasing other stores. Never deleteAll()
    // in secure storage: a failed rewrite could permanently lose API keys.
    await _vault.write(restoredVault);
    await _profiles.write(AiProfilesState(
      profiles: restoredProfiles, selectedId: 'default',
    ));
    await _clearOtherSecureEntries();
    await _closeDatabase();
    await _clearLocalData();
    await _clearPreferences();
  }
}
