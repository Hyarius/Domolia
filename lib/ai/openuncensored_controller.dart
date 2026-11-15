import 'package:flutter/foundation.dart';

import 'ai_controller.dart';
import 'ai_provider.dart';
import 'ai_task_routing.dart';
import 'openuncensored_api.dart';
import 'openuncensored_vault.dart';

enum OuQuality { economical, balanced, quality, advanced }

/// No LLM calls are made to test a key: /credits is sufficient.
class OuCreditsController extends ChangeNotifier {
  OuCreditsController({
    required this.api,
    required this.vault,
    required this.ai,
    required this.routing,
  });
  final OpenUncensoredApi api;
  final OuVaultStore vault;
  final AiConnectionController ai;
  final AiTaskRouting routing;

  OuVaultState _state = const OuVaultState();
  List<OuModel> _catalogue = const [];
  Future<void>? _initializing;
  bool _disposed = false;
  bool busy = false;
  bool ready = false;
  String? error;
  String? notice;
  String? _emergencyKey;

  List<StoredOuKey> get keys => List.unmodifiable(_state.keys);
  StoredOuKey? get active => _state.find(_state.activeKeyId);
  PendingOuCheckout? get pending => _state.pending;
  List<OuModel> get catalogue => List.unmodifiable(_catalogue);
  OuQuality get quality => OuQuality.values.firstWhere(
    (value) => value.name == _state.mode,
    orElse: () => OuQuality.balanced,
  );
  Map<String, String> get taskModels => Map.unmodifiable(_state.models);
  bool get hasEmergencyKey => _emergencyKey != null;

  String? emergencyKeyForManualRecovery() => _emergencyKey;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initializing ??= _load();

  Future<void> _load() async {
    try {
      await ai.initialize();
      await routing.initialize();
      var state = await vault.read();

      // Import, do not erase or rewrite, pre-existing OpenUncensored keys
      // previously kept in the old encrypted AI-profile collection.
      final added = List<StoredOuKey>.of(state.keys);
      var activeId = state.activeKeyId;
      for (final profile in ai.profiles) {
        if (profile.baseUrl.replaceFirst(RegExp(r'/+
        final id = ouKeyId(profile.apiKey);
        if (!added.any((item) => item.id == id)) {
          added.add(StoredOuKey(
            id: id, secret: profile.apiKey, addedAt: DateTime.now().toUtc(),
            name: profile.name,
          ));
        }
        if (activeId == null && ai.selectedProfileId == profile.id) {
          activeId = id;
        }
      }
      if (added.length != state.keys.length || activeId != state.activeKeyId) {
        final migrated = state.copyWith(keys: added, activeKeyId: activeId);
        await vault.write(migrated);
        state = migrated;
      }
      _state = state;
    } catch (_) {
      error = 'Le coffre sécurisé est indisponible. Aucune clé n’a été supprimée.';
    } finally {
      ready = true;
      _notify();
    }
  }

  Future<void> _write(OuVaultState next) async {
    await vault.write(next);
    _state = next;
    _notify();
  }

  Future<T?> _run<T>(Future<T> Function() action) async {
    await initialize();
    if (busy || _disposed) return null;
    busy = true;
    error = null;
    notice = null;
    _notify();
    try {
      return await action();
    } on OpenUncensoredFailure catch (failure) {
      error = failure.message;
    } catch (_) {
      // Neither platform exceptions nor HTTP bodies are logged or displayed.
      error = 'Opération interrompue. Les clés existantes sont conservées.';
    } finally {
      busy = false;
      _notify();
    }
    return null;
  }

  Future<List<OuModel>> loadModels() async {
    final result = await _run(() async {
      final models = await api.models();
      if (models.isEmpty) {
        throw const OpenUncensoredFailure('Aucun modèle disponible.');
      }
      _catalogue = models;
      return models;
    });
    return result ?? _catalogue;
  }

  /// Ranked recommendations from the dated provider guide only influence
  /// preference; actual availability and cost are checked live.
  static const _recommended = <String>[
    'deepseek-v4.1-flash-1017-uncensored',
    'glm-5.3-flash-uncensored',
    'qwen3.8-27b-uncensored-fast',
    'deepseek-v4.1-flash-0910-uncensored',
  ];

  Map<String, String> _chooseModels(OuQuality mode) {
    final sorted = _catalogue.where((model) => model.available).toList()
      ..sort((a, b) => _price(a).compareTo(_price(b)));
    final cheap = sorted.isEmpty ? defaultAiModel : sorted.first.id;
    final toolCandidates = sorted.where((model) => model.toolCompatible).toList();
    final narratorPool = toolCandidates.isNotEmpty ? toolCandidates : sorted;
    String ranked() {
      for (final name in _recommended) {
        if (narratorPool.any((model) => model.id == name)) return name;
      }
      return narratorPool.isEmpty ? defaultAiModel : narratorPool.first.id;
    }
    final narrator = switch (mode) {
      OuQuality.economical => narratorPool.isEmpty ? defaultAiModel : narratorPool.first.id,
      OuQuality.balanced => ranked(),
      OuQuality.quality => ranked(),
      OuQuality.advanced => _state.models['narrator'] ?? ranked(),
    };
    return {
      'narrator': narrator,
      'jsonifier': cheap,
      'optimizer': cheap,
    };
  }

  double _price(OuModel model) =>
      (model.inputPerTokenUsd ?? 0.000001) +
      (model.outputPerTokenUsd ?? 0.000005);

  Future<bool> _configure(OuVaultState snapshot) async {
    final key = snapshot.find(snapshot.activeKeyId);
    if (key == null) return true;
    final models = snapshot.models.isEmpty ?
        _chooseModels(OuQuality.balanced) : snapshot.models;
    final applied = await ai.configureOpenUncensored(
      key.secret,
      narratorModel: models['narrator'] ?? defaultAiModel,
      jsonifierModel: models['jsonifier'] ?? defaultAiModel,
      optimizerModel: models['optimizer'] ?? defaultAiModel,
    );
    if (!applied) return false;
    await routing.setProfile(
      AiNarrativeTask.narrator, AiConnectionController.ouNarratorProfileId);
    await routing.setProfile(
      AiNarrativeTask.jsonifier, AiConnectionController.ouJsonifierProfileId);
    await routing.setProfile(
      AiNarrativeTask.optimizer,
      snapshot.mode == OuQuality.economical.name ? '#disabled' :
          AiConnectionController.ouOptimizerProfileId);
    return true;
  }

  Future<bool> refresh(String id) async => await _run(() async {
    final key = _state.find(id);
    if (key == null) {
      throw const OpenUncensoredFailure('Clé introuvable dans l’historique.');
    }
    final balance = await api.balance(key.secret);
    await _write(_state.copyWith(keys: [
      for (final item in _state.keys)
        item.id == id ?
          item.copyWith(balance: balance, checked: DateTime.now().toUtc()) : item,
    ]));
    notice = 'Solde mis à jour.';
    return true;
  }) ?? false;

  Future<bool> importKey(String value, {String name = ''}) async =>
      await _run(() async {
    final key = value.trim();
    if (!validOpenUncensoredKey(key)) {
      throw const OpenUncensoredFailure('Format de clé OpenUncensored invalide.');
    }
    final balance = await api.balance(key);
    if (_catalogue.isEmpty) {
      try { _catalogue = await api.models(); } catch (_) { /* Use documented fallback. */ }
    }
    final id = ouKeyId(key);
    final existing = _state.find(id);
    final record = (existing ?? StoredOuKey(
      id: id, secret: key, addedAt: DateTime.now().toUtc(),
      name: name.trim(),
    )).copyWith(balance: balance, checked: DateTime.now().toUtc());
    final snapshot = _state.copyWith(
      keys: [
        for (final item in _state.keys)
          if (item.id != id) item,
        record,
      ],
      activeKeyId: id,
      models: _state.models.isEmpty ? _chooseModels(quality) : _state.models,
    );
    // Persist first. If activating a managed profile fails, the key remains
    // recoverable from the encrypted history.
    await _write(snapshot);
    if (!await _configure(snapshot)) {
      throw const OpenUncensoredFailure('Clé conservée, mais activation IA impossible.');
    }
    notice = 'Clé validée et activée. Les anciens crédits restent sur leurs clés.';
    return true;
  }) ?? false;

  Future<bool> activate(String id) async => await _run(() async {
    final key = _state.find(id);
    if (key == null) throw const OpenUncensoredFailure('Clé inconnue.');
    final balance = await api.balance(key.secret);
    final next = _state.copyWith(
      keys: [
        for (final item in _state.keys)
          item.id == id ?
            item.copyWith(balance: balance, checked: DateTime.now().toUtc()) : item,
      ],
      activeKeyId: id,
      models: _state.models.isEmpty ? _chooseModels(quality) : _state.models,
    );
    await _write(next);
    if (!await _configure(next)) {
      throw const OpenUncensoredFailure('Clé enregistrée, activation IA impossible.');
    }
    notice = 'Clé active remplacée. Aucun crédit n’a été transféré.';
    return true;
  }) ?? false;

  Future<bool> rename(String id, String value) async => await _run(() async {
    final name = value.trim();
    if (name.length > 48 || name.contains(RegExp(r'[\r\n]'))) {
      throw const OpenUncensoredFailure('Nom de clé invalide.');
    }
    if (_state.find(id) == null) return false;
    await _write(_state.copyWith(keys: [
      for (final item in _state.keys)
        item.id == id ? item.copyWith(name: name) : item,
    ]));
    return true;
  }) ?? false;

  /// Returns the provider URL only after saving the claim token, so a process
  /// restart during Stripe Checkout cannot orphan the purchase.
  Future<Uri?> startCheckout(int cents, {String? topUpKeyId}) async =>
      await _run(() async {
    if (_state.pending != null) {
      throw const OpenUncensoredFailure('Terminez ou abandonnez le paiement en cours.');
    }
    final target = topUpKeyId == null ? null : _state.find(topUpKeyId);
    if (topUpKeyId != null && target == null) {
      throw const OpenUncensoredFailure('Clé à recharger introuvable.');
    }
    final session = await api.checkout(
      cents: cents, topUpKey: target?.secret);
    await _write(_state.copyWith(pending: PendingOuCheckout(
      sessionId: session.sessionId, claimToken: session.claimToken,
      paymentUrl: session.paymentUrl, cents: cents,
      targetKeyId: target?.id, startedAt: DateTime.now().toUtc(),
    )));
    notice = 'Session enregistrée. Terminez le paiement chez Stripe.';
    return session.paymentUrl;
  });

  Future<OuCheckoutStatus?> checkPending() async => await _run<OuCheckoutStatus?>(() async {
    final session = _state.pending;
    if (session == null) return null;
    final result = await api.check(session.sessionId, session.claimToken);
    if (result.status == OuCheckoutStatus.pending) {
      notice = 'Paiement encore en attente.';
      return result.status;
    }
    if (result.status == OuCheckoutStatus.expired) {
      await _write(_state.copyWith(clearPending: true));
      notice = 'Le lien de paiement a expiré.';
      return result.status;
    }
    if (session.isTopUp) {
      // Top-ups always follow their original target, even if the active
      // selection changed while the Stripe page was open.
      final target = _state.find(session.targetKeyId);
      if (target == null) {
        throw const OpenUncensoredFailure('Recharge confirmée : clé cible introuvable.');
      }
      await _write(_state.copyWith(clearPending: true));
      try {
        final balance = await api.balance(target.secret);
        await _write(_state.copyWith(keys: [
          for (final item in _state.keys)
            item.id == target.id ?
              item.copyWith(balance: balance, checked: DateTime.now().toUtc()) :
              item,
        ]));
      } catch (_) {
        // Paid confirmation remains authoritative; cached balance is stale.
      }
      notice = 'Recharge confirmée sur la clé choisie au début du paiement.';
      return result.status;
    }
    final newKey = result.apiKey;
    if (newKey == null || !validOpenUncensoredKey(newKey)) {
      throw const OpenUncensoredFailure(
        'Paiement confirmé, mais aucune clé récupérable. Contactez le fournisseur.');
    }
    final id = ouKeyId(newKey);
    final old = _state.find(id);
    final created = old ?? StoredOuKey(
      id: id, secret: newKey, addedAt: DateTime.now().toUtc(),
    );
    final next = _state.copyWith(
      keys: [..._state.keys.where((item) => item.id != id), created],
      activeKeyId: id,
      clearPending: true,
      models: _state.models.isEmpty ? _chooseModels(quality) : _state.models,
    );
    try {
      await _write(next);
      _emergencyKey = null;
    } catch (_) {
      // Retain the one-time secret in RAM for explicit user recovery if the
      // secure write fails. It must never be sent to logs or diagnostics.
      _emergencyKey = newKey;
      throw const OpenUncensoredFailure(
        'Paiement confirmé : sauvegarde impossible. Copiez immédiatement la clé de secours.');
    }
    if (_catalogue.isEmpty) {
      try { _catalogue = await api.models(); } catch (_) { /* Offline fallback. */ }
    }
    if (!await _configure(next)) {
      throw const OpenUncensoredFailure(
        'Clé sauvegardée dans l’historique, mais configuration IA indisponible.');
    }
    try {
      final balance = await api.balance(newKey);
      await _write(_state.copyWith(keys: [
        for (final item in _state.keys)
          item.id == id ? item.copyWith(balance: balance,
            checked: DateTime.now().toUtc()) : item,
      ]));
    } catch (_) { /* Verified key remains durably stored. */ }
    notice = 'Paiement confirmé et clé sauvegardée.';
    return result.status;
  });

  Future<bool> abandonPending() async => await _run(() async {
    if (_state.pending == null) return true;
    await _write(_state.copyWith(clearPending: true));
    notice = 'Suivi local abandonné. Un paiement effectué peut toujours être encaissé.';
    return true;
  }) ?? false;

  Future<bool> setPreset(OuQuality mode) async => await _run(() async {
    if (mode == OuQuality.advanced) return false;
    final catalogue = await api.models();
    _catalogue = catalogue;
    if (catalogue.isEmpty) {
      throw const OpenUncensoredFailure('Catalogue indisponible.');
    }
    final next = _state.copyWith(mode: mode.name, models: _chooseModels(mode));
    await _write(next);
    if (!await _configure(next)) return false;
    notice = 'Préréglage ${mode.name} appliqué.';
    return true;
  }) ?? false;

  Future<bool> setAdvanced(Map<String, String> models) async => await _run(() async {
    if (_catalogue.isEmpty) _catalogue = await api.models();
    for (final task in ['narrator', 'jsonifier', 'optimizer']) {
      final requested = models[task];
      if (requested == null ||
          !_catalogue.any((model) => model.id == requested && model.available)) {
        throw const OpenUncensoredFailure('Modèle de tâche indisponible.');
      }
    }
    final narrator = _catalogue.firstWhere(
      (model) => model.id == models['narrator']);
    if (!narrator.toolCompatible) {
      throw const OpenUncensoredFailure(
        'Compatibilité tool calling du narrateur non confirmée.');
    }
    final next = _state.copyWith(mode: OuQuality.advanced.name, models: models);
    await _write(next);
    if (!await _configure(next)) return false;
    return true;
  }) ?? false;

  /// Only call after an explicit confirmation from the user.
  String? revealKey(String id) => _state.find(id)?.secret;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
), '') != defaultAiBaseUrl ||
            !validOpenUncensoredKey(profile.apiKey)) {
          continue;
        }
        final id = ouKeyId(profile.apiKey);
        if (!added.any((item) => item.id == id)) {
          added.add(StoredOuKey(
            id: id, secret: profile.apiKey, addedAt: DateTime.now().toUtc(),
            name: profile.name,
          ));
        }
        if (activeId == null && ai.selectedProfileId == profile.id) {
          activeId = id;
        }
      }
      if (added.length != state.keys.length || activeId != state.activeKeyId) {
        final migrated = state.copyWith(keys: added, activeKeyId: activeId);
        await vault.write(migrated);
        state = migrated;
      }
      _state = state;
    } catch (_) {
      error = 'Le coffre sécurisé est indisponible. Aucune clé n’a été supprimée.';
    } finally {
      ready = true;
      _notify();
    }
  }

  Future<void> _write(OuVaultState next) async {
    await vault.write(next);
    _state = next;
    _notify();
  }

  Future<T?> _run<T>(Future<T> Function() action) async {
    await initialize();
    if (busy || _disposed) return null;
    busy = true;
    error = null;
    notice = null;
    _notify();
    try {
      return await action();
    } on OpenUncensoredFailure catch (failure) {
      error = failure.message;
    } catch (_) {
      // Neither platform exceptions nor HTTP bodies are logged or displayed.
      error = 'Opération interrompue. Les clés existantes sont conservées.';
    } finally {
      busy = false;
      _notify();
    }
    return null;
  }

  Future<List<OuModel>> loadModels() async {
    final result = await _run(() async {
      final models = await api.models();
      if (models.isEmpty) {
        throw const OpenUncensoredFailure('Aucun modèle disponible.');
      }
      _catalogue = models;
      return models;
    });
    return result ?? _catalogue;
  }

  /// Ranked recommendations from the dated provider guide only influence
  /// preference; actual availability and cost are checked live.
  static const _recommended = <String>[
    'deepseek-v4.1-flash-1017-uncensored',
    'glm-5.3-flash-uncensored',
    'qwen3.8-27b-uncensored-fast',
    'deepseek-v4.1-flash-0910-uncensored',
  ];

  Map<String, String> _chooseModels(OuQuality mode) {
    final sorted = _catalogue.where((model) => model.available).toList()
      ..sort((a, b) => _price(a).compareTo(_price(b)));
    final cheap = sorted.isEmpty ? defaultAiModel : sorted.first.id;
    final toolCandidates = sorted.where((model) => model.toolCompatible).toList();
    final narratorPool = toolCandidates.isNotEmpty ? toolCandidates : sorted;
    String ranked() {
      for (final name in _recommended) {
        if (narratorPool.any((model) => model.id == name)) return name;
      }
      return narratorPool.isEmpty ? defaultAiModel : narratorPool.first.id;
    }
    final narrator = switch (mode) {
      OuQuality.economical => narratorPool.isEmpty ? defaultAiModel : narratorPool.first.id,
      OuQuality.balanced => ranked(),
      OuQuality.quality => ranked(),
      OuQuality.advanced => _state.models['narrator'] ?? ranked(),
    };
    return {
      'narrator': narrator,
      'jsonifier': cheap,
      'optimizer': cheap,
    };
  }

  double _price(OuModel model) =>
      (model.inputPerTokenUsd ?? 0.000001) +
      (model.outputPerTokenUsd ?? 0.000005);

  Future<bool> _configure(OuVaultState snapshot) async {
    final key = snapshot.find(snapshot.activeKeyId);
    if (key == null) return true;
    final models = snapshot.models.isEmpty ?
        _chooseModels(OuQuality.balanced) : snapshot.models;
    final applied = await ai.configureOpenUncensored(
      key.secret,
      narratorModel: models['narrator'] ?? defaultAiModel,
      jsonifierModel: models['jsonifier'] ?? defaultAiModel,
      optimizerModel: models['optimizer'] ?? defaultAiModel,
    );
    if (!applied) return false;
    await routing.setProfile(
      AiNarrativeTask.narrator, AiConnectionController.ouNarratorProfileId);
    await routing.setProfile(
      AiNarrativeTask.jsonifier, AiConnectionController.ouJsonifierProfileId);
    await routing.setProfile(
      AiNarrativeTask.optimizer,
      snapshot.mode == OuQuality.economical.name ? '#disabled' :
          AiConnectionController.ouOptimizerProfileId);
    return true;
  }

  Future<bool> refresh(String id) async => await _run(() async {
    final key = _state.find(id);
    if (key == null) {
      throw const OpenUncensoredFailure('Clé introuvable dans l’historique.');
    }
    final balance = await api.balance(key.secret);
    await _write(_state.copyWith(keys: [
      for (final item in _state.keys)
        item.id == id ?
          item.copyWith(balance: balance, checked: DateTime.now().toUtc()) : item,
    ]));
    notice = 'Solde mis à jour.';
    return true;
  }) ?? false;

  Future<bool> importKey(String value, {String name = ''}) async =>
      await _run(() async {
    final key = value.trim();
    if (!validOpenUncensoredKey(key)) {
      throw const OpenUncensoredFailure('Format de clé OpenUncensored invalide.');
    }
    final balance = await api.balance(key);
    if (_catalogue.isEmpty) {
      try { _catalogue = await api.models(); } catch (_) { /* Use documented fallback. */ }
    }
    final id = ouKeyId(key);
    final existing = _state.find(id);
    final record = (existing ?? StoredOuKey(
      id: id, secret: key, addedAt: DateTime.now().toUtc(),
      name: name.trim(),
    )).copyWith(balance: balance, checked: DateTime.now().toUtc());
    final snapshot = _state.copyWith(
      keys: [
        for (final item in _state.keys)
          if (item.id != id) item,
        record,
      ],
      activeKeyId: id,
      models: _state.models.isEmpty ? _chooseModels(quality) : _state.models,
    );
    // Persist first. If activating a managed profile fails, the key remains
    // recoverable from the encrypted history.
    await _write(snapshot);
    if (!await _configure(snapshot)) {
      throw const OpenUncensoredFailure('Clé conservée, mais activation IA impossible.');
    }
    notice = 'Clé validée et activée. Les anciens crédits restent sur leurs clés.';
    return true;
  }) ?? false;

  Future<bool> activate(String id) async => await _run(() async {
    final key = _state.find(id);
    if (key == null) throw const OpenUncensoredFailure('Clé inconnue.');
    final balance = await api.balance(key.secret);
    final next = _state.copyWith(
      keys: [
        for (final item in _state.keys)
          item.id == id ?
            item.copyWith(balance: balance, checked: DateTime.now().toUtc()) : item,
      ],
      activeKeyId: id,
      models: _state.models.isEmpty ? _chooseModels(quality) : _state.models,
    );
    await _write(next);
    if (!await _configure(next)) {
      throw const OpenUncensoredFailure('Clé enregistrée, activation IA impossible.');
    }
    notice = 'Clé active remplacée. Aucun crédit n’a été transféré.';
    return true;
  }) ?? false;

  Future<bool> rename(String id, String value) async => await _run(() async {
    final name = value.trim();
    if (name.length > 48 || name.contains(RegExp(r'[\r\n]'))) {
      throw const OpenUncensoredFailure('Nom de clé invalide.');
    }
    if (_state.find(id) == null) return false;
    await _write(_state.copyWith(keys: [
      for (final item in _state.keys)
        item.id == id ? item.copyWith(name: name) : item,
    ]));
    return true;
  }) ?? false;

  /// Returns the provider URL only after saving the claim token, so a process
  /// restart during Stripe Checkout cannot orphan the purchase.
  Future<Uri?> startCheckout(int cents, {String? topUpKeyId}) async =>
      await _run(() async {
    if (_state.pending != null) {
      throw const OpenUncensoredFailure('Terminez ou abandonnez le paiement en cours.');
    }
    final target = topUpKeyId == null ? null : _state.find(topUpKeyId);
    if (topUpKeyId != null && target == null) {
      throw const OpenUncensoredFailure('Clé à recharger introuvable.');
    }
    final session = await api.checkout(
      cents: cents, topUpKey: target?.secret);
    await _write(_state.copyWith(pending: PendingOuCheckout(
      sessionId: session.sessionId, claimToken: session.claimToken,
      paymentUrl: session.paymentUrl, cents: cents,
      targetKeyId: target?.id, startedAt: DateTime.now().toUtc(),
    )));
    notice = 'Session enregistrée. Terminez le paiement chez Stripe.';
    return session.paymentUrl;
  });

  Future<OuCheckoutStatus?> checkPending() async => await _run(() async {
    final session = _state.pending;
    if (session == null) return null;
    final result = await api.check(session.sessionId, session.claimToken);
    if (result.status == OuCheckoutStatus.pending) {
      notice = 'Paiement encore en attente.';
      return result.status;
    }
    if (result.status == OuCheckoutStatus.expired) {
      await _write(_state.copyWith(clearPending: true));
      notice = 'Le lien de paiement a expiré.';
      return result.status;
    }
    if (session.isTopUp) {
      // Top-ups always follow their original target, even if the active
      // selection changed while the Stripe page was open.
      final target = _state.find(session.targetKeyId);
      if (target == null) {
        throw const OpenUncensoredFailure('Recharge confirmée : clé cible introuvable.');
      }
      await _write(_state.copyWith(clearPending: true));
      try {
        final balance = await api.balance(target.secret);
        await _write(_state.copyWith(keys: [
          for (final item in _state.keys)
            item.id == target.id ?
              item.copyWith(balance: balance, checked: DateTime.now().toUtc()) :
              item,
        ]));
      } catch (_) {
        // Paid confirmation remains authoritative; cached balance is stale.
      }
      notice = 'Recharge confirmée sur la clé choisie au début du paiement.';
      return result.status;
    }
    final newKey = result.apiKey;
    if (newKey == null || !validOpenUncensoredKey(newKey)) {
      throw const OpenUncensoredFailure(
        'Paiement confirmé, mais aucune clé récupérable. Contactez le fournisseur.');
    }
    final id = ouKeyId(newKey);
    final old = _state.find(id);
    final created = old ?? StoredOuKey(
      id: id, secret: newKey, addedAt: DateTime.now().toUtc(),
    );
    final next = _state.copyWith(
      keys: [..._state.keys.where((item) => item.id != id), created],
      activeKeyId: id,
      clearPending: true,
      models: _state.models.isEmpty ? _chooseModels(quality) : _state.models,
    );
    try {
      await _write(next);
      _emergencyKey = null;
    } catch (_) {
      // Retain the one-time secret in RAM for explicit user recovery if the
      // secure write fails. It must never be sent to logs or diagnostics.
      _emergencyKey = newKey;
      throw const OpenUncensoredFailure(
        'Paiement confirmé : sauvegarde impossible. Copiez immédiatement la clé de secours.');
    }
    if (_catalogue.isEmpty) {
      try { _catalogue = await api.models(); } catch (_) { /* Offline fallback. */ }
    }
    if (!await _configure(next)) {
      throw const OpenUncensoredFailure(
        'Clé sauvegardée dans l’historique, mais configuration IA indisponible.');
    }
    try {
      final balance = await api.balance(newKey);
      await _write(_state.copyWith(keys: [
        for (final item in _state.keys)
          item.id == id ? item.copyWith(balance: balance,
            checked: DateTime.now().toUtc()) : item,
      ]));
    } catch (_) { /* Verified key remains durably stored. */ }
    notice = 'Paiement confirmé et clé sauvegardée.';
    return result.status;
  });

  Future<bool> abandonPending() async => await _run(() async {
    if (_state.pending == null) return true;
    await _write(_state.copyWith(clearPending: true));
    notice = 'Suivi local abandonné. Un paiement effectué peut toujours être encaissé.';
    return true;
  }) ?? false;

  Future<bool> setPreset(OuQuality mode) async => await _run(() async {
    if (mode == OuQuality.advanced) return false;
    final catalogue = await api.models();
    _catalogue = catalogue;
    if (catalogue.isEmpty) {
      throw const OpenUncensoredFailure('Catalogue indisponible.');
    }
    final next = _state.copyWith(mode: mode.name, models: _chooseModels(mode));
    await _write(next);
    if (!await _configure(next)) return false;
    notice = 'Préréglage ${mode.name} appliqué.';
    return true;
  }) ?? false;

  Future<bool> setAdvanced(Map<String, String> models) async => await _run(() async {
    if (_catalogue.isEmpty) _catalogue = await api.models();
    for (final task in ['narrator', 'jsonifier', 'optimizer']) {
      final requested = models[task];
      if (requested == null ||
          !_catalogue.any((model) => model.id == requested && model.available)) {
        throw const OpenUncensoredFailure('Modèle de tâche indisponible.');
      }
    }
    final narrator = _catalogue.firstWhere(
      (model) => model.id == models['narrator']);
    if (!narrator.toolCompatible) {
      throw const OpenUncensoredFailure(
        'Compatibilité tool calling du narrateur non confirmée.');
    }
    final next = _state.copyWith(mode: OuQuality.advanced.name, models: models);
    await _write(next);
    if (!await _configure(next)) return false;
    return true;
  }) ?? false;

  /// Only call after an explicit confirmation from the user.
  String? revealKey(String id) => _state.find(id)?.secret;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
