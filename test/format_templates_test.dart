import 'dart:convert';
import 'dart:io';

import 'package:domolia/books/book_definition.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/theatrical_script_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('portable book template imports, validates, and round-trips', () {
    final source = File('template/livre_template.json').readAsStringSync();
    final book = BookDefinition.importJson(source);
    expect(book.title, 'Livre de démonstration');
    expect(book.lore.characters, hasLength(1));
    expect(book.lore.scenarios, hasLength(1));
    expect(book.lore.events, hasLength(1));
    expect(BookDefinition.importJson(book.exportJson()).toPortableJson(),
        book.toPortableJson());
  });

  test('conversation and diagnostic examples retain their export contracts', () {
    final conversation = jsonDecode(
        File('template/conversation_template.json').readAsStringSync())
        as Map<String, dynamic>;
    expect(conversation['format'], 'domolia-conversation-v1');
    expect((conversation['events'] as List).length,
        conversation['exportedEvents']);
    expect(conversation['totalEventsInConversation'],
        conversation['exportedEvents']);
    final diagnostic = jsonDecode(
        File('template/diagnostic_ia_template.json').readAsStringSync())
        as Map<String, dynamic>;
    expect(diagnostic['format'], 'domolia-ai-pipeline-trace-v1');
    expect(diagnostic['turns'], isNotEmpty);
  });

  test('theatrical streaming template preserves scene and speaker order', () {
    final decoder = TheatricalScriptDecoder();
    final source = File('template/narrateur_theatral_template.txt')
        .readAsStringSync();
    final events = <ChatOutputEvent>[];
    for (final fragment in source.split('')) {
      events.addAll(decoder.add(fragment));
    }
    events.addAll(decoder.finish());
    expect(events.whereType<ChatLine>(), hasLength(3));
    expect(events.whereType<ChatSceneChangeOutput>(), hasLength(1));
  });

  test('legacy streaming template still decodes all NDJSON lines', () {
    final decoder = TheatricalScriptDecoder();
    final source = File('template/narrateur_streaming_template.ndjson')
        .readAsStringSync();
    final events = <ChatOutputEvent>[];
    for (final fragment in source.split('')) {
      events.addAll(decoder.add(fragment));
    }
    events.addAll(decoder.finish());
    expect(events.whereType<ChatLine>(), hasLength(2));
    expect(events.whereType<ChatSceneChangeOutput>(), hasLength(1));
  });
}
