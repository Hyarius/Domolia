import 'ai_provider.dart';

// Public types shared with AiConnectionController. Actual OAuth is deliberately
// unavailable on Web: the native implementation requires a localhost server.
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
}

abstract interface class ChatGptAccountService {
  Future<ChatGptSession?> session(String profileId);
  Future<ChatGptSession> signIn(String profileId);
  Future<String> accessToken(String profileId);
  Future<List<AiModel>> listModels(String profileId);
  Future<void> disconnect(String profileId);
  Future<void> delete(String profileId);
}
