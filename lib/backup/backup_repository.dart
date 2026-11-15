import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../books/book_definition.dart';
import '../books/book_session.dart';
import '../books/book_store.dart';
import 'portable_backup.dart';

/// All book/session/binding writes run in one SQLite transaction. AI credentials
/// are stored elsewhere and never passed to this repository.
class BackupRepository {
  BackupRepository(this.store);

  final SqliteBookStore store;

  Future<PortableBackup> capture(List<BackupProfile> profiles) async {
    final db = await store.database;
    final result = await db.transaction((txn) async {
      final cols = await _sessionColumns(txn);
      final books = await txn.query('books', orderBy: 'rowid DESC');
      final bindings = await txn.query('book_bindings', orderBy: 'book_id');
      final sessions = await txn.query('sessions', orderBy: 'updated_at DESC, id');
      // A profile can be deleted without clearing book/session references.
      // Preserve those references with credential-free placeholders so a
      // single dangling binding cannot prevent a complete user backup.
      final fullProfiles = List<BackupProfile>.of(profiles);
      final known = {for (final p in profiles) p.id};
      void preserveReference(String? id) {
        if (id != null && known.add(id)) {
          fullProfiles.add(BackupProfile.unresolved(id));
        }
      }
      for (final row in bindings) {
        preserveReference(row['profile_id'] as String?);
      }
      if (cols.contains('profile_id')) {
        for (final row in sessions) {
          preserveReference(row['profile_id'] as String?);
        }
      }
      return PortableBackup(
        createdAtUtc: DateTime.now().toUtc(),
        books: [
          for (final row in books)
            BookDefinition.importJson(row['definition_json'] as String),
        ],
        sessions: [
          for (final row in sessions)
            BackupSession(
              session: _session(row),
              updatedAtMicros: row['updated_at'] as int,
              aiProfileId: cols.contains('profile_id')
                  ? row['profile_id'] as String? : null,
            ),
        ],
        bookBindings: [
          for (final row in bindings)
            BackupBinding(
              row['book_id'] as String, row['profile_id'] as String?,
            ),
        ],
        aiProfiles: fullProfiles,
      );
    });
    result.validate();
    return result;
  }

  static BookSession _session(Map<String, Object?> row) => BookSession(
    id: row['id'] as String, bookId: row['book_id'] as String,
    title: row['title'] as String,
    timeline: BookSession.decodeTimeline(row['timeline_json'] as String),
  );

  static Future<Set<String>> _sessionColumns(DatabaseExecutor db) async {
    final rows = await db.rawQuery('PRAGMA table_info(sessions)');
    return {for (final r in rows) r['name'] as String};
  }

  static String _fingerprint(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  static String _stableId(
    String prefix, String originalId, Object content,
    Map<String, String> existing,
    String Function(String id) contentsFor,
  ) {
    final digest = _fingerprint([originalId, content]);
    final base = '$prefix-${digest.substring(0, 24)}';
    for (var attempt = 0; attempt < 1000; attempt++) {
      final candidate = attempt == 0 ? base : '$base-$attempt';
      if (!existing.containsKey(candidate) ||
          contentsFor(candidate) == existing[candidate]) {
        return candidate;
      }
    }
    throw const FormatException('Trop de collisions de sauvegarde.');
  }

  static String _canonicalTimeline(String raw) => BookSession(
    id: '', bookId: '', title: '',
    timeline: BookSession.decodeTimeline(raw),
  ).encodeTimeline();

  /// Mirrors the transaction's ID remapping without writing. An already
  /// imported, unchanged collision must not appear as a new conflict.
  Future<({int bookConflicts, int sessionConflicts})> preview(
    PortableBackup backup,
    BackupRestoreMode mode, {
    Map<String, String> profileIdMap = const {},
  }) async {
    backup.validate();
    if (mode == BackupRestoreMode.replace) {
      return (bookConflicts: 0, sessionConflicts: 0);
    }
    final db = await store.database;
    return db.transaction((txn) async {
      final cols = await _sessionColumns(txn);
      final books = await txn.query('books');
      final sessions = await txn.query('sessions');
      final bookContent = <String, String>{
        for (final row in books)
          row['id'] as String: row['definition_json'] as String,
      };
      final bookIds = <String, String>{};
      var bookConflicts = 0;
      // listBooks() is newest-first by SQLite rowid. Insert in reverse
      // archive order so a new device displays the same library ordering.
      for (final book in backup.books.reversed) {
        final json = book.exportJson();
        var target = book.id;
        if (bookContent.containsKey(target) &&
            !_sameJson(bookContent[target]!, json)) {
          target = _stableId(
            'bookimport', book.id, book.toPortableJson(),
            bookContent, (id) => book.copyWith(id: id).exportJson(),
          );
          if (!bookContent.containsKey(target)) {
            bookConflicts++;
          }
        }
        bookIds[book.id] = target;
        bookContent.putIfAbsent(target, () =>
          book.copyWith(id: target).exportJson());
      }
      final sessionContent = <String, String>{
        for (final row in sessions)
          row['id'] as String: jsonEncode([
            row['book_id'], row['title'],
            _canonicalTimeline(row['timeline_json'] as String),
            row['updated_at'],
            if (cols.contains('profile_id')) row['profile_id'],
          ]),
      };
      var sessionConflicts = 0;
      for (final record in backup.sessions) {
        final source = record.session;
        final bookId = bookIds[source.bookId]!;
        final mappedProfile = record.aiProfileId == null
            ? null : (profileIdMap[record.aiProfileId] ??
                record.aiProfileId);
        String signature(String _) => jsonEncode([
          bookId, source.title, source.encodeTimeline(),
          record.updatedAtMicros,
          if (cols.contains('profile_id')) mappedProfile,
        ]);
        var target = source.id;
        if (sessionContent.containsKey(target) &&
            sessionContent[target] != signature(target)) {
          target = _stableId(
            'partimport', source.id, signature(source.id),
            sessionContent, signature,
          );
          if (!sessionContent.containsKey(target)) {
            sessionConflicts++;
          }
        }
        sessionContent.putIfAbsent(target, () => signature(target));
      }
      return (
        bookConflicts: bookConflicts,
        sessionConflicts: sessionConflicts,
      );
    });
  }

  static bool _sameJson(String a, String b) {
    try {
      // The exported JSON is canonical for BookDefinition: sorted tags,
      // fixed key order and normalized nested values. Whitespace and source
      // key insertion order must never trigger duplicate books on merge.
      return BookDefinition.importJson(a).exportJson() ==
          BookDefinition.importJson(b).exportJson();
    } catch (_) {
      return false;
    }
  }

  Future<void> apply(
    PortableBackup backup,
    BackupRestoreMode mode, {
    required Map<String, String> profileIdMap,
  }) async {
    backup.validate();
    for (final profile in backup.aiProfiles) {
      if (!profileIdMap.containsKey(profile.id)) {
        throw const FormatException('Profil IA de sauvegarde non résolu.');
      }
    }
    final db = await store.database;
    await db.transaction((txn) async {
      final cols = await _sessionColumns(txn);
      if (backup.sessions.any((s) => s.aiProfileId != null) &&
          !cols.contains('profile_id')) {
        // Importing a PR07-era archive onto the old v2 database is unsafe:
        // never silently drop a per-session AI binding.
        throw const FormatException(
          'Les profils IA par Partie nécessitent la migration SQLite v3.',
        );
      }

      if (mode == BackupRestoreMode.replace) {
        // Intentional replacement of user books/sessions and their diagnostics.
        await txn.delete('books');
      }
      final bookRows = await txn.query('books');
      final bookContent = <String, String>{
        for (final row in bookRows)
          row['id'] as String: row['definition_json'] as String,
      };
      final bookIds = <String, String>{};
      for (final book in backup.books) {
        final json = book.exportJson();
        String target = book.id;
        if (bookContent.containsKey(target) &&
            !_sameJson(bookContent[target]!, json)) {
          target = _stableId(
            'bookimport', book.id, book.toPortableJson(), bookContent,
            (id) => book.copyWith(id: id).exportJson(),
          );
        }
        bookIds[book.id] = target;
        if (!bookContent.containsKey(target)) {
          final portable = book.copyWith(id: target).exportJson();
          await txn.insert('books', {
            'id': target, 'definition_json': portable,
          });
          bookContent[target] = portable;
        }
      }

      final existingBindings = {
        for (final row in await txn.query('book_bindings'))
          row['book_id'] as String: row['profile_id'] as String?,
      };
      for (final binding in backup.bookBindings) {
        final targetBookId = bookIds[binding.bookId]!;
        if (mode == BackupRestoreMode.merge &&
            existingBindings[targetBookId] != null) {
          continue;
        }
        await txn.insert('book_bindings', {
          'book_id': targetBookId,
          'profile_id': binding.aiProfileId == null
              ? null : profileIdMap[binding.aiProfileId],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      final sessionRows = await txn.query('sessions');
      final sessionContent = <String, String>{
        for (final row in sessionRows)
          row['id'] as String: jsonEncode([
            row['book_id'], row['title'],
            _canonicalTimeline(row['timeline_json'] as String),
            row['updated_at'],
            if (cols.contains('profile_id')) row['profile_id'],
          ]),
      };
      for (final record in backup.sessions) {
        final source = record.session;
        final targetBookId = bookIds[source.bookId]!;
        final targetProfile = record.aiProfileId == null
            ? null : profileIdMap[record.aiProfileId];
        String signature(String id) => jsonEncode([
          targetBookId, source.title, source.encodeTimeline(),
          record.updatedAtMicros,
          if (cols.contains('profile_id')) targetProfile,
        ]);
        var target = source.id;
        if (sessionContent.containsKey(target) &&
            sessionContent[target] != signature(target)) {
          target = _stableId(
            'partimport', source.id, signature(source.id), sessionContent,
            signature,
          );
        }
        if (!sessionContent.containsKey(target)) {
          await txn.insert('sessions', {
            'id': target,
            'book_id': targetBookId,
            'title': source.title,
            'timeline_json': source.encodeTimeline(),
            'updated_at': record.updatedAtMicros,
            if (cols.contains('profile_id')) 'profile_id': targetProfile,
          });
          sessionContent[target] = signature(target);
        }
      }
    });
  }
}
