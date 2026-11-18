import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../logging/app_logger.dart';

/// A deliberately bounded record of the actual outgoing HTTP JSON and
/// incoming HTTP response. The hosting Party may persist redacted exchanges
/// locally according to its retention policy; app-level logs contain metadata
/// only. Never store Authorization credentials.
class AiExchangeRecorder {
  AiExchange? last;

  // Scope a specific HTTP request to its owner without stealing the
  // narrator's shared "last" exchange during overlapping image work.
  static final Object _captureZoneKey = Object();

  Future<T> captureDuring<T>(
    Future<T> Function() action,
    void Function(AiExchange) onBegin,
  ) => runZoned(action, zoneValues: {_captureZoneKey: onBegin});

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
    // One lightweight app-log entry for every outgoing AI request, including
    // image preparation and model lookups. The full prompt is only available
    // in the per-Party diagnostics, never in the shared app journal.
    AppLogger.info('Appel IA lancé', component: 'ai.http', details: {
      'exchangeId': value.createdAtUtc.microsecondsSinceEpoch,
      'provider': provider,
      'method': method,
    });
    final capture = Zone.current[_captureZoneKey];
    if (capture is void Function(AiExchange)) {
      capture(value);
    } else {
      last = value;
    }
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
  /// Logical pipeline stage; the HTTP envelope remains unchanged.
  String? stage;
  /// Stable originating player message, shared by both AI exchanges.
  int? playerEventId;
  int? statusCode;
  bool truncated = false;
  int totalResponseBytes = 0;
  DateTime? completedAtUtc;
  int? promptTokens;
  int? completionTokens;
  int toolCalls = 0;
  String? error;
  bool cancelled = false;
  bool _completionLogged = false;
  List<Map<String, dynamic>> interpretedEvents = const [];

  /// Called after the narrator has decoded the response (also on failure).
  void complete({
    int? promptTokens,
    int? completionTokens,
    int toolCalls = 0,
    String? error,
    bool cancelled = false,
    List<Map<String, dynamic>> interpretedEvents = const [],
  }) {
    completedAtUtc = DateTime.now().toUtc();
    this.promptTokens = promptTokens;
    this.completionTokens = completionTokens;
    this.toolCalls = toolCalls;
    this.error = error;
    this.cancelled = cancelled;
    this.interpretedEvents = List.unmodifiable(interpretedEvents);
    // Some stages enrich a captured exchange after the transport has ended.
    // Emit a single terminal record rather than counting one request twice.
    if (!_completionLogged) {
      _completionLogged = true;
      final details = <String, Object?>{
        'exchangeId': createdAtUtc.microsecondsSinceEpoch,
        'provider': provider,
        'stage': stage ?? 'unclassified',
        'durationMs': completedAtUtc!.difference(createdAtUtc).inMilliseconds,
        'toolCalls': toolCalls,
        'cancelled': cancelled,
      };
      if (playerEventId != null) details['playerEventId'] = playerEventId;
      if (statusCode != null) details['statusCode'] = statusCode;
      if (promptTokens != null) details['promptTokens'] = promptTokens;
      if (completionTokens != null) {
        details['completionTokens'] = completionTokens;
      }
      if (error == null && !cancelled && (statusCode == null || statusCode! < 400)) {
        AppLogger.info('Appel IA terminé', component: 'ai.http',
            details: details);
      } else {
        AppLogger.warning('Appel IA interrompu ou échoué',
            component: 'ai.http', details: details);
      }
    }
  }

  /// Tool rounds are billed and recorded before local theatrical decoding.
  /// Enrich the same HTTP exchange afterwards, without creating a second call.
  void attachInterpretedEvents(List<Map<String, dynamic>> events) {
    interpretedEvents = List.unmodifiable(events);
  }

  /// Binary image responses must never be copied into diagnostics.
  /// Record only safe response metadata and the real transfer size.
  void addRedactedResponseSummary(Map<String, dynamic> summary,
      {required int actualBytes}) {
    if (totalResponseBytes != 0 || _response.length != 0) {
      throw StateError('La réponse a déjà été enregistrée.');
    }
    final bytes = utf8.encode(jsonEncode(summary));
    if (bytes.length > maxRawResponseBytes) {
      throw ArgumentError('Résumé de réponse trop volumineux.');
    }
    _response.add(bytes);
    totalResponseBytes = actualBytes;
    truncated = actualBytes > bytes.length;
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
    if (stage != null) 'stage': stage,
    if (playerEventId != null) 'playerEventId': playerEventId,
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
      'body': requestBody.trim().isEmpty
          ? null : jsonDecode(_redact(requestBody)),
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
      'toolCalls': toolCalls,
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

  bool isNarratorForTurn(int playerId) {
    final stage = data['stage'];
    return data['playerEventId'] == playerId &&
        (stage == 'narrator_raw' ||
         stage == 'narrator_structured' ||
         (stage is String && stage.startsWith('narrator_tool_round_')));
  }

  /// An AI request can produce multiple chat bubbles; each keeps its own
  /// event ID in the interpreted events of the exact captured HTTP exchange.
  bool containsMessage(int messageId) {
    final interpretation = data['interpretation'];
    if (interpretation is! Map<String, dynamic>) return false;
    final events = interpretation['events'];
    if (events is! List) return false;
    return events.any((event) => event is Map &&
        event['type'] == 'message' && event['id'] == messageId);
  }
}
