import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'openuncensored_api.dart';

/// Fingerprint is an identifier, never the key itself. All complete credentials
/// and checkout claim tokens are inside one encrypted platform-storage record.
String ouKeyId(String key) => sha256.convert(utf8.encode(key.trim())).toString();

class StoredOuKey {
  const StoredOuKey({
    required this.id,
    required this.secret,
    required this.addedAt,
    this.name = '',
    this.lastBalance,
    this.lastChecked,
  });
  final String id;
  final String secret;
  final DateTime addedAt;
  final String name;
  final OuBalance? lastBalance;
  final DateTime? lastChecked;

  String get masked => 'ou-••••${secret.substring(secret.length - 4)}';
  String get displayName => name.isEmpty ? masked : name;

  StoredOuKey copyWith({String? name, OuBalance? balance, DateTime? checked}) =>
      StoredOuKey(
        id: id, secret: secret, addedAt: addedAt,
        name: name ?? this.name,
        lastBalance: balance ?? lastBalance,
        lastChecked: checked ?? lastChecked,
      );

  Map<String, Object?> toJson() => {
    'id': id, 'secret': secret, 'addedAt': addedAt.toUtc().toIso8601String(),
    'name': name,
    if (lastBalance != null) 'remaining': lastBalance!.remainingUsd,
    if (lastBalance != null) 'balance': lastBalance!.balanceUsd,
    if (lastBalance != null) 'pending': lastBalance!.pendingUsd,
    if (lastChecked != null) 'checked': lastChecked!.toUtc().toIso8601String(),
  };

  factory StoredOuKey.fromJson(Map<String, dynamic> data) {
    final secret = data['secret'];
    final id = data['id'];
    if (secret is! String || !validOpenUncensoredKey(secret) ||
        id is! String || id != ouKeyId(secret)) {
      throw const FormatException('Historique des clés invalide.');
    }
    OuBalance? cached;
    if (data['remaining'] is num && data['balance'] is num &&
        data['pending'] is num) {
      cached = OuBalance(
        remainingUsd: (data['remaining'] as num).toDouble(),
        balanceUsd: (data['balance'] as num).toDouble(),
        pendingUsd: (data['pending'] as num).toDouble(),
      );
    }
    return StoredOuKey(
      id: id, secret: secret,
      addedAt: DateTime.parse(data['addedAt'] as String),
      name: data['name'] is String ? data['name'] as String : '',
      lastBalance: cached,
      lastChecked: data['checked'] is String
          ? DateTime.parse(data['checked'] as String) : null,
    );
  }
}

class PendingOuCheckout {
  const PendingOuCheckout({
    required this.sessionId,
    required this.claimToken,
    required this.paymentUrl,
    required this.cents,
    required this.startedAt,
    this.targetKeyId,
  });
  final String sessionId;
  final String claimToken;
  final Uri paymentUrl;
  final int cents;
  final DateTime startedAt;
  /// Null for initial purchase; fixed target fingerprint for a top-up.
  final String? targetKeyId;
  bool get isTopUp => targetKeyId != null;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId, 'claimToken': claimToken,
    'paymentUrl': paymentUrl.toString(), 'cents': cents,
    'startedAt': startedAt.toUtc().toIso8601String(),
    if (targetKeyId != null) 'targetKeyId': targetKeyId,
  };

  factory PendingOuCheckout.fromJson(Map<String, dynamic> data) {
    final session = OuCheckout.parse({
      'session_id': data['sessionId'],
      'claim_token': data['claimToken'],
      'payment_url': data['paymentUrl'],
    });
    final cents = data['cents'];
    if (cents is! int || cents < 500 || cents > 100000) {
      throw const FormatException('Session de paiement corrompue.');
    }
    return PendingOuCheckout(
      sessionId: session.sessionId, claimToken: session.claimToken,
      paymentUrl: session.paymentUrl, cents: cents,
      startedAt: DateTime.parse(data['startedAt'] as String),
      targetKeyId: data['targetKeyId'] as String?,
    );
  }
}

class OuVaultState {
  const OuVaultState({this.keys = const [], this.activeKeyId, this.pending, this.mode = 'balanced', this.models = const {},
    this.toolChecks = const {}});
  final List<StoredOuKey> keys;
  final String? activeKeyId;
  final PendingOuCheckout? pending;
  final String mode;
  final Map<String, String> models;
  /// Cached probe results keyed by key fingerprint + model ID; never a secret.
  /// Values: supported, unsupported, inconclusive.
  final Map<String, String> toolChecks;

  StoredOuKey? find(String? id) {
    for (final key in keys) {
      if (key.id == id) return key;
    }
    return null;
  }

  OuVaultState copyWith({
    List<StoredOuKey>? keys,
    String? activeKeyId,
    bool clearActive = false,
    PendingOuCheckout? pending,
    bool clearPending = false,
    String? mode,
    Map<String, String>? models,
    Map<String, String>? toolChecks,
  }) => OuVaultState(
    keys: keys ?? this.keys,
    activeKeyId: clearActive ? null : activeKeyId ?? this.activeKeyId,
    pending: clearPending ? null : pending ?? this.pending,
    mode: mode ?? this.mode,
    models: models ?? this.models,
    toolChecks: toolChecks ?? this.toolChecks,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'keys': [for (final key in keys) key.toJson()],
    'activeKeyId': activeKeyId,
    'mode': mode,
    'models': models,
    'toolChecks': toolChecks,
    if (pending != null) 'pending': pending!.toJson(),
  };

  factory OuVaultState.fromJson(Object? raw) {
    if (raw is! Map<String, dynamic> || raw['version'] != 1 ||
        raw['keys'] is! List) {
      throw const FormatException('Coffre OpenUncensored illisible.');
    }
    final entries = (raw['keys'] as List).map((item) =>
        StoredOuKey.fromJson(Map<String, dynamic>.from(item as Map))).toList();
    if (entries.map((e) => e.id).toSet().length != entries.length) {
      throw const FormatException('Clés dupliquées dans le coffre.');
    }
    final active = raw['activeKeyId'] as String?;
    if (active != null && !entries.any((item) => item.id == active)) {
      throw const FormatException('Clé active introuvable.');
    }
    final checks = <String, String>{};
    final cached = raw['toolChecks'];
    if (cached is Map) {
      for (final item in cached.entries) {
        if (checks.length >= 100 || item.key is! String ||
            item.value is! String ||
            !RegExp(r'^[a-f0-9]{64}:.{1,200}\$').hasMatch(item.key as String) ||
            !{'supported', 'unsupported', 'inconclusive'}
                .contains(item.value)) continue;
        checks[item.key as String] = item.value as String;
      }
    }
    return OuVaultState(
      keys: entries, activeKeyId: active,
      toolChecks: checks,
      mode: raw['mode'] is String ? raw['mode'] as String : 'balanced',
      models: raw['models'] is Map
          ? Map<String, String>.from(raw['models'] as Map) : const {},
      pending: raw['pending'] == null ? null :
          PendingOuCheckout.fromJson(
            Map<String, dynamic>.from(raw['pending'] as Map)),
    );
  }
}

abstract interface class OuVaultStore {
  Future<OuVaultState> read();
  Future<void> write(OuVaultState state);
}

class SecureOuVaultStore implements OuVaultStore {
  SecureOuVaultStore({FlutterSecureStorage? storage,
    String storageKey = _storageKey})
      : _storage = storage ?? FlutterSecureStorage(),
        _key = storageKey;
  final FlutterSecureStorage _storage;
  final String _key;
  static const _storageKey = 'domolia.openuncensored.vault.v1';

  @override
  Future<OuVaultState> read() async {
    final raw = await _storage.read(key: _key);
    return raw == null ? const OuVaultState() :
        OuVaultState.fromJson(jsonDecode(raw));
  }

  @override
  Future<void> write(OuVaultState state) async {
    final encoded = jsonEncode(state.toJson());
    // A freshly claimed key is returned once. Do not report successful
    // persistence without verifying that a subsequent read succeeds.
    await _storage.write(key: _key, value: encoded);
    final actual = await _storage.read(key: _key);
    if (actual != encoded) {
      throw const FormatException('Vérification du stockage sécurisé échouée.');
    }
  }
}
).hasMatch(item.key as String) ||
            !{'supported', 'unsupported', 'inconclusive'}
                .contains(item.value)) continue;
        checks[item.key as String] = item.value as String;
      }
    }
    return OuVaultState(
      keys: entries, activeKeyId: active,
      toolChecks: checks,
      mode: raw['mode'] is String ? raw['mode'] as String : 'balanced',
      models: raw['models'] is Map ? Map<String, String>.from(raw['models'] as Map) : const {},
      pending: raw['pending'] == null ? null :
          PendingOuCheckout.fromJson(
            Map<String, dynamic>.from(raw['pending'] as Map)),
    );
  }
}

abstract interface class OuVaultStore {
  Future<OuVaultState> read();
  Future<void> write(OuVaultState state);
}

class SecureOuVaultStore implements OuVaultStore {
  SecureOuVaultStore({FlutterSecureStorage? storage,
    String storageKey = _storageKey})
      : _storage = storage ?? FlutterSecureStorage(),
        _key = storageKey;
  final FlutterSecureStorage _storage;
  final String _key;
  static const _storageKey = 'domolia.openuncensored.vault.v1';

  @override
  Future<OuVaultState> read() async {
    final raw = await _storage.read(key: _key);
    return raw == null ? const OuVaultState() :
        OuVaultState.fromJson(jsonDecode(raw));
  }

  @override
  Future<void> write(OuVaultState state) async {
    final encoded = jsonEncode(state.toJson());
    // A freshly claimed key is returned once. Do not report successful
    // persistence without verifying that a subsequent read succeeds.
    await _storage.write(key: _key, value: encoded);
    final actual = await _storage.read(key: _key);
    if (actual != encoded) {
      throw const FormatException('Vérification du stockage sécurisé échouée.');
    }
  }
}
