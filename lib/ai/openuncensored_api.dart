import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Only static, sanitized failures are exposed. Never attach response bodies
/// or request URLs to an exception: a checkout body contains a prepaid key.
class OpenUncensoredFailure implements Exception {
  const OpenUncensoredFailure(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

bool validOpenUncensoredKey(String key) =>
    RegExp(r'^ou-[a-zA-Z0-9_-]{8,}$').hasMatch(key.trim());

class OuBalance {
  const OuBalance({
    required this.remainingUsd,
    required this.balanceUsd,
    required this.pendingUsd,
  });
  final double remainingUsd;
  final double balanceUsd;
  final double pendingUsd;

  static OuBalance parse(Object? raw) {
    if (raw is! Map<String, dynamic> || raw['data'] is! Map<String, dynamic>) {
      throw const OpenUncensoredFailure('Solde reçu dans un format inattendu.');
    }
    final data = raw['data'] as Map<String, dynamic>;
    if (data['currency'] != 'usd') {
      throw const OpenUncensoredFailure('Devise du solde non reconnue.');
    }
    double amount(String field, {bool optional = false}) {
      final value = data[field];
      if (value == null && optional) return 0;
      if (value is! num || !value.toDouble().isFinite) {
        throw const OpenUncensoredFailure('Montant du solde invalide.');
      }
      return value.toDouble();
    }
    return OuBalance(
      remainingUsd: amount('remaining_usd'),
      balanceUsd: amount('balance_usd'),
      pendingUsd: amount('pending_usage_usd', optional: true),
    );
  }
}

class OuCheckout {
  const OuCheckout(this.sessionId, this.claimToken, this.paymentUrl);
  final String sessionId;
  final String claimToken;
  final Uri paymentUrl;

  static OuCheckout parse(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const OpenUncensoredFailure('Session de paiement invalide.');
    }
    final id = raw['session_id'];
    final claim = raw['claim_token'];
    final url = raw['payment_url'];
    if (id is! String || claim is! String || url is! String ||
        !RegExp(r'^cs_[a-zA-Z0-9_]+$').hasMatch(id) ||
        claim.isEmpty || claim.length > 1024) {
      throw const OpenUncensoredFailure('Informations de paiement incomplètes.');
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' ||
        !{'checkout.stripe.com', 'buy.stripe.com'}.contains(uri.host) ||
        uri.userInfo.isNotEmpty) {
      throw const OpenUncensoredFailure('Adresse de paiement non sécurisée.');
    }
    return OuCheckout(id, claim, uri);
  }
}

enum OuCheckoutStatus { pending, paid, refused, expired }

class OuCheckoutResult {
  const OuCheckoutResult(this.status, {this.apiKey, this.balanceCents});
  final OuCheckoutStatus status;
  final String? apiKey;
  final int? balanceCents;
  static OuCheckoutResult parse(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const OpenUncensoredFailure('Confirmation de paiement illisible.');
    }
    final status = switch (raw['status']) {
      'pending' => OuCheckoutStatus.pending,
      'paid' => OuCheckoutStatus.paid,
      'expired' => OuCheckoutStatus.expired,
      'refused' => OuCheckoutStatus.refused,
      _ => throw const OpenUncensoredFailure('État de paiement inconnu.'),
    };
    final key = raw['api_key'];
    final balance = raw['balance_cents'];
    if (key != null && (key is! String || !validOpenUncensoredKey(key))) {
      throw const OpenUncensoredFailure('Clé reçue dans un format inattendu.');
    }
    if (balance != null && (balance is! int || balance < -100000000)) {
      throw const OpenUncensoredFailure('Montant de recharge invalide.');
    }
    return OuCheckoutResult(status, apiKey: key as String?, balanceCents: balance as int?);
  }
}

/// Public catalogue metadata; no API key or paid generation is involved.
class OuModel {
  const OuModel({
    required this.id,
    required this.available,
    required this.toolCompatible,
    required this.inputPerTokenUsd,
    required this.outputPerTokenUsd,
  });
  final String id;
  final bool available;
  /// True only if the catalogue explicitly advertises support. Unknown is
  /// treated as false until the tool-calling PR supplies its capability model.
  final bool toolCompatible;
  final double? inputPerTokenUsd;
  final double? outputPerTokenUsd;

  static OuModel? parse(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        raw['id'] is! String ||
        (raw['id'] as String).isEmpty ||
        raw['modality'] != null && raw['modality'] != 'text') {
      return null;
    }
    final pricing = raw['pricing'];
    double? price(String key) {
      if (pricing is! Map) return null;
      final value = pricing[key];
      final parsed = value is num ? value.toDouble() :
          value is String ? double.tryParse(value) : null;
      return parsed != null && parsed.isFinite && parsed >= 0 ? parsed : null;
    }
    final caps = raw['capabilities'];
    final params = raw['supported_parameters'];
    final providers = raw['providers'];
    final explicitTools = raw['supports_tools'] == true ||
        raw['tool_calling'] == true ||
        (caps is Map && (caps['tools'] == true || caps['tool_calling'] == true)) ||
        (params is List && params.contains('tools')) ||
        (providers is List && providers.any((provider) =>
          provider is Map && (provider['supports_tools'] == true ||
            provider['tool_calling'] == true)));
    return OuModel(
      id: raw['id'] as String,
      available: raw['available'] != false,
      toolCompatible: explicitTools,
      inputPerTokenUsd: price('prompt'),
      outputPerTokenUsd: price('completion'),
    );
  }
}

class OpenUncensoredApi {
  OpenUncensoredApi({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  static final Uri _api = Uri.parse('https://api.openuncensored.com/v1/');
  static final Uri _site = Uri.parse('https://openuncensored.com/api/agent/');

  Future<Object?> _request(Uri url, {String? bearer, Object? body}) async {
    final request = http.Request(body == null ? 'GET' : 'POST', url)
      ..followRedirects = false
      ..headers['Accept'] = 'application/json';
    if (bearer != null) request.headers['Authorization'] = 'Bearer $bearer';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      final streamed = await _client.send(request).timeout(const Duration(seconds: 20));
      if (streamed.statusCode != 200) {
        switch (streamed.statusCode) {
          case 401:
          case 403:
            throw const OpenUncensoredFailure('Clé ou autorisation refusée.', statusCode: 401);
          case 402:
            throw const OpenUncensoredFailure('Solde insuffisant.', statusCode: 402);
          case 400:
          case 422:
            throw const OpenUncensoredFailure('Requête refusée par OpenUncensored.', statusCode: 400);
          default:
            throw OpenUncensoredFailure(
              'OpenUncensored est indisponible (HTTP ${streamed.statusCode}).',
              statusCode: streamed.statusCode,
            );
        }
      }
      final response = await http.Response.fromStream(streamed)
          .timeout(const Duration(seconds: 20));
      if (response.bodyBytes.length > 4 * 1024 * 1024) {
        throw const OpenUncensoredFailure('Réponse trop volumineuse.');
      }
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on OpenUncensoredFailure {
      rethrow;
    } on TimeoutException {
      throw const OpenUncensoredFailure('Délai de connexion dépassé.');
    } on FormatException {
      throw const OpenUncensoredFailure('Réponse du fournisseur illisible.');
    } catch (_) {
      throw const OpenUncensoredFailure('Impossible de joindre OpenUncensored.');
    }
  }

  Future<OuBalance> balance(String key) async {
    if (!validOpenUncensoredKey(key)) {
      throw const OpenUncensoredFailure('Format de clé OpenUncensored invalide.');
    }
    return OuBalance.parse(await _request(_api.resolve('credits'), bearer: key.trim()));
  }

  Future<List<OuModel>> models() async {
    final response = await _request(_api.resolve('models?available=true'));
    if (response is! Map<String, dynamic> || response['data'] is! List) {
      throw const OpenUncensoredFailure('Catalogue de modèles illisible.');
    }
    final models = (response['data'] as List)
        .map(OuModel.parse).whereType<OuModel>()
        .where((model) => model.available).toList();
    models.sort((a, b) => a.id.compareTo(b.id));
    return models;
  }

  Future<OuCheckout> checkout({required int cents, String? topUpKey}) async {
    if (cents < 500 || cents > 100000) {
      throw const OpenUncensoredFailure('Choisissez un montant entre 5 USD et 1 000 USD.');
    }
    if (topUpKey != null && !validOpenUncensoredKey(topUpKey)) {
      throw const OpenUncensoredFailure('Clé de recharge invalide.');
    }
    final payload = <String, Object>{'credits': cents};
    if (topUpKey != null) payload['key'] = topUpKey.trim();
    return OuCheckout.parse(await _request(_site.resolve('checkout'), body: payload));
  }

  Future<OuCheckoutResult> check(String sessionId, String claimToken) async {
    if (!RegExp(r'^cs_[a-zA-Z0-9_]+$').hasMatch(sessionId) ||
        claimToken.isEmpty || claimToken.length > 1024) {
      throw const OpenUncensoredFailure('Session de paiement invalide.');
    }
    return OuCheckoutResult.parse(await _request(
      _site.resolve('checkout/${Uri.encodeComponent(sessionId)}'),
      bearer: claimToken,
    ));
  }

  void close() => _client.close();
}
