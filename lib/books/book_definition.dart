import 'dart:convert';
import 'dart:math';

import '../chat/narrator.dart';

/// Only portable, non-sensitive properties belong to a BookDefinition.
/// AI profile bindings and player sessions are stored in separate tables.
class BookDefinition {
  const BookDefinition({
    required this.id,
    required this.title,
    this.coverBase64,
    this.coverMime,
    this.tags = const <String>{},
    this.narrativeStyle = defaultNarratorNarrativePrompt,
    this.detailLevel = 3,
    this.openingMessages = defaultNarratorOpeningMessages,
    this.extensions = const <String, Object?>{},
  });

  static const format = 'domolia.book';
  static const version = 1;
  static const maxJsonBytes = 2 * 1024 * 1024;
  static const maxCoverBytes = 1024 * 1024;
  static const _allowedMime = {'image/png', 'image/jpeg', 'image/webp'};
  static const _allowedTags = {'nsfw'};

  final String id;
  final String title;
  final String? coverBase64;
  final String? coverMime;
  final Set<String> tags;
  final String narrativeStyle;
  final int detailLevel;
  final List<String> openingMessages;
  /// Reserved for future versioned, explicitly safe scenario/character data.
  final Map<String, Object?> extensions;

  bool get nsfw => tags.contains('nsfw');

  Narrator get narrator => Narrator(
        narrativePrompt: [
          narrativeStyle,
          detailInstruction(detailLevel),
          if (nsfw)
            'Le contenu adulte est une préférence du Livre. Respecte '
                'toujours les règles et limites du fournisseur IA.',
        ].join('\n\n'),
        openingMessages: openingMessages,
      );

  static const detailNames = [
    'Minimaliste', 'Concis', 'Équilibré', 'Détaillé', 'Très descriptif',
  ];

  static const detailInstructions = [
    'Niveau de détail 1 : réponds en descriptions très courtes et directes.',
    'Niveau de détail 2 : utilise des descriptions légères et concises.',
    'Niveau de détail 3 : privilégie une narration naturelle et modérée.',
    'Niveau de détail 4 : développe les descriptions et le contexte sensible.',
    'Niveau de détail 5 : enrichis les descriptions, ambiance et sensations.',
  ];

  static String detailInstruction(int level) {
    if (level < 1 || level > 5) {
      throw const FormatException('Niveau de détail invalide.');
    }
    return detailInstructions[level - 1];
  }

  BookDefinition copyWith({
    String? id,
    String? title,
    String? coverBase64,
    String? coverMime,
    bool clearCover = false,
    Set<String>? tags,
    String? narrativeStyle,
    int? detailLevel,
    List<String>? openingMessages,
    Map<String, Object?>? extensions,
  }) => BookDefinition(
        id: id ?? this.id,
        title: title ?? this.title,
        coverBase64: clearCover ? null : coverBase64 ?? this.coverBase64,
        coverMime: clearCover ? null : coverMime ?? this.coverMime,
        tags: tags ?? this.tags,
        narrativeStyle: narrativeStyle ?? this.narrativeStyle,
        detailLevel: detailLevel ?? this.detailLevel,
        openingMessages: openingMessages ?? this.openingMessages,
        extensions: extensions ?? this.extensions,
      );

  static String freshId() {
    final random = Random.secure();
    return 'book-${DateTime.now().microsecondsSinceEpoch}-'
        '${random.nextInt(0x7fffffff).toRadixString(16)}';
  }

  /// A deliberate allowlist prevents exporting credentials or local profile IDs.
  Map<String, Object?> toPortableJson() => {
        'format': format,
        'version': version,
        'id': id,
        'title': title,
        'tags': tags.toList()..sort(),
        'cover': coverBase64 == null ? null : {
          'mime': coverMime,
          'base64': coverBase64,
        },
        'narrative': {
          'style': narrativeStyle,
          'detailLevel': detailLevel,
        },
        'openingMessages': openingMessages,
        'extensions': extensions,
      };

  String exportJson() {
    validate();
    return const JsonEncoder.withIndent('  ').convert(toPortableJson());
  }

  void validate() {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(id) ||
        title.trim().isEmpty || title.length > 120 ||
        narrativeStyle.trim().isEmpty || narrativeStyle.length > 8000 ||
        detailLevel < 1 || detailLevel > 5 ||
        openingMessages.isEmpty || openingMessages.length > 30 ||
        openingMessages.any((s) => s.trim().isEmpty || s.length > 2000) ||
        tags.any((tag) => !_allowedTags.contains(tag))) {
      throw const FormatException('Définition de Livre invalide.');
    }
    if (coverBase64 == null && coverMime != null ||
        coverBase64 != null && !_allowedMime.contains(coverMime)) {
      throw const FormatException('Format de couverture invalide.');
    }
    if (coverBase64 != null) {
      try {
        final bytes = base64Decode(coverBase64!);
        if (bytes.isEmpty || bytes.length > maxCoverBytes) {
          throw const FormatException('Couverture trop volumineuse.');
        }
        final png = bytes.length >= 8 &&
            bytes.take(8).toList().join(',') == '137,80,78,71,13,10,26,10';
        final jpg = bytes.length >= 3 &&
            bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff;
        final webp = bytes.length >= 12 &&
            ascii.decode(bytes.sublist(0, 4)) == 'RIFF' &&
            ascii.decode(bytes.sublist(8, 12)) == 'WEBP';
        if (!(coverMime == 'image/png' && png ||
            coverMime == 'image/jpeg' && jpg ||
            coverMime == 'image/webp' && webp)) {
          throw const FormatException('Signature de couverture incorrecte.');
        }
      } on FormatException {
        rethrow;
      } catch (_) {
        throw const FormatException('Couverture illisible.');
      }
    }
    // Future extensions must declare a new schema before accepting data.
    if (extensions.isNotEmpty) {
      throw const FormatException('Extensions non prises en charge en v1.');
    }
  }

  static BookDefinition importJson(String source) {
    if (utf8.encode(source).length > maxJsonBytes) {
      throw const FormatException('Fichier de Livre trop volumineux.');
    }
    dynamic parsed;
    try {
      parsed = jsonDecode(source);
    } catch (_) {
      throw const FormatException('Fichier JSON invalide.');
    }
    if (parsed is! Map<String, dynamic>) {
      throw const FormatException('Le Livre doit être un objet JSON.');
    }
    const allowed = {
      'format', 'version', 'id', 'title', 'tags', 'cover',
      'narrative', 'openingMessages', 'extensions',
    };
    if (parsed.keys.any((key) => !allowed.contains(key)) ||
        parsed['format'] != format || parsed['version'] != version ||
        parsed['id'] is! String || parsed['title'] is! String ||
        parsed['tags'] is! List || parsed['narrative'] is! Map<String, dynamic> ||
        parsed['openingMessages'] is! List ||
        parsed['extensions'] is! Map<String, dynamic>) {
      throw const FormatException('Schéma de Livre non pris en charge.');
    }
    final tags = parsed['tags'] as List;
    final openings = parsed['openingMessages'] as List;
    final narrative = parsed['narrative'] as Map<String, dynamic>;
    if (tags.any((e) => e is! String) ||
        openings.any((e) => e is! String) ||
        narrative.length != 2 || narrative['style'] is! String ||
        narrative['detailLevel'] is! int) {
      throw const FormatException('Champs narratifs invalides.');
    }
    final cover = parsed['cover'];
    if (cover != null && (cover is! Map<String, dynamic> ||
        cover.length != 2 || cover['mime'] is! String ||
        cover['base64'] is! String)) {
      throw const FormatException('Couverture du Livre invalide.');
    }
    final book = BookDefinition(
      id: parsed['id'] as String,
      title: parsed['title'] as String,
      coverBase64: cover == null ? null : cover['base64'] as String,
      coverMime: cover == null ? null : cover['mime'] as String,
      tags: tags.cast<String>().toSet(),
      narrativeStyle: narrative['style'] as String,
      detailLevel: narrative['detailLevel'] as int,
      openingMessages: List<String>.unmodifiable(openings.cast<String>()),
      extensions: Map<String, Object?>.unmodifiable(
        parsed['extensions'] as Map<String, dynamic>,
      ),
    );
    book.validate();
    return book;
  }
}
