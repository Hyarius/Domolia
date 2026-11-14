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

  void addRawResponse(List<int> bytes) {
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
      'truncated': truncated,
    },
  };

  String exportJson() => const JsonEncoder.withIndent('  ').convert(toJson());
}
