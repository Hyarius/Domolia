import 'dart:async';

import 'package:domolia/ai/ai_controller.dart';
import 'package:domolia/ai/ai_settings_panel.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/ai_task_routing.dart';
import 'package:domolia/ai/openuncensored_api.dart';
import 'package:domolia/ai/openuncensored_controller.dart';
import 'package:domolia/ai/openuncensored_credits_page.dart';
import 'package:domolia/ai/openuncensored_vault.dart';
import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_library_controller.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/main.dart';
import 'package:domolia/updates/update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Books implements BookStore {
  Completer<void>? blockNextBookWrite;
  bool failNextList = false;
  final Map<String, BookDefinition> books = {};
  final Map<String, BookSession> sessionsById = {};
  final Map<String, String?> bindings = {};
  final Map<String, StoredAiDiagnostic> diagnostics = {};

  @override
  Future<List<BookDefinition>> listBooks() async {
    if (failNextList) {
      failNextList = false;
      throw StateError('Simulated SQLite read failure');
    }
    return books.values.toList();
  }
  @override
  Future<BookDefinition?> findBook(String id) async => books[id];
  @override
  Future<void> putBook(BookDefinition book) async {
    book.validate();
    final gate = blockNextBookWrite;
    if (gate != null) {
      blockNextBookWrite = null;
      await gate.future;
    }
    books[book.id] = book;
  }
  @override
  Future<void> deleteBook(String id) async {
    books.remove(id);
    bindings.remove(id);
    sessionsById.removeWhere((key, value) => value.bookId == id);
  }
  @override
  Future<String?> profileIdForBook(String bookId) async => bindings[bookId];
  @override
  Future<void> bindProfile(String bookId, String? profileId) async {
    bindings[bookId] = profileId;
  }
  @override
  Future<List<BookSession>> listSessions(String id) async =>
      sessionsById.values.where((s) => s.bookId == id).toList();
  @override
  Future<BookSession?> findSession(String id) async => sessionsById[id];
  @override
  Future<void> putSession(BookSession session) async {
    sessionsById[session.id] = session;
  }
  @override
  Future<void> updateSession(BookSession session) async {
    if (sessionsById.containsKey(session.id)) sessionsById[session.id] = session;
  }
  @override
  Future<void> deleteSession(String id) async {
    sessionsById.remove(id);
  }
  @override
  Future<void> putDiagnostic(StoredAiDiagnostic item, int limit) async {
    diagnostics[item.id] = item;
  }
  @override
  Future<List<StoredAiDiagnostic>> listDiagnostics(String sessionId) async =>
      diagnostics.values.where((d) => d.sessionId == sessionId).toList();
  @override
  Future<void> clearDiagnostics(String sessionId) async {
    diagnostics.removeWhere((key, value) => value.sessionId == sessionId);
  }
  @override
  Future<void> pruneDiagnostics(int retentionLimit) async {}
}

class _AiStore implements AiProfileStore {
  AiProfilesState? saved;
  @override
  Future<AiProfilesState?> read() async => saved;
  @override
  Future<void> write(AiProfilesState state) async { saved = state; }
}
class _Provider implements AiChatProvider {
  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async => [];
  @override
  Future<String> complete(AiConfiguration configuration, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) async => throw StateError('No network during UX tests');
}
class _Vault implements OuVaultStore {
  OuVaultState value = const OuVaultState();
  @override
  Future<OuVaultState> read() async => value;
  @override
  Future<void> write(OuVaultState next) async { value = next; }
}
class _Release implements ReleaseSource {
  @override
  Future<UpdateCandidate?> latest(String channel) async => null;
}
class _Downloader implements ApkDownloader {
  @override
  Future<String> download(UpdateCandidate candidate, DownloadCancellation token,
      void Function(double?) onProgress) async => throw StateError('No download');
}
class _Android implements AndroidUpdater {
  @override
  Future<InstalledApp> installedApp() async =>
      const InstalledApp('fr.domolia.domolia', '0.1.0', 1);
  @override
  Future<String> install(String path) async => 'permissionRequired';
}
class _Prefs implements UpdatePreferences {
  bool automaticUpdates = false;
  @override
  Future<String> channel() async => 'dev-latest';
  @override
  Future<bool> automatic() async => automaticUpdates;
  @override
  Future<void> setChannel(String value) async {}
  @override
  Future<void> setAutomatic(bool value) async { automaticUpdates = value; }
}

Future<void> _showApp(WidgetTester tester, {
  bool withSession = false,
  _Books? store,
  Future<void> Function()? onResetApp,
}) async {
  SharedPreferences.setMockInitialValues({});
  final storage = store ?? _Books();
  storage.books['novel'] = const BookDefinition(id: 'novel', title: 'La forêt');
  if (withSession) {
    storage.sessionsById['journey'] = const BookSession(
      id: 'journey', bookId: 'novel', title: 'La traversée',
    );
  }
  final library = BookLibraryController(store: storage);
  await library.initialize();
  final provider = _Provider();
  final ai = AiConnectionController(store: _AiStore(), provider: provider);
  await ai.initialize();
  final routing = AiTaskRouting();
  final credits = OuCreditsController(
    ai: ai, routing: routing, vault: _Vault(),
    api: OpenUncensoredApi(client: MockClient(
      (_) async => http.Response('Unexpected request', 500))),
  );
  final chat = NarrativeChatController(
    provider: provider, configuration: () => null,
  );
  final updates = UpdateController(
    releases: _Release(), downloader: _Downloader(),
    android: _Android(), preferences: _Prefs(),
  );
  addTearDown(() {
    updates.dispose();
    chat.dispose();
    credits.dispose();
    routing.dispose();
    ai.dispose();
    library.dispose();
  });
  await tester.pumpWidget(DomoliaApp(
    updateController: updates, aiController: ai,
    creditsController: credits, chatController: chat,
    bookLibraryController: library,
    onResetApp: onResetApp,
  ));
  await tester.pumpAndSettle();
}

Future<void> _drawerItem(WidgetTester tester, String label) async {
  final menu = find.byKey(const ValueKey('appMenu'));
  if (menu.evaluate().isNotEmpty) {
    await tester.tap(menu);
  } else {
    await tester.tap(find.byIcon(Icons.menu));
  }
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(ListTile, label));
  await tester.pumpAndSettle();
}

Future<void> _systemBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('La bibliothèque reste lisible sur téléphone étroit',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await _showApp(tester);
    await tester.tap(find.byKey(const ValueKey('homeBooks')));
    await tester.pumpAndSettle();
    final grid = tester.widget<GridView>(
      find.byKey(const ValueKey('booksGrid')));
    final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 1);
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Supprimer La forêt'), findsOneWidget);
  });

  testWidgets('Accueil distingue une erreur de stockage d’une bibliothèque vide',
      (tester) async {
    final storage = _Books()..failNextList = true;
    await _showApp(tester, store: storage);
    expect(find.text('Bibliothèque indisponible'), findsOneWidget);
    expect(find.text('Aucune aventure commencée'), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('homeRetryLibrary')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('homeRetryLibrary')));
    await tester.pumpAndSettle();
    expect(find.text('Bibliothèque indisponible'), findsNothing);
    expect(find.text('Aucune aventure commencée'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('homeBooks')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('book-novel')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Une sauvegarde lente ne perd pas un réglage plus récent',
      (tester) async {
    final storage = _Books();
    await _showApp(tester, store: storage);
    await tester.tap(find.byKey(const ValueKey('homeBooks')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('book-novel')));
    await tester.pumpAndSettle();

    final firstWrite = Completer<void>();
    storage.blockNextBookWrite = firstWrite;
    await tester.enterText(
      find.byKey(const ValueKey('bookTitle')), 'La forêt revisitée');
    await tester.pump(const Duration(milliseconds: 600));
    expect(storage.blockNextBookWrite, isNull,
        reason: 'The debounced text save must be in progress.');

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('bookNsfw')),
      180,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('bookTab-0')),
        matching: find.byType(Scrollable),
      ).first,
    );
    await tester.tap(find.byKey(const ValueKey('bookNsfw')));
    await tester.pump();
    firstWrite.complete();
    await tester.pumpAndSettle();

    expect(storage.books['novel']!.title, 'La forêt revisitée');
    expect(storage.books['novel']!.nsfw, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Accueil, bibliothèque, Livre et retour Android',
      (tester) async {
    await _showApp(tester);
    await tester.tap(find.byKey(const ValueKey('homeBooks')));
    await tester.pumpAndSettle();
    expect(find.text('Livres'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('book-novel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bookTabs')), findsOneWidget);

    await _systemBack(tester);
    expect(find.byKey(const ValueKey('booksGrid')), findsOneWidget);
    await _systemBack(tester);
    expect(find.text('Mes Parties'), findsOneWidget);
  });

  testWidgets('Accueil, Partie, paramètres, retour conversation',
      (tester) async {
    await _showApp(tester, withSession: true);
    await tester.tap(find.byKey(const ValueKey('recentSession-journey')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('groupChatInput')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chatSettingsAppBar')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Paramètres'), findsWidgets);
    await _systemBack(tester);
    expect(find.byKey(const ValueKey('groupChatInput')), findsOneWidget);
    await _systemBack(tester);
    expect(find.text('Mes Parties'), findsOneWidget);
  });

  testWidgets('Depuis une Partie, le raccourci ouvre le Lore du Livre',
      (tester) async {
    await _showApp(tester, withSession: true);
    await tester.tap(find.byKey(const ValueKey('recentSession-journey')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('groupChatInput')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chatBookLoreAppBar')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bookLoreTab')), findsOneWidget);
    expect(tester.widget<NavigationBar>(
        find.byKey(const ValueKey('bookTabs'))).selectedIndex, 1);
    await _systemBack(tester);
    expect(find.byKey(const ValueKey('groupChatInput')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Retour protège un Livre dont la sauvegarde a échoué',
      (tester) async {
    await _showApp(tester);
    await tester.tap(find.byKey(const ValueKey('homeBooks')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('book-novel')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('bookTitle')), '');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('appBack')));
    await tester.pumpAndSettle();
    expect(find.text('Modifications non enregistrées'), findsOneWidget);
    await tester.tap(find.text('Rester'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bookTabs')), findsOneWidget);
  });

  testWidgets('Retour ferme le clavier avant de quitter les mises à jour',
      (tester) async {
    await _showApp(tester);
    await _drawerItem(tester, 'Paramètres');
    await tester.tap(find.widgetWithText(ListTile, 'Mises à jour'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.resetViewInsets);
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await _systemBack(tester);
    expect(find.byKey(const ValueKey('appBack')), findsOneWidget);
    expect(find.text('Mises à jour'), findsWidgets);
    expect(tester.widget<EditableText>(
      find.byType(EditableText).first).focusNode.hasFocus, isFalse);
    tester.view.resetViewInsets();
    await tester.pump();
    await _systemBack(tester);
    expect(find.widgetWithText(ListTile, 'Crédits IA'), findsOneWidget);
  });

  testWidgets('Réinitialisation demande confirmation et peut être annulée',
      (tester) async {
    var count = 0;
    await _showApp(tester, onResetApp: () async => count++);
    await _drawerItem(tester, 'Paramètres');
    await tester.ensureVisible(
        find.byKey(const ValueKey('settingsFactoryReset')));
    await tester.tap(find.byKey(const ValueKey('settingsFactoryReset')));
    await tester.pumpAndSettle();
    expect(find.text('Réinitialiser Domolia ?'), findsOneWidget);
    expect(find.textContaining('clés API enregistrées'), findsOneWidget);
    expect(count, 0);
    await tester.tap(find.byKey(const ValueKey('resetAppCancel')));
    await tester.pumpAndSettle();
    expect(count, 0);
    await tester.tap(find.byKey(const ValueKey('settingsFactoryReset')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('resetAppConfirm')));
    await tester.pumpAndSettle();
    expect(count, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Paramètres, crédits, mises à jour et dialogue',
      (tester) async {
    await _showApp(tester);
    expect(find.byTooltip('Mise à jour'), findsNothing);
    expect(find.text('Hello World !'), findsNothing);

    await _drawerItem(tester, 'Paramètres');
    expect(find.widgetWithText(ListTile, 'Crédits IA'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Fournisseurs IA'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Mises à jour'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settingsAiProviders')));
    await tester.pumpAndSettle();
    expect(find.byType(AiSettingsPanel), findsOneWidget);
    expect(find.text('Profils IA'), findsOneWidget);
    await _systemBack(tester);
    expect(find.widgetWithText(ListTile, 'Crédits IA'), findsOneWidget);

    await tester.tap(find.widgetWithText(ListTile, 'Mises à jour'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vérifier maintenant'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('updateCheckDialog')), findsOneWidget);
    await _systemBack(tester); // Modal closes before the underlying screen.
    expect(find.byKey(const ValueKey('updateCheckDialog')), findsNothing);
    expect(find.text('Mises à jour'), findsWidgets);

    await _systemBack(tester);
    expect(find.widgetWithText(ListTile, 'Crédits IA'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'Crédits IA'));
    await tester.pumpAndSettle();
    expect(find.byType(OpenUncensoredCreditsPage), findsOneWidget);
    await _systemBack(tester);
    expect(find.widgetWithText(ListTile, 'Mises à jour'), findsOneWidget);
    await _systemBack(tester);
    expect(find.text('Mes Livres'), findsOneWidget);
    await _systemBack(tester); // Root route has no prior in-app page.
    expect(find.text('Mes Livres'), findsOneWidget);
  });
}
