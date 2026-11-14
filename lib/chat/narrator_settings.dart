import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'narrator.dart';

/// Narrative preferences are ordinary local data, not API credentials.
/// The technical protocol is deliberately excluded from serialization.
abstract interface class NarratorSettingsStore {
  Future<Narrator?> read();
  Future<void> write(Narrator narrator);
}

class LocalNarratorSettingsStore implements NarratorSettingsStore {
  static const _key = 'domolia.narrator.settings.v1';

  @override
  Future<Narrator?> read() async {
    final preferences = await SharedPreferences.getInstance();
    final json = preferences.getString(_key);
    if (json == null) return null;
    final value = jsonDecode(json);
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value['style'] is! String ||
        value['openingMessages'] is! List) {
      throw const FormatException('Configuration du narrateur illisible.');
    }
    final openings = value['openingMessages'] as List;
    if (openings.any((item) => item is! String)) {
      throw const FormatException('Messages d’ouverture illisibles.');
    }
    return Narrator(
      narrativePrompt: value['style'] as String,
      openingMessages: List<String>.unmodifiable(openings.cast<String>()),
    );
  }

  @override
  Future<void> write(Narrator narrator) async {
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setString(
      _key,
      jsonEncode({
        'version': 1,
        'style': narrator.narrativePrompt,
        'openingMessages': narrator.openingMessages,
      }),
    );
    if (!saved) {
      throw const FormatException('Enregistrement du narrateur impossible.');
    }
  }
}

/// Independent of the AI profile: future adventures may select their own
/// Narrator, while the current prototype persists a device-level default.
class NarratorSettingsController extends ChangeNotifier {
  NarratorSettingsController({required this.store});

  final NarratorSettingsStore store;
  Narrator _narrator = const Narrator();
  Narrator get narrator => _narrator;

  bool initialized = false;
  bool busy = false;
  String? message;
  bool _disposed = false;
  Future<void>? _initialization;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() {
    if (_disposed || initialized) return Future<void>.value();
    return _initialization ??= _read();
  }

  Future<void> _read() async {
    try {
      final value = await store.read();
      if (_disposed) return;
      if (value != null) {
        _validate(value.narrativePrompt, value.openingMessages);
        _narrator = value;
      }
    } catch (_) {
      message = 'Configuration du narrateur illisible : valeurs par défaut utilisées.';
    } finally {
      initialized = true;
      _notify();
    }
  }

  static void _validate(String style, List<String> openings) {
    if (style.trim().isEmpty || style.length > 8000) {
      throw const FormatException(
        'Le style du narrateur doit contenir entre 1 et 8 000 caractères.',
      );
    }
    if (openings.isEmpty || openings.length > 30 ||
        openings.any((line) => line.trim().isEmpty || line.length > 2000)) {
      throw const FormatException(
        'Saisissez entre 1 et 30 messages d’ouverture '
        '(2 000 caractères maximum par message).',
      );
    }
  }

  Future<bool> save({
    required String style,
    required String openingMessagesText,
  }) async {
    if (_disposed || busy || !initialized) return false;
    busy = true;
    message = null;
    _notify();
    try {
      final openings = openingMessagesText
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList(growable: false);
      final normalizedStyle = style.trim();
      _validate(normalizedStyle, openings);
      final updated = Narrator(
        narrativePrompt: normalizedStyle,
        openingMessages: List<String>.unmodifiable(openings),
      );
      await store.write(updated);
      if (_disposed) return false;
      _narrator = updated;
      message = 'Configuration du narrateur enregistrée.';
      return true;
    } on FormatException catch (error) {
      message = error.message;
      return false;
    } catch (_) {
      message = 'Impossible d’enregistrer la configuration du narrateur.';
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
