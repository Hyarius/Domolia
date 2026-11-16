import 'chat/raw_generation.dart';
import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'package:cupertino_ui/cupertino_ui.dart' as cupertino_ui;
import 'package:flutter_localizations/flutter_localizations.dart' as flutter_l10n;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'theme/domolia_theme.dart';
import 'chat/chat_controller.dart';
import 'chat/group_chat_page.dart';
import 'chat/conversation_settings_page.dart';
import 'chat/narrator_settings.dart';
import 'books/book_definition.dart';
import 'books/book_session.dart';
import 'books/book_library_controller.dart';
import 'books/book_library_page.dart';
import 'books/book_editor_page.dart';
import 'books/book_store.dart';
import 'memory/live_memory_coordinator.dart';
import 'memory/live_memory_page.dart';
import 'ai/ai_controller.dart';
import 'ai/ai_task_routing.dart';
import 'ai/ministral_model_manager.dart';
import 'ai/ministral_local_provider.dart';
import 'ai/ministral_settings_page.dart';
import 'ai/ai_diagnostics.dart';
import 'ai/ai_diagnostic_settings.dart';
import 'ai/ai_provider.dart';
import 'ai/openuncensored_api.dart';
import 'ai/openuncensored_controller.dart';
import 'ai/openuncensored_vault.dart';
import 'ai/openuncensored_credits_page.dart';
import 'ai/ai_storage.dart';
import 'ai/chatgpt_auth.dart';
import 'ai/chatgpt_responses.dart';
import 'updates/update_service.dart';
import 'updates/update_io.dart';
import 'updates/update_widgets.dart';
import 'logging/app_logger.dart';
import 'logging/app_logs_page.dart';

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await AppLogger.initialize();
    final flutterHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      AppLogger.error('Exception Flutter', component: 'flutter',
          error: details.exception, stackTrace: details.stack);
      flutterHandler?.call(details);
    };
    final platformHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stackTrace) {
      AppLogger.error('Exception non interceptée', component: 'platform',
          error: error, stackTrace: stackTrace);
      return platformHandler?.call(error, stackTrace) ?? false;
    };
    AppLogger.info('Démarrage de Domolia', component: 'app');
    runApp(const DomoliaApp());
  }, (error, stackTrace) {
    AppLogger.error('Exception asynchrone non interceptée', component: 'zone',
        error: error, stackTrace: stackTrace);
  });
}

class DomoliaApp extends StatelessWidget {
  const DomoliaApp({
    super.key,
    this.updateController,
    this.aiController,
    this.creditsController,
    this.chatController,
    this.narratorSettingsController,
    this.bookLibraryController,
  });

  final UpdateController? updateController;
  final AiConnectionController? aiController;
  final OuCreditsController? creditsController;
  final NarrativeChatController? chatController;
  final NarratorSettingsController? narratorSettingsController;
  final BookLibraryController? bookLibraryController;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Domolia',
      debugShowCheckedModeBanner: false,
      theme: DomoliaTheme.dark,
      locale: const Locale('fr'),
      supportedLocales: const [Locale('fr')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        flutter_l10n.GlobalWidgetsLocalizations.delegate,
        cupertino_ui.GlobalCupertinoLocalizations.delegate,
      ],
      home: HomePage(
        updates: updateController,
        ai: aiController,
        credits: creditsController,
        chat: chatController,
        narratorSettings: narratorSettingsController,
        books: bookLibraryController,
      ),
    );
  }
}

enum _Page { home, books, book, chat, about, settings, updates, ai, localAi, diagnostics, logs, conversationSettings, memory }

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    this.updates,
    this.ai,
    this.credits,
    this.chat,
    this.narratorSettings,
    this.books,
  });
  final UpdateController? updates;
  final AiConnectionController? ai;
  final OuCreditsController? credits;
  final NarrativeChatController? chat;
  final NarratorSettingsController? narratorSettings;
  final BookLibraryController? books;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  _Page _page = _Page.home;
  final List<_Page> _history = [];
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  GlobalKey<BookEditorPageState> _bookEditorKey = GlobalKey<BookEditorPageState>();
  bool _leavingBook = false;
  late final UpdateController _updates;
  late final bool _ownsUpdates;
  final AiExchangeRecorder _aiDiagnostics = AiExchangeRecorder();
  final AiTaskRouting _taskRouting = AiTaskRouting();
  final MinistralModelManager _ministralModels = MinistralModelManager();
  late final MinistralLocalProvider _ministralProvider =
      MinistralLocalProvider(_ministralModels);
  late final AiConnectionController _ai;
  late final OuCreditsController _credits;
  late final bool _ownsCredits;
  late final bool _ownsAi;
  late NarrativeChatController _chat;
  LiveMemoryCoordinator? _liveMemory;
  late final bool _ownsChat;
  late final NarratorSettingsController _narratorSettings;
  late final bool _ownsNarratorSettings;
  late final BookLibraryController _books;
  late final bool _ownsBooks;
  String? _selectedBookId;
  String? _activeBookTitle;
  String? _activeSessionTitle;
  String? _activeSessionId;
  Future<void> Function()? _awaitSessionWrites;
  List<BookSession> _recentSessions = const [];
  bool _recentLoading = true;
  String? _recentError;

  @override
  void initState() {
    super.initState();
    _ownsUpdates = widget.updates == null;
    _updates = widget.updates ?? createProductionUpdateController();
    _ownsAi = widget.ai == null;
    _ai = widget.ai ?? AiConnectionController(
      store: SecureAiProfileStore(),
      provider: OpenAiCompatibleChatProvider(diagnostics: _aiDiagnostics),
      chatGpt: ChatGptAuthService(store: SecureChatGptSessionStore()),
      chatGptProvider: ChatGptResponsesProvider(diagnostics: _aiDiagnostics),
    );
    unawaited(_ministralModels.initialize());
    _ownsCredits = widget.credits == null;
    _credits = widget.credits ?? OuCreditsController(
      api: OpenUncensoredApi(), vault: SecureOuVaultStore(),
      ai: _ai, routing: _taskRouting,
    );
    _ownsNarratorSettings = widget.narratorSettings == null;
    _narratorSettings = widget.narratorSettings ?? NarratorSettingsController(
      store: LocalNarratorSettingsStore(),
    );
    _ownsBooks = widget.books == null;
    _books = widget.books ?? BookLibraryController(
      store: SqliteBookStore(),
      legacyNarrator: _narratorSettings.store,
    );
    _ownsChat = widget.chat == null;
    _chat = widget.chat ?? NarrativeChatController(
      provider: _ai.provider,
      configuration: () => null,
      diagnostics: _aiDiagnostics,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_updates.initialize());
        unawaited(_credits.initialize());
        unawaited(_refreshRecent());
      }
    });
  }

  @override
  void dispose() {
    if (_ownsUpdates) _updates.dispose();
    if (_ownsChat) _chat.dispose();
    _liveMemory?.dispose();
    if (_ownsNarratorSettings) _narratorSettings.dispose();
    if (_ownsBooks) {
      if (_books.store is SqliteBookStore) {
        unawaited((_books.store as SqliteBookStore).close());
      }
      _books.dispose();
    }
    if (_ownsCredits) _credits.dispose();
    if (_ownsAi) _ai.dispose();
    unawaited(_ministralProvider.dispose());
    _ministralModels.dispose();
    _taskRouting.dispose();
    super.dispose();
  }

  // La liste des releases reste accessible avant la première publication
  // dev-latest (par exemple pour les APK de préversion des branches).
  static final Uri _allReleasesUrl = Uri.parse(
    'https://github.com/Hyarius/Domolia/releases',
  );

  Future<void> _openUrl(Uri url) async {
    final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d’ouvrir les versions sur GitHub.')),
      );
    }
  }

  void _checkForUpdates() {
    // Manual checks always have a visible result; startup auto-checks do not.
    unawaited(_updates.checkNow());
    showDialog<void>(
      context: context,
      builder: (_) => UpdateCheckDialog(controller: _updates),
    );
  }

  Future<void> _refreshRecent() async {
    if (mounted) {
      setState(() {
        _recentLoading = true;
        _recentError = null;
      });
    }
    try {
      final sessions = await _books.recentSessions();
      if (!mounted) {
        return;
      }
      setState(() {
        _recentError = _books.error;
        _recentSessions = _books.error == null ? sessions : const [];
        _recentLoading = false;
      });
    } catch (failure, stackTrace) {
      AppLogger.error('Chargement des Parties récentes échoué',
          component: 'books', error: failure, stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _recentError = 'Impossible de charger les Parties récentes.';
          _recentLoading = false;
        });
      }
    }
  }

  Future<void> _retryRecent() async {
    await _books.retry();
    if (mounted) {
      await _refreshRecent();
    }
  }

  void _openConversationSettings() {
    if (_activeSessionId == null || _selectedBookId == null) return;
    unawaited(_navigateTo(_Page.conversationSettings));
  }

  void _openBooks() {
    unawaited(_books.initialize());
    unawaited(_navigateTo(_Page.books));
  }

  void _openBook(BookDefinition book) {
    unawaited(_ai.initialize());
    setState(() {
      _history.add(_page);
      _selectedBookId = book.id;
      _bookEditorKey = GlobalKey<BookEditorPageState>();
      _page = _Page.book;
    });
  }

  Future<void> _createBookFromHome() async {
    try {
      await _books.initialize();
      final book = await _books.create();
      if (mounted) _openBook(book);
    } catch (error, stackTrace) {
      AppLogger.error('Création du Livre échouée', component: 'books',
          error: error, stackTrace: stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Impossible de créer ce Livre. Réessayez.'),
        ));
      }
    }
  }

  // The shell owns screen history. Dialogs and drawers still use Navigator.
  Future<bool> _canLeaveCurrentPage() async {
    if (_page != _Page.book) return true;
    if (_leavingBook) return false;
    _leavingBook = true;
    try {
      return await (_bookEditorKey.currentState?.prepareToLeave() ??
          Future<bool>.value(true));
    } finally {
      _leavingBook = false;
    }
  }

  Future<void> _navigateTo(_Page next) async {
    if (_page == next || !await _canLeaveCurrentPage() || !mounted) return;
    if (next == _Page.books) unawaited(_books.initialize());
    if (next == _Page.home) unawaited(_refreshRecent());
    setState(() {
      if (next == _Page.home) {
        _history.clear();
      } else {
        _history.add(_page);
      }
      _page = next;
    });
  }

  Future<void> _goBack() async {
    if (_history.isEmpty) return;
    // Android usually hides the IME before forwarding Back to Flutter.
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    if (!await _canLeaveCurrentPage() || !mounted || _history.isEmpty) return;
    setState(() => _page = _history.removeLast());
    if (_page == _Page.home) unawaited(_refreshRecent());
  }

  Future<void> _openBookSession(
      BookDefinition book, BookSession session) async {
    try {
      await _ai.initialize();
      await _taskRouting.initialize();
      await _ministralModels.initialize();
      if (!mounted) return;
      if (_ownsChat) {
        Future<NarrativeAiEndpoint> endpointForId(
            String id, AiNarrativeTask task) async {
          final binding = await _ai.connectionForProfile(id);
          final current = await _books.session(session.id);
          final settings = _taskRouting.generationFor(task)
              .merged(current?.generationOverrides[task]);
          settings.validate();
          final reasoning = binding.provider is ChatGptResponsesProvider
              ? settings.effectiveEffort(task, binding.configuration.model)
              : null;
          return NarrativeAiEndpoint(
            provider: binding.provider,
            configuration: binding.configuration.withReasoning(reasoning),
            maxOutputTokens: settings.maxOutputTokens,
            toolCallingEnabled: task == AiNarrativeTask.narrator &&
                binding.provider is AiToolCallingChatProvider &&
                (current?.toolCallingEnabled ?? true) &&
                _ai.profiles.any((p) => p.id == id &&
                    p.toolCallingCompatibility ==
                        AiToolCallingCompatibility.supported),
          );
        }

        Future<NarrativeAiEndpoint> localEndpoint(AiNarrativeTask task) async {
          await _ministralModels.initialize();
          if (!_ministralModels.enabled || !_ministralModels.ready) {
            throw const AiProviderException(
                'Ministral local indisponible. Vérifiez son installation.');
          }
          return NarrativeAiEndpoint(
            provider: _ministralProvider,
            configuration: MinistralLocalProvider.configuration,
            maxOutputTokens: switch (task) {
              AiNarrativeTask.narrator => 600,
              AiNarrativeTask.jsonifier => 1200,
              AiNarrativeTask.memory => 700,
              AiNarrativeTask.optimizer => 600,
            },
          );
        }

        Future<String> narratorProfileId() async {
          final current = await _books.session(session.id);
          final chosen = current?.aiProfileId ??
              _taskRouting.profileFor(AiNarrativeTask.narrator) ??
              await _books.profileFor(book.id);
          if (chosen == null || chosen.isEmpty) {
            throw const AiProviderException(
              'Choisissez une configuration IA pour le narrateur.',
            );
          }
          return chosen;
        }

        _chat.dispose();
        _liveMemory?.dispose();
        final storage = _books.store;
        _liveMemory = storage is LiveMemoryStore &&
                storage is NarrativeSnapshotStore
            ? LiveMemoryCoordinator(
                sessionId: session.id,
                store: storage as LiveMemoryStore,
                isEnabled: () async =>
                    (await _books.session(session.id))?.memoryEnabled == true,
                resolveConnection: () async {
                  final current = await _books.session(session.id);
                  if (current == null || !current.memoryEnabled) return null;
                  final chosen = current.memoryProfileId ??
                      _taskRouting.profileFor(AiNarrativeTask.memory);
                  if (chosen == '#disabled') return null;
                  if (_ministralModels.enabled) {
                    final endpoint = await localEndpoint(AiNarrativeTask.memory);
                    return LiveMemoryAiEndpoint(endpoint.provider,
                        endpoint.configuration,
                        maxTokens: endpoint.maxOutputTokens ?? 700);
                  }
                  final id = chosen == null || chosen == '#narrator'
                      ? await narratorProfileId() : chosen;
                  final endpoint = await endpointForId(
                      id, AiNarrativeTask.memory);
                  return LiveMemoryAiEndpoint(endpoint.provider,
                      endpoint.configuration,
                      maxTokens: endpoint.maxOutputTokens ?? 1024);
                },
              )
            : null;
        if (_liveMemory != null) await _liveMemory!.refresh();
        Future<void> writes = Future<void>.value();
        _awaitSessionWrites = () => writes;
        _chat = NarrativeChatController(
          provider: _ai.provider,
          configuration: () => null,
          narrator: book.narrator,
          loreProvider: () => _books.byId(book.id)?.lore ?? book.lore,
          diagnostics: _aiDiagnostics,
          memory: _liveMemory,
          initialOptimizedLore: session.optimizedLore,
          initialOptimizedLoreHash: session.optimizedLoreHash,
          loreContextBudget: _ministralModels.enabled ? 3000 : 8000,
          narratorRecentBudget: _ministralModels.enabled ? 4200 : 16000,
          memoryContextBudget: _ministralModels.enabled ? 1100 : 3600,
          resolveConnection: () async => _ministralModels.enabled
              ? localEndpoint(AiNarrativeTask.narrator)
              : endpointForId(
                  await narratorProfileId(), AiNarrativeTask.narrator),
          resolveFormatterConnection: () async {
            if (_ministralModels.enabled) {
              return localEndpoint(AiNarrativeTask.jsonifier);
            }
            final current = await _books.session(session.id);
            final chosen = current?.formatterProfileId ??
                _taskRouting.profileFor(AiNarrativeTask.jsonifier);
            if (chosen == null || chosen == '#narrator') {
              return endpointForId(
                  await narratorProfileId(), AiNarrativeTask.jsonifier);
            }
            return endpointForId(chosen, AiNarrativeTask.jsonifier);
          },
          resolveOptimizerConnection: () async {
            if (_ministralModels.enabled) return null;
            final current = await _books.session(session.id);
            final chosen = current?.optimizerProfileId ??
                _taskRouting.profileFor(AiNarrativeTask.optimizer);
            if (chosen == null || chosen == '#disabled') return null;
            return endpointForId(chosen, AiNarrativeTask.optimizer);
          },
          onOptimizedLore: (hash, compact) {
            final pending = writes.then((_) =>
                _books.saveOptimizedLore(session.id, hash, compact));
            writes = pending.then((_) {}, onError: (Object error) {
              AppLogger.warning('Lore compact non sauvegardé', component: 'lore');
            });
            return pending;
          },
          onPersistState: (events, List<RawGeneration> generations) {
            final pending = writes.then((_) => _books.saveSessionState(
              session.copyWith(timeline: events), generations,
            ));
            // Keep the next autosave queue usable after a failed transaction,
            // but propagate the actual failure to the active generation.
            writes = pending.then((_) {}, onError: (
                Object failure, StackTrace trace) {
              AppLogger.error('Snapshot narratif non enregistré',
                  component: 'books', error: failure, stackTrace: trace);
            });
            return pending;
          },
          onTimelineChanged: (events) {
            // Serialize writes, so a slower prior write cannot override
            // the latest conversation snapshot.
            writes = writes.then((_) => _books.saveSession(
              session.copyWith(timeline: events),
            )).catchError((Object failure, StackTrace stackTrace) {
              AppLogger.error('Sauvegarde de Partie échouée',
                component: 'books', error: failure, stackTrace: stackTrace);
            });
          },
          onExchangeCaptured: (exchange) {
            // A completed RAW→JSON turn has spent prepaid credits. Refresh
            // once, on the final stage, without delaying narrative storage.
            if (exchange.stage == 'jsonifier') {
              final key = _credits.active;
              if (key != null) {
                unawaited(_credits.refresh(key.id));
              }
            }
            // Persist the already-redacted HTTP request and raw response.
            writes = writes.then((_) async {
              final retention =
                  await const AiDiagnosticsRetentionPreferences().limit();
              if (retention == 0) return;
              await _books.saveDiagnostic(
                StoredAiDiagnostic(
                  id: 'exchange-${exchange.createdAtUtc.microsecondsSinceEpoch}',
                  sessionId: session.id,
                  createdAtUtc: exchange.createdAtUtc,
                  content: exchange.exportJson(),
                ),
                retention,
              );
            }).catchError((Object failure, StackTrace stackTrace) {
              AppLogger.error('Persistance du diagnostic IA échouée',
                component: 'diagnostics', error: failure, stackTrace: stackTrace);
            });
          },
        );
      }
      final rawGenerations = await _books.rawGenerations(session.id);
      if (!mounted) return;
      _chat.restoreTimeline(session.timeline, rawGenerations: rawGenerations);
      _chat.beginConversation();
      setState(() {
        _selectedBookId = book.id;
        _activeBookTitle = book.title;
        _activeSessionTitle = session.title;
        _activeSessionId = session.id;
        _history.add(_page);
        _page = _Page.chat;
      });
    } catch (failure, stackTrace) {
      AppLogger.error('Ouverture de Partie échouée', component: 'books',
          error: failure, stackTrace: stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d’ouvrir cette partie.')),
      );
    }
  }

  void _openAiSettings() {
    unawaited(_credits.initialize());
    unawaited(_navigateTo(_Page.ai));
  }

  void _showPage(_Page page) {
    Navigator.pop(context); // Dismiss the drawer route.
    unawaited(_navigateTo(page));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _history.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_goBack());
      },
      child: AnimatedBuilder(
      animation: _updates,
      builder: (context, _) => Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        leading: _history.isNotEmpty
            ? IconButton(
                key: const ValueKey('appBack'),
                tooltip: 'Retour',
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => unawaited(_goBack()),
              )
            : null,
        title: const Text(
          'DOMOLIA',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            letterSpacing: 3,
            color: DomoliaColors.goldLight,
          ),
        ),
        actions: [
          if (_page == _Page.chat)
            IconButton(
              key: const ValueKey('chatSettingsAppBar'),
              tooltip: 'Paramètres de la conversation',
              onPressed: _openConversationSettings,
              icon: const Icon(Icons.tune_rounded),
            ),
          if (_history.isNotEmpty)
            IconButton(
              key: const ValueKey('appMenu'),
              tooltip: 'Menu',
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              icon: const Icon(Icons.menu),
            ),
        ],
      ),
      drawer: _buildDrawer(),
      body: Column(children: [
        if (_updates.phase == UpdatePhase.downloading)
          UpdateProgressStrip(controller: _updates),
        Expanded(child: _page == _Page.home ? _buildHome()
          : _page == _Page.books ? BookLibraryPage(
              library: _books, onOpen: _openBook,
            )
          : _page == _Page.book && _selectedBookId != null &&
                  _books.byId(_selectedBookId!) != null
              ? BookEditorPage(
                  key: _bookEditorKey,
                  book: _books.byId(_selectedBookId!)!,
                  library: _books,
                  ai: _ai,
                  onPlay: _openBookSession,
                )
          : _page == _Page.chat ? GroupChatPage(
              controller: _chat,
              onOpenSettings: _openConversationSettings,
              bookTitle: _activeBookTitle,
              sessionTitle: _activeSessionTitle,
              onLoadDiagnostics: () async {
                final id = _activeSessionId;
                if (id == null) return <StoredAiDiagnostic>[];
                await _awaitSessionWrites?.call();
                return _books.diagnostics(id);
              },
            )
          : _page == _Page.memory && _liveMemory != null
              ? LiveMemoryPage(
                  memory: _liveMemory!,
                  onBack: () => unawaited(_goBack()),
                )
          : _page == _Page.conversationSettings &&
                  _activeSessionId != null && _selectedBookId != null
              ? ConversationSettingsPage(
                  key: ValueKey(_activeSessionId),
                  library: _books,
                  ai: _ai,
                  chat: _chat,
                  taskRouting: _taskRouting,
                  localNarratorEnabled: _ministralModels.enabled,
                  onOpenMemory: _liveMemory == null ? null :
                      () => unawaited(_navigateTo(_Page.memory)),
                  bookId: _selectedBookId!,
                  sessionId: _activeSessionId!,
                  bookTitle: _activeBookTitle,
                  sessionTitle: _activeSessionTitle,
                  onLoadAiDiagnostics: () async {
                    final id = _activeSessionId;
                    if (id == null) return <StoredAiDiagnostic>[];
                    await _awaitSessionWrites?.call();
                    return _books.diagnostics(id);
                  },
                  onPurgeAiDiagnostics: () async {
                    final id = _activeSessionId;
                    if (id == null) return;
                    await _awaitSessionWrites?.call();
                    await _books.clearDiagnostics(id);
                  },
                  onBack: () => unawaited(_goBack()),
                  showBackButton: false,
                )
          : _page == _Page.about ? _buildAbout()
          : _page == _Page.settings ? _buildSettings()
          : _page == _Page.updates ? UpdateSettingsPanel(
              controller: _updates,
              onViewAllVersions: () => _openUrl(_allReleasesUrl),
              onCheckManually: _checkForUpdates,
            )
          : _page == _Page.ai ? OpenUncensoredCreditsPage(
              controller: _credits,
              onBack: () => unawaited(_goBack()),
              onOpenLocalAi: () => unawaited(_navigateTo(_Page.localAi)),
              showBackButton: false,
            )
          : _page == _Page.localAi ? MinistralSettingsPage(
              models: _ministralModels,
              provider: _ministralProvider,
              onBack: () => unawaited(_goBack()),
              showBackButton: false,
              canChangeModel: () => !_chat.busy &&
                  !(_liveMemory?.processing ?? false),
            )
          : _page == _Page.diagnostics ? AiDiagnosticsSettingsPage(
              onBack: () => unawaited(_goBack()),
              showBackButton: false,
              onPrune: _books.pruneDiagnostics,
            )
          : _page == _Page.logs ? AppLogsPage()
          : _buildSettings()),
      ]),
    ),
    ));
  }

  Widget _buildDrawer() {
    return Drawer(
      child: SafeArea(
        child: ListView(
          children: [
            Container(
              width: double.infinity,
              color: DomoliaColors.background,
              padding: const EdgeInsets.fromLTRB(20, 28, 16, 28),
              child: Row(
                children: [
                  Image.asset(
                    'assets/images/domolia_emblem.png',
                    width: 68,
                    height: 68,
                    semanticLabel: 'Emblème Domolia',
                  ),
                  const SizedBox(width: 16),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'DOMOLIA',
                          style: TextStyle(
                            color: DomoliaColors.goldLight,
                            fontSize: 22,
                            letterSpacing: 2,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          'L’aventure vous appartient',
                          style: TextStyle(color: DomoliaColors.muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.home_outlined),
              title: const Text('Accueil'),
              selected: _page == _Page.home,
              selectedColor: DomoliaColors.goldLight,
              selectedTileColor: DomoliaColors.raisedSurface,
              onTap: () => _showPage(_Page.home),
            ),
            ListTile(
              leading: const Icon(Icons.library_books_outlined),
              title: const Text('Livres'),
              selected: _page == _Page.books || _page == _Page.book ||
                  _page == _Page.chat || _page == _Page.conversationSettings ||
                  _page == _Page.memory,
              selectedColor: DomoliaColors.goldLight,
              selectedTileColor: DomoliaColors.raisedSurface,
              onTap: () => _showPage(_Page.books),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text('À propos'),
              selected: _page == _Page.about,
              selectedColor: DomoliaColors.goldLight,
              selectedTileColor: DomoliaColors.raisedSurface,
              onTap: () => _showPage(_Page.about),
            ),
            const Divider(indent: 16, endIndent: 16),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Paramètres'),
              selected: _page == _Page.settings ||
                  _page == _Page.updates || _page == _Page.ai ||
                   _page == _Page.localAi ||
                  _page == _Page.diagnostics || _page == _Page.logs,
              selectedColor: DomoliaColors.goldLight,
              selectedTileColor: DomoliaColors.raisedSurface,
              onTap: () => _showPage(_Page.settings),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettings() => SafeArea(
    child: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Paramètres',
          style: TextStyle(
            color: DomoliaColors.goldLight,
            fontSize: 25,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: DomoliaSpacing.section),
        ListTile(
          leading: const Icon(Icons.smart_toy_outlined, color: DomoliaColors.gold),
          title: const Text('Crédits IA'),
          subtitle: const Text('OpenUncensored, clés et modèles'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _openAiSettings,
        ),
        const Divider(),
        ListTile(
          key: const ValueKey('settingsLocalAi'),
          leading: const Icon(Icons.smartphone_outlined,
              color: DomoliaColors.gold),
          title: const Text('IA locale — Mistral'),
          subtitle: const Text('Installer et essayer Ministral hors connexion'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => unawaited(_navigateTo(_Page.localAi)),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.system_update_alt_rounded, color: DomoliaColors.gold),
          title: const Text('Mises à jour'),
          subtitle: const Text('Version installée, canal et préversions'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => unawaited(_navigateTo(_Page.updates)),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.bug_report_outlined,
              color: DomoliaColors.gold),
          title: const Text('Diagnostics IA'),
          subtitle: const Text('Conservation locale des requêtes et réponses'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => unawaited(_navigateTo(_Page.diagnostics)),
        ),
        const Divider(),
        ListTile(
          key: const ValueKey('settingsLogs'),
          leading: const Icon(Icons.article_outlined, color: DomoliaColors.gold),
          title: const Text('Logs'),
          subtitle: const Text('Consulter, copier, exporter et effacer le journal'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => unawaited(_navigateTo(_Page.logs)),
        ),
      ],
    ),
  );

  Widget _buildHome() {
    return SafeArea(
      child: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 44),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Image.asset('assets/images/domolia_emblem.png',
                      width: 64, height: 64, semanticLabel: 'Emblème Domolia'),
                    const SizedBox(width: 16),
                    const Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Bienvenue dans Domolia', style: TextStyle(
                          color: DomoliaColors.goldLight,
                          fontSize: 23, fontWeight: FontWeight.bold)),
                        SizedBox(height: 4),
                        Text('Votre prochaine aventure commence ici.',
                          style: TextStyle(color: DomoliaColors.cream)),
                      ],
                    )),
                  ]),
                  const SizedBox(height: DomoliaSpacing.section),
                  const Text('Mes Livres', style: TextStyle(
                    color: DomoliaColors.goldLight, fontSize: 21,
                    fontWeight: FontWeight.bold)),
                  const SizedBox(height: DomoliaSpacing.compact),
                  const Text('Explorez vos univers ou créez une nouvelle histoire.',
                    style: TextStyle(color: DomoliaColors.muted)),
                  const SizedBox(height: DomoliaSpacing.field),
                  FilledButton.icon(
                    key: const ValueKey('homeBooks'),
                    onPressed: _openBooks,
                    icon: const Icon(Icons.library_books_outlined),
                    label: const Text('Ouvrir ma bibliothèque'),
                  ),
                  const SizedBox(height: DomoliaSpacing.compact),
                  OutlinedButton.icon(
                    key: const ValueKey('homeCreateBook'),
                    onPressed: _recentLoading || _recentError != null
                        ? null : _createBookFromHome,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Créer un Livre'),
                  ),
                  const SizedBox(height: DomoliaSpacing.section),
                  const _GoldSeparator(),
                  const SizedBox(height: DomoliaSpacing.section),
                  const Text('Mes Parties', style: TextStyle(
                    color: DomoliaColors.goldLight, fontSize: 21,
                    fontWeight: FontWeight.bold)),
                  const SizedBox(height: DomoliaSpacing.compact),
                  if (_recentLoading)
                    const _DomoliaPanel(
                      child: Row(children: [
                        Icon(Icons.hourglass_empty_rounded,
                          color: DomoliaColors.gold),
                        SizedBox(width: DomoliaSpacing.field),
                        Expanded(child: Text('Chargement de vos Parties...',
                          style: TextStyle(color: DomoliaColors.cream))),
                      ]),
                    )
                  else if (_recentError != null)
                    _DomoliaPanel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Bibliothèque indisponible',
                            style: TextStyle(color: DomoliaColors.goldLight,
                                fontWeight: FontWeight.bold)),
                          const SizedBox(height: DomoliaSpacing.compact),
                          Text(_recentError!),
                          const SizedBox(height: DomoliaSpacing.field),
                          OutlinedButton.icon(
                            key: const ValueKey('homeRetryLibrary'),
                            onPressed: () => unawaited(_retryRecent()),
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Réessayer'),
                          ),
                        ],
                      ),
                    )
                  else if (_recentSessions.isEmpty)
                    const _DomoliaPanel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.auto_stories_outlined,
                            color: DomoliaColors.goldDark, size: 30),
                          SizedBox(height: DomoliaSpacing.compact),
                          Text('Aucune aventure commencée',
                            style: TextStyle(color: DomoliaColors.goldLight,
                              fontWeight: FontWeight.bold)),
                          SizedBox(height: 6),
                          Text('Ouvrez un Livre pour commencer une Partie. '
                            'Vous pourrez ensuite la retrouver ici.',
                            style: TextStyle(color: DomoliaColors.cream)),
                        ],
                      ),
                    ),
                  if (!_recentLoading && _recentError == null)
                    for (final session in _recentSessions)
                      Card(
                      color: DomoliaColors.surface,
                      child: ListTile(
                        key: ValueKey('recentSession-${session.id}'),
                        leading: const Icon(Icons.auto_stories_outlined,
                          color: DomoliaColors.gold),
                        title: Text(session.title, maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          _books.byId(session.bookId)?.title ?? 'Livre indisponible',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          final book = _books.byId(session.bookId);
                          if (book != null) {
                            unawaited(_openBookSession(book, session));
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content:
                                Text('Ce Livre n’est plus disponible.')));
                          }
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAbout() {
    return SafeArea(
      child: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 24),
                  const Icon(
                    Icons.auto_stories_rounded,
                    color: DomoliaColors.gold,
                    size: 54,
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'À propos de Domolia',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: DomoliaColors.goldLight,
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const _DomoliaPanel(
                    child: Text(
                      'Domolia est une application de jeu de rôle narratif '
                      'assisté par IA. Créez des Livres, définissez vos univers '
                      'et vivez des Parties qui évoluent avec vos choix.',
                      style: TextStyle(
                        color: DomoliaColors.cream,
                        height: 1.6,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    onPressed: () => _openUrl(_allReleasesUrl),
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('Voir le projet sur GitHub'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DomoliaPanel extends StatelessWidget {
  const _DomoliaPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: DomoliaColors.surface,
        border: Border.all(color: DomoliaColors.border),
        borderRadius: BorderRadius.circular(18),
      ),
      padding: const EdgeInsets.all(22),
      child: child,
    );
  }
}

class _GoldSeparator extends StatelessWidget {
  const _GoldSeparator();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Expanded(child: Divider(color: DomoliaColors.goldDark)),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 14),
          child: Icon(
            Icons.auto_awesome_rounded,
            color: DomoliaColors.gold,
            size: 18,
          ),
        ),
        Expanded(child: Divider(color: DomoliaColors.goldDark)),
      ],
    );
  }
}
