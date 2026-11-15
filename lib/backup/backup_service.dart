import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../ai/ai_provider.dart';
import '../books/book_store.dart';
import 'backup_repository.dart';
import 'portable_backup.dart';

/// Coordinates SQLite and the encrypted (Android) / non-secret (Web) profile
/// store. Imported profiles are additive and have no secrets. In case the SQL
/// transaction fails, the preceding metadata write is compensated.
class BackupService {
  BackupService({
    required SqliteBookStore books,
    required this.profileStore,
  }) : repository = BackupRepository(books);

  final BackupRepository repository;
  final AiProfileStore profileStore;

  Future<PortableBackup> capture() async {
    final profiles = await profileStore.read();
    if (profiles == null) {
      throw StateError('Initialisez les configurations IA.');
    }
    return repository.capture([
      for (final profile in profiles.profiles) BackupProfile.fromAi(profile),
    ]);
  }

  Future<({int bookConflicts, int sessionConflicts})> preview(
      PortableBackup backup, BackupRestoreMode mode) =>
      repository.preview(backup, mode);

  static String _newProfileId(BackupProfile profile) {
    final bytes = utf8.encode(jsonEncode(profile.toJson()));
    return 'imported-' + sha256.convert(bytes).toString().substring(0, 24);
  }

  static bool _matches(AiProfile local, BackupProfile imported) =>
      local.apiKey.isEmpty && local.name == imported.name &&
      local.kind == imported.kind && local.baseUrl == imported.baseUrl &&
      local.model == imported.model &&
      local.nsfwCompatibility == imported.nsfwCompatibility;

  Future<void> restore(
    PortableBackup backup,
    BackupRestoreMode mode,
  ) async {
    backup.validate();
    final before = await profileStore.read();
    if (before == null || before.profiles.isEmpty) {
      throw const FormatException('Aucun profil IA local initialisé.');
    }
    final updated = List<AiProfile>.of(before.profiles);
    final mappings = <String, String>{};
    for (final profile in backup.aiProfiles) {
      final base = _newProfileId(profile);
      var target = base;
      var suffix = 0;
      while (true) {
        final matches = updated.where((e) => e.id == target);
        if (matches.isEmpty || _matches(matches.single, profile)) break;
        suffix++;
        target = base + '-' + suffix.toString();
      }
      mappings[profile.id] = target;
      if (!updated.any((e) => e.id == target)) {
        updated.add(profile.toAi(importedId: target));
      }
    }

    final changed = updated.length != before.profiles.length;
    if (changed) {
      // Metadata is written first: failures before SQL commit cannot delete
      // existing books or conversations. After a process crash, at worst
      // harmless unbound profiles with empty credentials remain.
      await profileStore.write(AiProfilesState(
        profiles: updated, selectedId: before.selectedId,
      ));
    }
    try {
      await repository.apply(backup, mode, profileIdMap: mappings);
    } catch (_) {
      if (changed) {
        try {
          await profileStore.write(before);
        } catch (_) {
          throw StateError(
            'Restauration interrompue : les métadonnées IA peuvent '
            'nécessiter une vérification. Livres et Parties sont inchangés.',
          );
        }
      }
      rethrow;
    }
  }
}
