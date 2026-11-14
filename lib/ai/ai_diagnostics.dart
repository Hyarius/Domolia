import 'dart:convert';
import 'dart:typed_data';

/// A deliberately bounded, in-memory record of the actual outgoing HTTP
/// JSON and the unparsed incoming HTTP response. Nothing is persisted until
/// the user explicitly exports it. Never store Authorization credentials.
class AiExchangeRecorder {
  AiExchange? last;

  AiExchange begin({
    required String provider,
    required String method,
    required String url,
    required String requestBody,
    required String secret,
    required String accept,
  }) {
    final value = AiExchange._(
      provider: provider,
      method: method,
      url: url,
      requestBody: requestBody,
      secret: secret,
      accept: accept,
    );
    last = value;
    return value;
  }
}

class AiExchange {
  AiExchange._({
    required this.provider,
    required this.method,
    required this.url,
    required this.requestBody,
    required this._secret,
    required this.accept,
  });

  static const maxRawResponseBytes = 1024 * 1024;
  final DateTime createdAtUtc = DateTime.now().toUtc();
  final String provider;
  final String method;
  final String url;
  final String requestBody;
  final String accept;
  final String _secret;
  final BytesBuilder _response = BytesBuilder(copy: false);
  int? statusCode;
  bool truncated = false;
  int totalResponseBytes = 0;
  DateTime? completedAtUtc;
  int? promptTokens;
  int? completionTokens;
  String? error;
  bool cancelled = false;
  List<Map<String, dynamic>> interpretedEvents = const [];

  /// Called after the narrator has decoded the response (also on failure).
  void complete({
    int? promptTokens,
    int? completionTokens,
    String? error,
    bool cancelled = false,
    List<Map<String, dynamic>> interpretedEvents = const [],
  }) {
    completedAtUtc = DateTime.now().toUtc();
    this.promptTokens = promptTokens;
    this.completionTokens = completionTokens;
    this.error = error;
    this.cancelled = cancelled;
    this.interpretedEvents = List.unmodifiable(interpretedEvents);
  }

  void addRawResponse(List<int> bytes) {
    totalResponseBytes += bytes.length;
    final left = maxRawResponseBytes - _response.length;
    if (left <= 0) {
      truncated = true;
      return;
    }
    if (bytes.length > left) truncated = true;
    _response.add(bytes.length > left ? bytes.sublist(0, left) : bytes);
  }

  String _redact(String value) {
    var result = value;
    if (_secret.isNotEmpty) result = result.replaceAll(_secret, '[REDACTED]');
    // Also redact credential-like strings returned by upstream error bodies.
    return result.replaceAll(
      RegExp(r'Bearer\s+[^\s"\\]+', caseSensitive: false),
      'Bearer [REDACTED]',
    );
  }

  /// The request body is captured verbatim from http.Request.body; only
  /// credentials are redacted. The response is the raw SSE/HTTP body, not
  /// the decoded narrative or a reconstructed answer.
  Map<String, dynamic> toJson() => {
    'format': 'domolia-ai-exchange-v1',
    'recordedAtUtc': createdAtUtc.toIso8601String(),
    'completedAtUtc': completedAtUtc?.toIso8601String(),
    'durationMs': completedAtUtc?.difference(createdAtUtc).inMilliseconds,
    'provider': provider,
    'credentialsRedacted': true,
    'request': {
      'method': method,
      'url': url,
      'headers': {
        'Authorization': 'Bearer [REDACTED]',
        'Content-Type': 'application/json',
        'Accept': accept,
      },
      'rawBody': _redact(requestBody),
      'body': jsonDecode(_redact(requestBody)),
    },
    'response': {
      'statusCode': statusCode,
      'rawBody': _redact(utf8.decode(_response.toBytes(), allowMalformed: true)),
      'capturedBytes': _response.length,
      'totalBytesReceived': totalResponseBytes,
      'truncated': truncated,
    },
    'interpretation': {
      'promptTokens': promptTokens,
      'completionTokens': completionTokens,
      'cancelled': cancelled,
      'error': error == null ? null : _redact(error!),
      'events': [
        for (final event in interpretedEvents)
          {
            for (final field in event.entries)
              field.key: field.value is String ? _redact(field.value as String) : field.value,
          },
      ],
    },
  };

  String exportJson() => const JsonEncoder.withIndent('  ').convert(toJson());
}


/// An already-redacted diagnostic tied to one locally stored conversation.
/// No credentials or Authorization header values are ever persisted.
class StoredAiDiagnostic {
  const StoredAiDiagnostic({
    required this.id,
    required this.sessionId,
    required this.createdAtUtc,
    required this.content,
  });

  final String id;
  final String sessionId;
  final DateTime createdAtUtc;
  final String content;

  Map<String, dynamic> get data =>
      jsonDecode(content) as Map<String, dynamic>;

  String get model {
    final request = data['request'];
    if (request is! Map<String, dynamic>) return 'Modèle inconnu';
    final body = request['body'];
    if (body is! Map<String, dynamic>) return 'Modèle inconnu';
    return body['model'] is String ? body['model'] as String : 'Modèle inconnu';
  }

  int? get statusCode {
    final response = data['response'];
    return response is Map<String, dynamic> ? response['statusCode'] as int? : null;
  }
}
