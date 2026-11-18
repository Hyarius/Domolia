import 'dart:convert';
import 'dart:math';

import '../chat/narrator.dart';
import '../chat/chat_protocol.dart';
import 'book_lore.dart';

/// Portable artistic choices belonging to a Book, never to an API profile.
class BookIllustrationSettings {
  const BookIllustrationSettings({
    this.size = '1024x1024',
    this.quality,
    this.count = 1,
    this.style = 'illustration cinématographique',
    this.negativePrompt = defaultNegativePrompt,
    this.coverPrompt = defaultCoverPrompt,
    this.maximumCostUsd,
  });

  static const defaultNegativePrompt =
      'texte imprimé dans l’image, sous-titres, bulles de dialogue, '
      'légendes, filigranes, signatures, interface utilisateur, '
      'lettres et mots flottants';
  static const defaultCoverPrompt =
      'Une scène emblématique de l’univers du Livre, avec un cadrage '
      'cinématographique vertical et une atmosphère immersive, '
      'sans titre ni texte incrusté.';
  static const supportedSizes = [
    '1024x1024', '1024x1536', '1536x1024',
    '512x512', '1024x1792', '1792x1024', 'auto',
  ];
  static const supportedQualities = [
    'low', 'medium', 'high', 'xhigh', 'max',
  ];

  final String size, style, negativePrompt, coverPrompt;
  final String? quality;
  final int count;
  /// A hard spending limit cannot be enforced without a reliable quote.
  final double? maximumCostUsd;

  BookIllustrationSettings copyWith({
    String? size, String? quality, bool clearQuality = false,
    int? count, String? style, String? negativePrompt,
    String? coverPrompt, double? maximumCostUsd, bool clearMaximumCost = false,
  }) => BookIllustrationSettings(
    size: size ?? this.size,
    quality: clearQuality ? null : quality ?? this.quality,
    count: count ?? this.count,
    style: style ?? this.style,
    negativePrompt: negativePrompt ?? this.negativePrompt,
    coverPrompt: coverPrompt ?? this.coverPrompt,
    maximumCostUsd: clearMaximumCost ? null
        : maximumCostUsd ?? this.maximumCostUsd,
  );

  Map<String, Object?> toJson() => {
    'size': size,
    'quality': quality,
    'count': count,
    'style': style,
    'negativePrompt': negativePrompt,
    'coverPrompt': coverPrompt,
    'maximumCostUsd': maximumCostUsd,
  };

  factory BookIllustrationSettings.fromJson(Object? value) {
    if (value == null) return const BookIllustrationSettings();
    if (value is! Map<String, dynamic> ||
        value.keys.any((key) => !const {
          'size', 'quality', 'count', 'style',
          'negativePrompt', 'coverPrompt', 'maximumCostUsd',
        }.contains(key)) ||
        (value['size'] != null && value['size'] is! String) ||
        (value['quality'] != null && value['quality'] is! String) ||
        (value['count'] != null && value['count'] is! int) ||
        (value['style'] != null && value['style'] is! String) ||
        (value['negativePrompt'] != null &&
            value['negativePrompt'] is! String) ||
        (value['coverPrompt'] != null &&
            value['coverPrompt'] is! String) ||
        (value['maximumCostUsd'] != null &&
            value['maximumCostUsd'] is! num)) {
      throw const FormatException('Configuration d’illustrations invalide.');
    }
    final result = BookIllustrationSettings(
      size: value['size'] as String? ?? '1024x1024',
      quality: value['quality'] as String?,
      count: value['count'] as int? ?? 1,
      style: value['style'] as String? ??
          'illustration cinématographique',
      negativePrompt: value['negativePrompt'] as String? ??
          defaultNegativePrompt,
      coverPrompt: value['coverPrompt'] as String? ??
          defaultCoverPrompt,
      maximumCostUsd: (value['maximumCostUsd'] as num?)?.toDouble(),
    );
    result.validate();
    return result;
  }

  void validate() {
    if (!supportedSizes.contains(size) ||
        (quality != null && !supportedQualities.contains(quality)) ||
        count < 1 || count > 4 ||
        style.trim().isEmpty || style.length > 160 ||
        negativePrompt.length > 1500 ||
        coverPrompt.trim().isEmpty || coverPrompt.length > 2000 ||
        (maximumCostUsd != null &&
            (maximumCostUsd! <= 0 || maximumCostUsd! > 100))) {
      throw const FormatException('Paramètres artistiques du Livre invalides.');
    }
  }
}

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
    this.tuning = const NarrativeTuning(),
    this.illustrationMode = IllustrationMode.suggestions,
    this.illustrationSettings = const BookIllustrationSettings(),
    this.openingMessages = defaultNarratorOpeningMessages,
    this.extensions = const <String, Object?>{},
    this.lore = const BookLore(),
  });

  static const format = 'domolia.book';
  static const version = 3;
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
  final NarrativeTuning tuning;
  final IllustrationMode illustrationMode;
  final BookIllustrationSettings illustrationSettings;
  final List<String> openingMessages;
  /// Reserved for future versioned, explicitly safe scenario/character data.
  final Map<String, Object?> extensions;
  final BookLore lore;

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
        tuning: tuning,
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
    NarrativeTuning? tuning,
    IllustrationMode? illustrationMode,
    BookIllustrationSettings? illustrationSettings,
    List<String>? openingMessages,
    Map<String, Object?>? extensions,
    BookLore? lore,
  }) => BookDefinition(
        id: id ?? this.id,
        title: title ?? this.title,
        coverBase64: clearCover ? null : coverBase64 ?? this.coverBase64,
        coverMime: clearCover ? null : coverMime ?? this.coverMime,
        tags: tags ?? this.tags,
        narrativeStyle: narrativeStyle ?? this.narrativeStyle,
        detailLevel: detailLevel ?? this.detailLevel,
        tuning: tuning ?? this.tuning,
        illustrationMode: illustrationMode ?? this.illustrationMode,
        illustrationSettings: illustrationSettings ?? this.illustrationSettings,
        openingMessages: openingMessages ?? this.openingMessages,
        extensions: extensions ?? this.extensions,
        lore: lore ?? this.lore,
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
          ...tuning.toJson(),
          'illustrationMode': illustrationMode.name,
        },
        'openingMessages': openingMessages,
        'illustration': illustrationSettings.toJson(),
        'extensions': extensions,
        'lore': lore.toJson(),
      };

  String exportJson() {
    validate();
    final result = const JsonEncoder.withIndent('  ').convert(toPortableJson());
    if (utf8.encode(result).length > maxJsonBytes) {
      throw const FormatException('Fichier de Livre trop volumineux.');
    }
    return result;
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
            bytes[0] == 0x52 && bytes[1] == 0x49 &&
            bytes[2] == 0x46 && bytes[3] == 0x46 &&
            bytes[8] == 0x57 && bytes[9] == 0x45 &&
            bytes[10] == 0x42 && bytes[11] == 0x50;
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
    tuning.validate();
    illustrationSettings.validate();
    lore.validate();
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
      'narrative', 'openingMessages', 'illustration',
      'extensions', 'lore',
    };
    if (parsed.keys.any((key) => !allowed.contains(key)) ||
        parsed['format'] != format ||
        !{1, 2, version}.contains(parsed['version']) ||
        (parsed['version'] == 1 && parsed.containsKey('lore')) ||
        (parsed['version'] != 1 && !parsed.containsKey('lore')) ||
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
        narrative.keys.any((key) => !const {
          'style', 'detailLevel', 'responseLength',
          'scenePacing', 'styleKeywords', 'illustrationMode',
        }.contains(key)) ||
        narrative['style'] is! String ||
        narrative['detailLevel'] is! int) {
      throw const FormatException('Champs narratifs invalides.');
    }
    final modeValue = narrative['illustrationMode'];
    if (modeValue != null && (modeValue is! String ||
        !IllustrationMode.values.any((mode) => mode.name == modeValue))) {
      throw const FormatException('Mode d’illustration invalide.');
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
      tuning: NarrativeTuning.fromJson(narrative),
      illustrationMode: modeValue == null
          ? parsed['version'] == version
              ? IllustrationMode.suggestions : IllustrationMode.disabled
          : IllustrationMode.values.byName(modeValue as String),
      illustrationSettings:
          BookIllustrationSettings.fromJson(parsed['illustration']),
      openingMessages: List<String>.unmodifiable(openings.cast<String>()),
      extensions: Map<String, Object?>.unmodifiable(
        parsed['extensions'] as Map<String, dynamic>,
      ),
      lore: parsed['version'] == 1
          ? const BookLore() : BookLore.fromJson(parsed['lore']),
    );
    book.validate();
    return book;
  }
}
