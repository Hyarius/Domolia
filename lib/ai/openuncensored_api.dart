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

/// Catalogue evidence is distinct from an actual tool-call test.
enum OuToolSupport { supported, unsupported, unknown }

/// A successful HTTP response without a real function invocation is NOT proof.
enum OuToolProbeOutcome { supported, unsupported, inconclusive }

/// Public catalogue metadata. Missing flags must never mean "unsupported".
class OuModel {
  const OuModel({
    required this.id,
    required this.available,
    required this.toolSupport,
    required this.inputPerTokenUsd,
    required this.outputPerTokenUsd,
  });

  final String id;
  final bool available;
  final OuToolSupport toolSupport;
  bool get toolCompatible => toolSupport == OuToolSupport.supported;
  final double? inputPerTokenUsd;
  final double? outputPerTokenUsd;

  static OuToolSupport _tools(Map<String, dynamic> raw) {
    final capabilities = raw['capabilities'];
    final parameters = raw['supported_parameters'];
    final providers = raw['providers'];
    final sources = <Object?>[
      raw['supports_tools'], raw['tool_calling'],
      if (capabilities is Map) ...[
        capabilities['tools'], capabilities['tool_calling'],
      ],
    ];
    if (sources.contains(true) ||
        parameters is List && parameters.contains('tools')) {
      return OuToolSupport.supported;
    }
    if (providers is List) {
      for (final item in providers) {
        if (item is Map &&
            (item['supports_tools'] == true || item['tool_calling'] == true)) {
          return OuToolSupport.supported;
        }
      }
    }
    if (sources.contains(false)) return OuToolSupport.unsupported;
    // An unknown provider never makes an entire multi-provider model
    // incompatible. All provider entries must explicitly reject tools.
    if (providers is List && providers.isNotEmpty &&
        providers.every((item) => item is Map &&
            (item['supports_tools'] == false ||
                item['tool_calling'] == false))) {
      return OuToolSupport.unsupported;
    }
    return OuToolSupport.unknown;
  }

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
    return OuModel(
      id: raw['id'] as String,
      available: raw['available'] != false,
      toolSupport: _tools(raw),
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

  /// Explicit, small, potentially billable probe. No tool is executed.
  /// Only a correctly structured function call proves compatibility.
  /// Unknown/ambiguous responses remain inconclusive, never unsupported.
  Future<OuToolProbeOutcome> probeToolCalling(
      String key, String model) async {
    if (!validOpenUncensoredKey(key) ||
        model.trim().isEmpty || model.length > 200 ||
        model.contains(RegExp(r'[\\r\\n]'))) {
      throw const OpenUncensoredFailure('Modèle ou clé de test invalide.');
    }
    final request = http.Request('POST', _api.resolve('chat/completions'))
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer ${key.trim()}'
      ..headers['Accept'] = 'application/json'
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'model': model,
        'stream': false,
        'max_tokens': 96,
        'messages': [
          {'role': 'system', 'content':
              'Diagnostic technique. Utilise exclusivement la fonction '
              'domolia_tool_probe avec value égal à ok.'},
          {'role': 'user', 'content':
              'Appelle maintenant domolia_tool_probe avec value = ok.'},
        ],
        'tools': [
          {'type': 'function', 'function': {
            'name': 'domolia_tool_probe',
            'description': 'Diagnostic ponctuel de compatibilité des outils.',
            'parameters': {'type': 'object', 'properties': {
              'value': {'type': 'string', 'enum': ['ok']},
            }, 'required': ['value'], 'additionalProperties': false},
          }},
        ],
        'tool_choice': 'auto',
      });
    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw const OpenUncensoredFailure('Test expiré. Compatibilité inconnue.');
    } catch (_) {
      throw const OpenUncensoredFailure('Connexion impossible pendant le test.');
    }
    http.Response result;
    try {
      result = await http.Response.fromStream(response)
          .timeout(const Duration(seconds: 40));
    } catch (_) {
      throw const OpenUncensoredFailure('Réponse du test incomplète.');
    }
    if (result.bodyBytes.length > 65536) {
      throw const OpenUncensoredFailure('Réponse du test trop volumineuse.');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(result.bodyBytes));
    } catch (_) {
      throw const OpenUncensoredFailure('Réponse du test illisible.');
    }
    if (result.statusCode != 200) {
      if ((result.statusCode == 400 || result.statusCode == 422) &&
          decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          final code = error['code']?.toString().toLowerCase() ?? '';
          final param = error['param']?.toString().toLowerCase() ?? '';
          final message = error['message']?.toString().toLowerCase() ?? '';
          if (param == 'tools' || param == 'tool_choice' ||
              code.contains('unsupported_tool') ||
              message.contains('tool calling is not supported') ||
              message.contains('tools are not supported') ||
              message.contains('tool_choice is not supported')) {
            return OuToolProbeOutcome.unsupported;
          }
        }
      }
      if (result.statusCode == 401 || result.statusCode == 403) {
        throw const OpenUncensoredFailure('Clé API refusée.');
      }
      if (result.statusCode == 402) {
        throw const OpenUncensoredFailure('Crédits insuffisants pour le test.');
      }
      if (result.statusCode == 429) {
        throw const OpenUncensoredFailure('Limite de débit atteinte.');
      }
      throw OpenUncensoredFailure(
          'Test refusé par le fournisseur (HTTP ${result.statusCode}).');
    }
    if (decoded is! Map || decoded['choices'] is! List ||
        (decoded['choices'] as List).isEmpty) {
      return OuToolProbeOutcome.inconclusive;
    }
    final choice = (decoded['choices'] as List).first;
    if (choice is! Map || choice['message'] is! Map) {
      return OuToolProbeOutcome.inconclusive;
    }
    final calls = (choice['message'] as Map)['tool_calls'];
    if (calls is! List) return OuToolProbeOutcome.inconclusive;
    for (final call in calls) {
      if (call is! Map || call['type'] != 'function' ||
          call['function'] is! Map) continue;
      final function = call['function'] as Map;
      if (function['name'] != 'domolia_tool_probe' ||
          function['arguments'] is! String) continue;
      try {
        final args = jsonDecode(function['arguments'] as String);
        if (args is Map && args['value'] == 'ok') {
          return OuToolProbeOutcome.supported;
        }
      } catch (_) {
        // A malformed function argument does not prove tool support.
      }
    }
    return OuToolProbeOutcome.inconclusive;
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
