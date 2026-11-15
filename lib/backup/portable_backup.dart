import 'dart:convert';
import 'dart:typed_data';

import '../ai/ai_provider.dart';
import '../books/book_definition.dart';
import '../books/book_session.dart';

enum BackupRestoreMode { merge, replace }

/// Portable metadata only: credentials are explicitly excluded from the type.
class BackupProfile {
  const BackupProfile({
    required this.id,
    required this.name,
    required this.kind,
    required this.baseUrl,
    required this.model,
    required this.nsfwCompatibility,
  });

  final String id;
  final String name;
  final AiProviderKind kind;
  final String baseUrl;
  final String model;
  final AiNsfwCompatibility nsfwCompatibility;

  factory BackupProfile.fromAi(AiProfile profile) => BackupProfile(
    id: profile.id, name: profile.name, kind: profile.kind,
    baseUrl: profile.baseUrl, model: profile.model,
    nsfwCompatibility: profile.nsfwCompatibility,
  );

  AiProfile toAi({required String importedId}) => AiProfile(
    id: importedId, name: name, kind: kind, baseUrl: baseUrl,
    model: model, nsfwCompatibility: nsfwCompatibility, apiKey: '',
  );

  Map<String, Object?> toJson() => {
    'id': id, 'name': name, 'providerType': kind.name,
    'baseUrl': baseUrl, 'model': model,
    'nsfwCompatibility': nsfwCompatibility.name,
  };

  static BackupProfile parse(Object? value) {
    final m = _object(value, {
      'id', 'name', 'providerType', 'baseUrl', 'model',
      'nsfwCompatibility',
    });
    for (final k in m.keys) {
      if (m[k] is! String) {
        throw const FormatException('Profil IA de sauvegarde invalide.');
      }
    }
    final id = m['id'] as String;
    final name = m['name'] as String;
    final base = m['baseUrl'] as String;
    final model = m['model'] as String;
    if (!_identifier.hasMatch(id) || name.trim().isEmpty ||
        name.length > 60 || base.length > 2048 || model.isEmpty ||
        model.length > 250 || base.contains('@')) {
      throw const FormatException('Profil IA de sauvegarde invalide.');
    }
    final kind = AiProviderKind.values
        .where((v) => v.name == m['providerType']).firstOrNull;
    final nsfw = AiNsfwCompatibility.values
        .where((v) => v.name == m['nsfwCompatibility']).firstOrNull;
    if (kind == null || nsfw == null) {
      throw const FormatException('Fournisseur IA non reconnu.');
    }
    return BackupProfile(
      id: id, name: name, kind: kind, baseUrl: base,
      model: model, nsfwCompatibility: nsfw,
    );
  }
}

class BackupSession {
  const BackupSession({
    required this.session,
    required this.updatedAtMicros,
    this.aiProfileId,
  });

  final BookSession session;
  final int updatedAtMicros;
  final String? aiProfileId;

  Map<String, Object?> toJson() => {
    'id': session.id,
    'bookId': session.bookId,
    'title': session.title,
    'updatedAtUtc': DateTime.fromMicrosecondsSinceEpoch(
      updatedAtMicros, isUtc: true,
    ).toIso8601String(),
    'aiProfileId': aiProfileId,
    'timeline': jsonDecode(session.encodeTimeline()),
  };

  static BackupSession parse(Object? value) {
    final m = _object(value, {
      'id', 'bookId', 'title', 'updatedAtUtc', 'aiProfileId', 'timeline',
    });
    if (m['id'] is! String || m['bookId'] is! String ||
        m['title'] is! String || m['updatedAtUtc'] is! String ||
        m['timeline'] is! List ||
        (m['aiProfileId'] != null && m['aiProfileId'] is! String)) {
      throw const FormatException('Partie de sauvegarde invalide.');
    }
    final id = m['id'] as String;
    final bookId = m['bookId'] as String;
    final title = m['title'] as String;
    final profileId = m['aiProfileId'] as String?;
    if (!_identifier.hasMatch(id) || !_identifier.hasMatch(bookId) ||
        (profileId != null && !_identifier.hasMatch(profileId)) ||
        title.trim().isEmpty || title.length > 200) {
      throw const FormatException('Identifiants de Partie invalides.');
    }
    final DateTime date;
    try {
      date = DateTime.parse(m['updatedAtUtc'] as String).toUtc();
    } catch (_) {
      throw const FormatException('Date de Partie invalide.');
    }
    final timeline = BookSession.decodeTimeline(jsonEncode(m['timeline']));
    return BackupSession(
      session: BookSession(
        id: id, bookId: bookId, title: title, timeline: timeline,
      ),
      updatedAtMicros: date.microsecondsSinceEpoch,
      aiProfileId: profileId,
    );
  }
}

class BackupBinding {
  const BackupBinding(this.bookId, this.aiProfileId);
  final String bookId;
  final String? aiProfileId;

  Map<String, Object?> toJson() =>
      {'bookId': bookId, 'aiProfileId': aiProfileId};

  static BackupBinding parse(Object? value) {
    final m = _object(value, {'bookId', 'aiProfileId'});
    final id = m['bookId'];
    final profile = m['aiProfileId'];
    if (id is! String || !_identifier.hasMatch(id) ||
        (profile != null &&
          (profile is! String || !_identifier.hasMatch(profile)))) {
      throw const FormatException('Liaison IA de sauvegarde invalide.');
    }
    return BackupBinding(id, profile as String?);
  }
}

final RegExp _identifier = RegExp(r'^[A-Za-z0-9_-]{1,100}$');

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.keys.any((key) => !keys.contains(key)) ||
      keys.any((key) => !value.containsKey(key))) {
    throw const FormatException('Schéma de sauvegarde invalide.');
  }
  return value;
}

List<T> _items<T>(Object? value, T Function(Object?) decode, int max) {
  if (value is! List || value.length > max) {
    throw const FormatException('Liste de sauvegarde invalide.');
  }
  return List.unmodifiable(value.map(decode));
}

class PortableBackup {
  const PortableBackup({
    required this.createdAtUtc,
    required this.books,
    required this.sessions,
    required this.bookBindings,
    required this.aiProfiles,
  });

  static const format = 'domolia.backup';
  static const version = 1;
  static const maxBytes = 100 * 1024 * 1024;

  final DateTime createdAtUtc;
  final List<BookDefinition> books;
  final List<BackupSession> sessions;
  final List<BackupBinding> bookBindings;
  final List<BackupProfile> aiProfiles;

  Map<String, Object?> toJson() => {
    'format': format,
    'version': version,
    'createdAtUtc': createdAtUtc.toUtc().toIso8601String(),
    'books': [for (final b in books) b.toPortableJson()],
    'sessions': [for (final s in sessions) s.toJson()],
    'bookBindings': [for (final b in bookBindings) b.toJson()],
    'aiProfiles': [for (final p in aiProfiles) p.toJson()],
    'preferences': <String, Object?>{},
  };

  Uint8List encode() {
    validate();
    final data = Uint8List.fromList(utf8.encode(jsonEncode(toJson())));
    if (data.length > maxBytes) {
      throw const FormatException('Sauvegarde supérieure à 100 Mio.');
    }
    return data;
  }

  static PortableBackup decode(Uint8List bytes) {
    if (bytes.length > maxBytes) {
      throw const FormatException('Sauvegarde supérieure à 100 Mio.');
    }
    try {
      final m = _object(jsonDecode(utf8.decode(bytes, allowMalformed: false)), {
        'format', 'version', 'createdAtUtc', 'books', 'sessions',
        'bookBindings', 'aiProfiles', 'preferences',
      });
      if (m['format'] != format || m['version'] != version ||
          m['createdAtUtc'] is! String ||
          m['preferences'] is! Map<String, dynamic> ||
          (m['preferences'] as Map).isNotEmpty) {
        throw const FormatException('Version ou préférences non prises en charge.');
      }
      final DateTime created;
      try {
        created = DateTime.parse(m['createdAtUtc'] as String).toUtc();
      } catch (_) {
        throw const FormatException('Date de sauvegarde invalide.');
      }
      final result = PortableBackup(
        createdAtUtc: created,
        books: _items(m['books'], (o) => BookDefinition.importJson(jsonEncode(o)), 5000),
        sessions: _items(m['sessions'], BackupSession.parse, 50000),
        bookBindings: _items(m['bookBindings'], BackupBinding.parse, 5000),
        aiProfiles: _items(m['aiProfiles'], BackupProfile.parse, 1500),
      );
      result.validate();
      return result;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Fichier de sauvegarde invalide.');
    }
  }

  void validate() {
    final bookIds = <String>{};
    for (final b in books) {
      b.validate();
      if (!bookIds.add(b.id)) {
        throw const FormatException('Livre présent plusieurs fois.');
      }
    }
    final profileIds = <String>{};
    for (final p in aiProfiles) {
      BackupProfile.parse(p.toJson());
      if (!profileIds.add(p.id)) {
        throw const FormatException('Profil IA présent plusieurs fois.');
      }
    }
    final sessionIds = <String>{};
    for (final record in sessions) {
      final s = record.session;
      if (!sessionIds.add(s.id) || !bookIds.contains(s.bookId)) {
        throw const FormatException('Partie orpheline ou en doublon.');
      }
      BackupSession.parse(record.toJson());
      if (record.aiProfileId != null &&
          !profileIds.contains(record.aiProfileId)) {
        throw const FormatException('Référence IA de Partie absente.');
      }
    }
    final bound = <String>{};
    for (final b in bookBindings) {
      if (!bookIds.contains(b.bookId) || !bound.add(b.bookId) ||
          (b.aiProfileId != null && !profileIds.contains(b.aiProfileId))) {
        throw const FormatException('Liaison IA orpheline ou en doublon.');
      }
    }
  }
}
