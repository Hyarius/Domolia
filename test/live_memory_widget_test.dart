import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:domolia/chat/raw_generation.dart';
import 'package:domolia/memory/live_memory.dart';
import 'package:domolia/memory/live_memory_coordinator.dart';
import 'package:domolia/memory/live_memory_page.dart';

class _WidgetMemoryStore implements LiveMemoryStore, NarrativeSnapshotStore {
  final overrides = <String, LiveMemoryOverride>{};
  final history = <List<LiveMemoryOperation>>[
    [
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
    ],
  ];

  @override
  Future<List<List<LiveMemoryOperation>>> loadMemoryTurns(String id) async =>
      history;

  @override
  Future<List<LiveMemoryOverride>> loadMemoryOverrides(String id) async =>
      overrides.values.toList();

  @override
  Future<Set<int>> analyzedMemoryTurns(String id) async => {1};

  @override
  Future<List<RawGeneration>> listRawGenerations(String id) async => [
    RawGeneration(
      playerEventId: 1,
      rawText: 'bague en argent',
    ).structured(2, 2),
  ];

  @override
  Future<void> saveMemoryOverride(String id, LiveMemoryOverride value) async {
    overrides[value.id] = value;
  }

  @override
  Future<void> clearGeneratedMemory(String id) async => history.clear();

  @override
  Future<void> saveNarrativeSnapshot(
    BookSession session,
    List<RawGeneration> sources,
  ) async {}

  @override
  Future<void> commitMemoryTurn(
    String id,
    RawGeneration source,
    List<LiveMemoryOperation> changes,
  ) async {}
}

void main() {
  testWidgets('memory UI search, source citation and fact protection', (
    tester,
  ) async {
    final store = _WidgetMemoryStore();
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
    await tester.ensureVisible(
      find.byKey(const ValueKey('memoryCharacter-elise')),
    );
    await tester.tap(find.byKey(const ValueKey('memoryCharacter-elise')));
    await tester.pumpAndSettle();
    expect(find.text('Bague en argent'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('memoryFact-character:elise:ring')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Source : tour 1'), findsOneWidget);
    await tester.ensureVisible(find.text('Protéger'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Protéger'));
    await tester.pumpAndSettle();
    expect(memory.facts.single.pinned, isTrue);
    await tester.ensureVisible(find.byKey(const ValueKey('memorySearch')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('memorySearch')),
      'introuvable',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('memoryEmpty')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('memorySearch')), '');
    await tester.pumpAndSettle();
    expect(memory.facts.length, 1);
  });
}
