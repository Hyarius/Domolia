import 'dart:convert';
import 'dart:io';

import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_lore.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/logging/app_logger.dart';
import 'package:domolia/memory/live_memory.dart';
import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File('template/$path').readAsStringSync();
Map<String, dynamic> _object(String name) =>
    jsonDecode(_read(name)) as Map<String, dynamic>;

void main() {
  test('book template is directly importable and round-trips losslessly', () {
    final original = _object('livre_template.json');
    final book = BookDefinition.importJson(_read('livre_template.json'));
    expect(book.id, 'livre_template');
    expect(book.tags, isEmpty);
    expect(book.extensions, isEmpty);
    expect(book.lore.characters, hasLength(2));
    expect(book.lore.places, hasLength(2));
    expect(book.lore.scenarios, hasLength(1));
    expect(book.lore.events, hasLength(2));
    expect(jsonDecode(book.exportJson()), original);
  });

  test('standalone Lore template is an exact reusable book section', () {
    final lore = _object('lore_template.json');
    final imported = BookLore.fromJson(lore);
    expect(imported.toJson(), lore);
    expect(_object('livre_template.json')['lore'], lore);
  });

  test('book template rejects unknown top-level tags and broken Lore refs', () {
    final invalidTag = _object('livre_template.json');
    invalidTag['tags'] = ['Mystère'];
    expect(() => BookDefinition.importJson(jsonEncode(invalidTag)),
        throwsFormatException);

    final invalidRef = _object('livre_template.json');
    final lore = invalidRef['lore'] as Map<String, dynamic>;
    final chars = lore['characters'] as List;
    (chars.first as Map<String, dynamic>)['homePlaceId'] = 'inconnu';
    expect(() => BookDefinition.importJson(jsonEncode(invalidRef)),
        throwsFormatException);
  });

  test('narrator NDJSON template uses only valid stream events', () {
    final source = _read('narration_stream_template.ndjson');
    final decoder = ChatLineDecoder();
    final parsed = <ChatOutputEvent>[];
    for (final fragment in source.split('')) {
      parsed.addAll(decoder.add(fragment));
    }
    parsed.addAll(decoder.finish());
    expect(parsed, hasLength(4));
    expect(parsed.whereType<ChatLine>(), hasLength(3));
    expect(parsed.whereType<ChatSceneChangeOutput>(), hasLength(1));
    expect(parsed.whereType<ChatLine>().every(
        (line) => line.speaker != ChatSpeaker.player), isTrue);
  });

  test('conversation export has a decodable committed timeline', () {
    final document = _object('conversation_template.json');
    expect(document['format'], 'domolia-conversation-v1');
    final events = document['events'] as List;
    expect(document['exportedEvents'], events.length);
    expect(document['totalEventsInConversation'], events.length);
    expect(document['selection'], {'scope': 'complete'});
    final timeline = BookSession.decodeTimeline(jsonEncode(events));
    expect(timeline, hasLength(3));
    expect(timeline.whereType<ChatEntry>().last.status, 'calme');
  });

  test('memory operation template passes the real provenance validator', () {
    final content = _read('live_memory_operations_template.json');
    final player = _object('conversation_template.json')['events'] as List;
    final message = (player[1] as Map<String, dynamic>)['text'] as String;
    final ops = LiveMemoryOperation.parse(
      content,
      playerEventId: 1,
      playerText: message,
      validatedRaw: 'Tomas répond : Je vous attends.',
    );
    expect(ops, hasLength(1));
    expect(ops.single.action, 'upsert');
    expect(ops.single.fact.category, 'commitment');
    expect(ops.single.fact.sourceTurnId, 1);
    expect(message, contains(ops.single.fact.sourceQuote));
  });

  test('diagnostic templates contain coherent redacted exchange data', () {
    final exchange = _object('echange_ia_template.json');
    final trace = _object('diagnostic_ia_template.json');
    expect(exchange['format'], 'domolia-ai-exchange-v1');
    expect(exchange['credentialsRedacted'], isTrue);
    final request = exchange['request'] as Map<String, dynamic>;
    expect((request['headers'] as Map)['Authorization'], 'Bearer [REDACTED]');
    expect(jsonDecode(request['rawBody'] as String), request['body']);
    final response = exchange['response'] as Map<String, dynamic>;
    expect(response['capturedBytes'],
        utf8.encode(response['rawBody'] as String).length);
    expect(trace['format'], 'domolia-ai-pipeline-trace-v1');
    expect(trace['capturedExchangeCount'], 1);
    final turn = (trace['turns'] as List).single as Map<String, dynamic>;
    expect(turn['phases'], [exchange]);
    expect(turn['playerEventId'], 1);
    expect((turn['raw'] as Map)['status'], 'jsonified'); // historical label
    final usage = turn['usage'] as Map<String, dynamic>;
    expect(usage['jsonifierRequests'], 0);
    expect(usage['requests'], (turn['phases'] as List).length);
    expect(usage['totalTokensKnown'],
        (usage['promptTokensKnown'] as int) +
        (usage['completionTokensKnown'] as int));
  });

  test('application log template contains valid JSONL entries', () {
    final lines = _read('app_logs_template.jsonl').trimRight().split('\n');
    expect(lines, hasLength(2));
    for (final line in lines) {
      final entry = AppLogEntry.fromJson(
          jsonDecode(line) as Map<String, dynamic>);
      expect(entry.level, AppLogLevel.info);
      expect(entry.component, 'chat');
      expect(entry.message, isNotEmpty);
    }
  });
}
