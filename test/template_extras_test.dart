import 'dart:convert';
import 'dart:io';

import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_lore.dart';
import 'package:domolia/logging/app_logger.dart';
import 'package:domolia/memory/live_memory.dart';
import 'package:flutter_test/flutter_test.dart';

String _read(String filename) =>
    File('template/$filename').readAsStringSync();

Map<String, dynamic> _json(String filename) =>
    jsonDecode(_read(filename)) as Map<String, dynamic>;

void main() {
  test('standalone Lore mirrors the valid importable Book exactly', () {
    final lore = _json('lore_template.json');
    final book = BookDefinition.importJson(_read('livre_template.json'));
    expect(BookLore.fromJson(lore).toJson(), lore);
    expect(book.lore.toJson(), lore);
  });

  test('Live Memory operation template is accepted by the real validator', () {
    final source = _read('live_memory_operations_template.json');
    const playerText = 'Je promets de revenir avant minuit.';
    final ops = LiveMemoryOperation.parse(
      source,
      playerEventId: 1,
      playerText: playerText,
      validatedRaw: 'Tomas : Je vous attends.',
    );
    expect(ops, hasLength(1));
    expect(ops.single.action, 'upsert');
    expect(ops.single.fact.category, 'commitment');
    expect(ops.single.fact.sourceTurnId, 1);
    expect(playerText, contains(ops.single.fact.sourceQuote));
  });

  test('AI exchange template matches the exported redacted envelope', () {
    final exchange = _json('echange_ia_template.json');
    expect(exchange['format'], 'domolia-ai-exchange-v1');
    expect(exchange['credentialsRedacted'], isTrue);
    final request = exchange['request'] as Map<String, dynamic>;
    final headers = request['headers'] as Map<String, dynamic>;
    expect(headers['Authorization'], 'Bearer [REDACTED]');
    expect(jsonDecode(request['rawBody'] as String), request['body']);
    final response = exchange['response'] as Map<String, dynamic>;
    expect(response['capturedBytes'],
        utf8.encode(response['rawBody'] as String).length);
    final events =
        (exchange['interpretation'] as Map<String, dynamic>)['events'] as List;
    expect(events, isNotEmpty);
  });

  test('application log template is valid JSONL', () {
    final lines = _read('app_logs_template.jsonl').trimRight().split('\n');
    expect(lines, isNotEmpty);
    for (final line in lines) {
      final entry = AppLogEntry.fromJson(
        jsonDecode(line) as Map<String, dynamic>,
      );
      expect(entry.level, AppLogLevel.info);
      expect(entry.message, isNotEmpty);
    }
  });
}
