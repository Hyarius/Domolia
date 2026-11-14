import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:jose/jose.dart';
import 'package:url_launcher/url_launcher.dart';

import 'ai_provider.dart';

/// The authorization record belongs to one named Domolia profile.
/// No OAuth token is stored in the unencrypted profile metadata.
class ChatGptSession {
  const ChatGptSession({
    required this.clientId,
    required this.subject,
    required this.email,
    required this.idToken,
    required this.accessToken,
    required this.refreshToken,
    required this.scopes,
    required this.expiresAt,
  });

  final String clientId;
  final String subject;
  final String email;
  final String idToken;
  final String accessToken;
  final String refreshToken;
  final Set<String> scopes;
  final DateTime expiresAt;

  bool get planEnabled => scopes.contains('chatgpt.tokens.use.direct') &&
      scopes.contains('resource.invoke');

  ChatGptSession copyWith({
    String? accessToken,
    String? refreshToken,
    String? idToken,
    Set<String>? scopes,
    DateTime? expiresAt,
  }) => ChatGptSession(
    clientId: clientId,
    subject: subject,
    email: email,
    idToken: idToken ?? this.idToken,
    accessToken: accessToken ?? this.accessToken,
    refreshToken: refreshToken ?? this.refreshToken,
    scopes: scopes ?? this.scopes,
    expiresAt: expiresAt ?? this.expiresAt,
  );

  Map<String, dynamic> toJson() => {
    'client_id': clientId,
    'sub': subject,
    'email': email,
    'id_token': idToken,
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'scopes': scopes.toList(),
    'expires_at': expiresAt.toUtc().toIso8601String(),
  };

  factory ChatGptSession.fromJson(Map<String, dynamic> value) {
    final scopes = value['scopes'];
    if (scopes is! List) {
      throw const FormatException('Session ChatGPT illisible.');
    }
    return ChatGptSession(
      clientId: value['client_id'] as String,
      subject: value['sub'] as String,
      email: value['email'] as String,
      idToken: value['id_token'] as String,
      accessToken: value['access_token'] as String,
      refreshToken: value['refresh_token'] as String,
      scopes: scopes.cast<String>().toSet(),
      expiresAt: DateTime.parse(value['expires_at'] as String),
    );
  }
}

abstract interface class ChatGptSessionStore {
  Future<String> hostId();
  Future<ChatGptSession?> read(String profileId);
  Future<void> write(String profileId, ChatGptSession session);
  Future<void> delete(String profileId);
}

class SecureChatGptSessionStore implements ChatGptSessionStore {
  SecureChatGptSessionStore({FlutterSecureStorage? storage})
      : _storage = storage ?? FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _hostIdKey = 'domolia.chatgpt.host-id.v1';

  String _sessionKey(String id) => 'domolia.chatgpt.session.v1.$id';

  @override
  Future<String> hostId() async {
    final existing = await _storage.read(key: _hostIdKey);
    if (existing != null) return existing;
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((part) => part.toRadixString(16).padLeft(2, '0')).join();
    final host = 'urn:uuid:${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    await _storage.write(key: _hostIdKey, value: host);
    return host;
  }

  @override
  Future<ChatGptSession?> read(String profileId) async {
    final raw = await _storage.read(key: _sessionKey(profileId));
    if (raw == null) return null;
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Session ChatGPT illisible.');
    }
    return ChatGptSession.fromJson(data);
  }

  @override
  Future<void> write(String profileId, ChatGptSession session) =>
      _storage.write(
        key: _sessionKey(profileId),
        value: jsonEncode(session.toJson()),
      );

  @override
  Future<void> delete(String profileId) =>
      _storage.delete(key: _sessionKey(profileId));
}

/// Redirect handling is injectable: widget and controller tests never open
/// a browser or contact OAuth endpoints.
abstract interface class ChatGptAuthBrowser {
  Future<Map<String, String>> authorize(Uri Function(Uri callback) buildUrl);
}

/// Loopback redirect mandated by the OSS Sign in with ChatGPT flow. Only
/// 127.0.0.1 is bound; the state and PKCE verifier are checked separately.
class LocalChatGptAuthBrowser implements ChatGptAuthBrowser {
  @override
  Future<Map<String, String>> authorize(Uri Function(Uri callback) buildUrl) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final callback = Uri.parse(
      'http://127.0.0.1:${server.port}/auth/callback',
    );
    try {
      final uri = buildUrl(callback);
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) {
        throw const AiProviderException('Impossible d’ouvrir la connexion ChatGPT.');
      }
      // The local server is single-subscription; accept exactly one callback.
      final request = await server.first.timeout(const Duration(minutes: 3));
      if (request.uri.path != '/auth/callback') {
        request.response.statusCode = 404;
        await request.response.close();
        throw const AiProviderException('Retour OAuth inattendu.');
      }
      final query = request.uri.queryParameters;
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<!doctype html><html><head><meta charset="utf-8"></head>'
        '<body>Retournez dans Domolia pour terminer la connexion.</body></html>',
      );
      await request.response.close();
      return query;
    } on TimeoutException {
      throw const AiProviderException(
        'La connexion ChatGPT a expiré. Réessayez.',
      );
    } finally {
      await server.close(force: true);
    }
  }
}

abstract interface class ChatGptAccountService {
  Future<ChatGptSession?> session(String profileId);
  Future<ChatGptSession> signIn(String profileId);
  Future<String> accessToken(String profileId);
  Future<List<AiModel>> listModels(String profileId);
  Future<void> disconnect(String profileId);
  Future<void> delete(String profileId);
}

/// Official OpenAI OSS dynamic-agent OAuth + PKCE. No client secret, no
/// impersonation of the ChatGPT app, no cookies or internal backend endpoints.
class ChatGptAuthService implements ChatGptAccountService {
  ChatGptAuthService({
    required this.store,
    http.Client? client,
    ChatGptAuthBrowser? browser,
  }) : _client = client ?? http.Client(),
       _browser = browser ?? LocalChatGptAuthBrowser();

  final ChatGptSessionStore store;
  final http.Client _client;
  final ChatGptAuthBrowser _browser;
  final Map<String, Future<ChatGptSession>> _refreshPending = {};

  static final _authUrl =
      Uri.parse('https://auth.openai.com/api/accounts/authorize');
  static final _tokenUrl =
      Uri.parse('https://auth.openai.com/api/accounts/oauth/token');
  static final _jwksUrl =
      Uri.parse('https://auth.openai.com/.well-known/jwks.json');
  static const _resource = 'https://api.openai.com/v1';
  static const _scopes =
      'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct';

  String _random(int length) {
    final random = Random.secure();
    return base64Url.encode(
      List<int>.generate(length, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
  }

  @override
  Future<ChatGptSession?> session(String profileId) => store.read(profileId);

  @override
  Future<ChatGptSession> signIn(String profileId) async {
    final old = await store.read(profileId);
    final host = await store.hostId();
    final state = _random(32);
    final nonce = _random(32);
    final verifier = _random(48);
    final challenge = base64Url.encode(
      sha256.convert(ascii.encode(verifier)).bytes,
    ).replaceAll('=', '');
    late Uri redirect;
    final query = await _browser.authorize((callback) {
      redirect = callback;
      final values = <String, String>{
        'client_id': old?.clientId ?? 'dynamic_agent_client',
        'response_type': 'code',
        'redirect_uri': callback.toString(),
        'scope': _scopes,
        'resource': _resource,
        'ext_agent_host_id': host,
        'state': state,
        'nonce': nonce,
        'code_challenge_method': 'S256',
        'code_challenge': challenge,
      };
      if (old == null) {
        values['agent_name_hint'] = 'Domolia';
      } else {
        values['id_token_hint'] = old.idToken;
        if (old.email.isNotEmpty) values['login_hint'] = old.email;
      }
      return _authUrl.replace(queryParameters: values);
    });
    if (query['state'] != state) {
      throw const AiProviderException('Retour de connexion ChatGPT non vérifié.');
    }
    if (query['error'] != null) {
      throw const AiProviderException(
        'Connexion ChatGPT refusée ou annulée.',
      );
    }
    final clientId = query['client_id'] ?? old?.clientId;
    final code = query['code'];
    if (clientId == null || code == null || code.isEmpty ||
        clientId == 'dynamic_agent_client' ||
        (old != null && clientId != old.clientId)) {
      throw const AiProviderException('Enregistrement ChatGPT incomplet.');
    }
    final tokenData = await _tokenRequest({
      'grant_type': 'authorization_code',
      'client_id': clientId,
      'code': code,
      'code_verifier': verifier,
      'redirect_uri': redirect.toString(),
      'resource': _resource,
    });
    final identity = await _validateIdentity(
      tokenData['id_token'] as String,
      clientId: clientId,
      nonce: nonce,
    );
    if (old != null && old.subject != identity.subject) {
      throw const AiProviderException('Le compte ChatGPT ne correspond pas au profil.');
    }
    final scopes = (tokenData['scope'] as String).split(' ').toSet();
    final result = ChatGptSession(
      clientId: clientId,
      subject: identity.subject,
      email: identity.email,
      idToken: tokenData['id_token'] as String,
      accessToken: tokenData['access_token'] as String,
      refreshToken: tokenData['refresh_token'] as String,
      scopes: scopes,
      expiresAt: DateTime.now().toUtc().add(
        Duration(seconds: tokenData['expires_in'] as int),
      ),
    );
    await store.write(profileId, result);
    return result;
  }

  Future<Map<String, dynamic>> _tokenRequest(Map<String, String> form) async {
    http.Response response;
    try {
      response = await _client.post(
        _tokenUrl,
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: form,
      ).timeout(const Duration(seconds: 25));
    } catch (_) {
      throw const AiProviderException('Impossible de contacter OpenAI pour la connexion.');
    }
    if (response.statusCode != 200) {
      throw const AiProviderException(
        'Authentification ChatGPT refusée. Reconnectez votre compte.',
      );
    }
    try {
      final data = jsonDecode(response.body);
      if (data is Map<String, dynamic> &&
          data['access_token'] is String &&
          data['refresh_token'] is String &&
          data['expires_in'] is int &&
          data['scope'] is String) {
        return data;
      }
    } catch (_) {
      // Never expose token response or internal server errors.
    }
    throw const AiProviderException('Réponse de connexion ChatGPT invalide.');
  }

  Future<({String subject, String email})> _validateIdentity(
    String idToken, {
    required String clientId,
    required String nonce,
  }) async {
    try {
      final response = await _client.get(_jwksUrl).timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200) throw const FormatException();
      final jwks = jsonDecode(response.body);
      if (jwks is! Map<String, dynamic>) throw const FormatException();
      final keyStore = JsonWebKeyStore()
        ..addKeySet(JsonWebKeySet.fromJson(jwks));
      final jwt = JsonWebToken.unverified(idToken);
      if (!await jwt.verify(keyStore)) throw const FormatException();
      final claims = jwt.claims;
      if (claims.issuer != Uri.parse('https://auth.openai.com') ||
          claims.audience?.contains(clientId) != true ||
          claims.expiry == null ||
          !claims.expiry!.isAfter(DateTime.now().toUtc()) ||
          claims.notBefore?.isAfter(DateTime.now().toUtc()) == true ||
          claims['nonce'] != nonce ||
          claims.subject == null ||
          claims.subject!.isEmpty) {
        throw const FormatException();
      }
      return (
        subject: claims.subject!,
        email: claims['email'] is String ? claims['email'] as String : '',
      );
    } catch (_) {
      throw const AiProviderException(
        'L’identité ChatGPT n’a pas pu être vérifiée.',
      );
    }
  }

  @override
  Future<String> accessToken(String profileId) async {
    var current = await store.read(profileId);
    if (current == null || !current.planEnabled) {
      throw const AiProviderException(
        'Connectez ChatGPT et autorisez l’utilisation de votre abonnement.',
      );
    }
    if (DateTime.now().toUtc().isBefore(
      current.expiresAt.subtract(const Duration(minutes: 3)),
    )) {
      return current.accessToken;
    }
    final pending = _refreshPending[profileId] ??=
        _refresh(profileId, current);
    try {
      current = await pending;
      if (!current.planEnabled) {
        throw const AiProviderException(
          'L’utilisation de votre abonnement ChatGPT n’est pas autorisée.',
        );
      }
      return current.accessToken;
    } finally {
      _refreshPending.remove(profileId);
    }
  }

  Future<ChatGptSession> _refresh(
    String profileId,
    ChatGptSession old,
  ) async {
    final data = await _tokenRequest({
      'grant_type': 'refresh_token',
      'client_id': old.clientId,
      'refresh_token': old.refreshToken,
      'resource': _resource,
    });
    final replacement = old.copyWith(
      accessToken: data['access_token'] as String,
      refreshToken: data['refresh_token'] as String,
      scopes: (data['scope'] as String).split(' ').toSet(),
      expiresAt: DateTime.now().toUtc().add(
        Duration(seconds: data['expires_in'] as int),
      ),
    );
    await store.write(profileId, replacement);
    return replacement;
  }

  @override
  Future<List<AiModel>> listModels(String profileId) async {
    final token = await accessToken(profileId);
    try {
      final response = await _client.get(
        Uri.parse('https://api.openai.com/v1/models'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) {
        throw const AiProviderException(
          'Impossible de charger les modèles de votre compte ChatGPT.',
        );
      }
      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic> || data['models'] is! List) {
        throw const FormatException();
      }
      return [
        for (final model in data['models'] as List)
          if (model is Map<String, dynamic> &&
              model['visibility'] == 'list' &&
              model['slug'] is String)
            AiModel(model['slug'] as String),
      ];
    } on AiProviderException {
      rethrow;
    } catch (_) {
      throw const AiProviderException('Catalogue ChatGPT indisponible.');
    }
  }

  Future<Uri> _revocationEndpoint() async {
    try {
      final response = await _client.get(
        Uri.parse('https://auth.openai.com/.well-known/openid-configuration'),
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) throw const FormatException();
      final body = jsonDecode(response.body);
      final raw = body is Map<String, dynamic>
          ? body['revocation_endpoint'] : null;
      final endpoint = raw is String ? Uri.tryParse(raw) : null;
      if (endpoint == null ||
          endpoint.scheme != 'https' ||
          endpoint.host != 'auth.openai.com') {
        throw const FormatException();
      }
      return endpoint;
    } catch (_) {
      throw const AiProviderException(
        'Impossible de vérifier la révocation ChatGPT.',
      );
    }
  }

  @override
  Future<void> disconnect(String profileId) async {
    final current = await store.read(profileId);
    if (current == null) return;
    try {
      final response = await _client.post(
        await _revocationEndpoint(),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'token': current.refreshToken,
          'token_type_hint': 'refresh_token',
          'client_id': current.clientId,
        },
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw const AiProviderException(
          'Révocation distante non confirmée. Révoquez Domolia dans ChatGPT.',
        );
      }
    } on AiProviderException {
      rethrow;
    } catch (_) {
      throw const AiProviderException(
        'Révocation distante non confirmée. Révoquez Domolia dans ChatGPT.',
      );
    } finally {
      await store.delete(profileId);
    }
  }

  @override
  Future<void> delete(String profileId) => disconnect(profileId);
}
