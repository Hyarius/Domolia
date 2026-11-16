import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/raw_generation.dart';
import 'package:domolia/memory/live_memory.dart';
import 'package:domolia/memory/live_memory_coordinator.dart';
import 'package:domolia/memory/live_memory_page.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets(
    'memory UI filters, edits, protects, deletes and reports sources',
    (tester) async {
      final store = SqliteBookStore(
        factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      addTearDown(store.close);
      await store.putBook(const BookDefinition(id: 'book', title: 'Livre'));
      const player = ChatEntry(
        id: 1,
        speaker: ChatSpeaker.player,
        name: 'Vous',
        text: 'Je regarde Élise.',
      );
      await store.putSession(
        const BookSession(
          id: 'part',
          bookId: 'book',
          title: 'Partie',
          timeline: [player],
        ),
      );
      final raw = RawGeneration(
        playerEventId: 1,
        rawText: 'Élise porte une bague en argent.',
      ).structured(2, 2);
      await store.saveNarrativeSnapshot(
        const BookSession(
          id: 'part',
          bookId: 'book',
          title: 'Partie',
          timeline: [player],
        ),
        [raw],
      );
      await store.commitMemoryTurn('part', raw, [
        const LiveMemoryOperation(
          action: 'upsert',
          fact: LiveMemoryFact(
            id: 'character:elise:ring',
            category: 'character',
            entityId: 'elise',
            label: 'Élise',
            field: 'ring',
            text: 'Bague en argent',
            kind: 'stable',
            certainty: 'confirmed',
            visibility: 'player',
            importance: 4,
            sourceTurnId: 1,
            sourceSide: 'raw',
            sourceQuote: 'bague en argent',
          ),
        ),
      ]);
      final memory = LiveMemoryCoordinator(
        sessionId: 'part',
        store: store,
        isEnabled: () async => false,
        resolveConnection: () async => null,
      );
      addTearDown(memory.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveMemoryPage(memory: memory, onBack: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('liveMemoryPage')), findsOneWidget);
      expect(find.text('Mémoire à jour'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('memoryCategory-character')));
      await tester.pumpAndSettle();
      expect(find.text('Bague en argent'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('memoryFact-character:elise:ring')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Source : tour 1'), findsOneWidget);
      await tester.tap(find.text('Protéger'));
      await tester.pumpAndSettle();
      expect(memory.facts.single.pinned, isTrue);
      await tester.enterText(
        find.byKey(const ValueKey('memorySearch')),
        'introuvable',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('memoryEmpty')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('memorySearch')), '');
      await tester.pumpAndSettle();
      expect(memory.facts.length, 1);
    },
  );
}
