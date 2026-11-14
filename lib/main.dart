import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart' as cupertino_ui;
import 'package:flutter_localizations/flutter_localizations.dart' as flutter_l10n;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'theme/domolia_theme.dart';
import 'chat/chat_controller.dart';
import 'chat/group_chat_page.dart';
import 'chat/narrator_settings.dart';
import 'books/book_definition.dart';
import 'books/book_session.dart';
import 'books/book_library_controller.dart';
import 'books/book_library_page.dart';
import 'books/book_editor_page.dart';
import 'books/book_store.dart';
import 'ai/ai_controller.dart';
import 'ai/ai_diagnostics.dart';
import 'ai/ai_diagnostic_settings.dart';
import 'ai/ai_provider.dart';
import 'ai/ai_settings_panel.dart';
import 'ai/ai_storage.dart';
import 'ai/chatgpt_auth.dart';
import 'ai/chatgpt_responses.dart';
import 'updates/update_service.dart';
import 'updates/update_io.dart';
import 'updates/update_widgets.dart';

void main() {
  runApp(const DomoliaApp());
}

class DomoliaApp extends StatelessWidget {
  const DomoliaApp({
    super.key,
    this.updateController,
    this.aiController,
    this.chatController,
    this.narratorSettingsController,
    this.bookLibraryController,
  });

  final UpdateController? updateController;
  final AiConnectionController? aiController;
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
        chat: chatController,
        narratorSettings: narratorSettingsController,
        books: bookLibraryController,
      ),
    );
  }
}

enum _Page { home, books, book, chat, about, settings, updates, ai, diagnostics }

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    this.updates,
    this.ai,
    this.chat,
    this.narratorSettings,
    this.books,
  });
  final UpdateController? updates;
  final AiConnectionController? ai;
  final NarrativeChatController? chat;
  final NarratorSettingsController? narratorSettings;
  final BookLibraryController? books;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  _Page _page = _Page.home;
  _Page _aiReturnPage = _Page.settings;
  late final UpdateController _updates;
  late final bool _ownsUpdates;
  final AiExchangeRecorder _aiDiagnostics = AiExchangeRecorder();
  late final AiConnectionController _ai;
  late final bool _ownsAi;
  late NarrativeChatController _chat;
  late final bool _ownsChat;
  late final NarratorSettingsController _narratorSettings;
  late final bool _ownsNarratorSettings;
  late final BookLibraryController _books;
  late final bool _ownsBooks;
  String? _selectedBookId;
  String? _activeBookTitle;
  String? _activeSessionTitle;
  String? _activeSessionId;

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
      if (mounted) unawaited(_updates.initialize());
    });
  }

  @override
  void dispose() {
    if (_ownsUpdates) _updates.dispose();
    if (_ownsChat) _chat.dispose();
    if (_ownsNarratorSettings) _narratorSettings.dispose();
    if (_ownsBooks) {
      if (_books.store is SqliteBookStore) {
        unawaited((_books.store as SqliteBookStore).close());
      }
      _books.dispose();
    }
    if (_ownsAi) _ai.dispose();
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

  void _openBooks() {
    unawaited(_books.initialize());
    setState(() => _page = _Page.books);
  }

  void _openBook(BookDefinition book) {
    unawaited(_ai.initialize());
    setState(() {
      _selectedBookId = book.id;
      _page = _Page.book;
    });
  }

  Future<void> _openBookSession(
      BookDefinition book, BookSession session) async {
    try {
      await _ai.initialize();
      if (!mounted) return;
      if (_ownsChat) {
        _chat.dispose();
        Future<void> writes = Future<void>.value();
        _chat = NarrativeChatController(
          provider: _ai.provider,
          configuration: () => null,
          narrator: book.narrator,
          diagnostics: _aiDiagnostics,
          resolveConnection: () async {
            final id = await _books.profileFor(book.id);
            if (id == null || id.isEmpty) {
              throw const AiProviderException(
                'Choisissez une configuration IA pour ce Livre.',
              );
            }
            final binding = await _ai.connectionForProfile(id);
            return NarrativeAiEndpoint(
              provider: binding.provider,
              configuration: binding.configuration,
            );
          },
          onTimelineChanged: (events) {
            // Serialize writes, so a slower prior write cannot override
            // the latest conversation snapshot.
            writes = writes.then((_) => _books.saveSession(
              session.copyWith(timeline: events),
            )).catchError((Object _) {
              // The UI remains usable if local storage is temporarily unavailable.
            });
          },
          onExchangeCaptured: (exchange) {
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
            }).catchError((Object _) {
              // Diagnostics never prevent the story from continuing.
            });
          },
        );
      }
      _chat.restoreTimeline(session.timeline);
      _chat.beginConversation();
      setState(() {
        _activeBookTitle = book.title;
        _activeSessionTitle = session.title;
        _activeSessionId = session.id;
        _page = _Page.chat;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d’ouvrir cette partie.')),
      );
    }
  }

  void _openAiSettings() {
    unawaited(_ai.initialize());
    setState(() {
      _aiReturnPage = _page == _Page.chat ? _Page.chat : _Page.settings;
      _page = _Page.ai;
    });
  }

  void _showPage(_Page page) {
    Navigator.pop(context); // Ferme le menu latéral.
    if (page == _Page.books) unawaited(_books.initialize());
    setState(() => _page = page);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _updates,
      builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text(
          'DOMOLIA',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            letterSpacing: 3,
            color: DomoliaColors.goldLight,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Mise à jour',
            onPressed: _checkForUpdates,
            icon: const Icon(Icons.system_update_alt_rounded),
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
                  key: ValueKey(_selectedBookId),
                  book: _books.byId(_selectedBookId!)!,
                  library: _books,
                  ai: _ai,
                  onPlay: _openBookSession,
                )
          : _page == _Page.chat ? GroupChatPage(
              controller: _chat,
              onOpenSettings: _openAiSettings,
              bookTitle: _activeBookTitle,
              sessionTitle: _activeSessionTitle,
              onLoadDiagnostics: () async {
                final id = _activeSessionId;
                return id == null ? <StoredAiDiagnostic>[] :
                    _books.diagnostics(id);
              },
            )
          : _page == _Page.about ? _buildAbout()
          : _page == _Page.settings ? _buildSettings()
          : _page == _Page.updates ? UpdateSettingsPanel(
              controller: _updates,
              onBack: () => setState(() => _page = _Page.settings),
              onViewAllVersions: () => _openUrl(_allReleasesUrl),
              onCheckManually: _checkForUpdates,
            )
          : _page == _Page.ai ? AiSettingsPanel(
              controller: _ai,
              onBack: () => setState(() => _page = _aiReturnPage),
            )
          : _page == _Page.diagnostics ? AiDiagnosticsSettingsPage(
              onBack: () => setState(() => _page = _Page.settings),
              onPrune: _books.pruneDiagnostics,
            )
          : _buildSettings()),
      ]),
    ),
    );
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
                  _page == _Page.chat,
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
                  _page == _Page.diagnostics,
              selectedColor: DomoliaColors.goldLight,
              selectedTileColor: DomoliaColors.raisedSurface,
              onTap: () => _showPage(_Page.settings),
            ),
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'VERSION DE DÉVELOPPEMENT',
                style: TextStyle(
                  color: DomoliaColors.muted,
                  letterSpacing: 1.4,
                  fontSize: 11,
                ),
              ),
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
        const SizedBox(height: 20),
        ListTile(
          leading: const Icon(Icons.smart_toy_outlined, color: DomoliaColors.gold),
          title: const Text('Configurations IA'),
          subtitle: const Text('Profils, fournisseurs et modèles'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _openAiSettings,
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.system_update_alt_rounded, color: DomoliaColors.gold),
          title: const Text('Mises à jour'),
          subtitle: const Text('Version installée, canal et préversions'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => setState(() => _page = _Page.updates),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.bug_report_outlined,
              color: DomoliaColors.gold),
          title: const Text('Diagnostics IA'),
          subtitle: const Text('Conservation locale des requêtes et réponses'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => setState(() => _page = _Page.diagnostics),
        ),
      ],
    ),
  );

  Widget _buildHome() {
    return SafeArea(
      child: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 26, 24, 44),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Image.asset(
                      'assets/images/domolia_emblem.png',
                      width: 170,
                      height: 170,
                      semanticLabel: 'Bouclier doré Domolia',
                    ),
                  ),
                  const SizedBox(height: 15),
                  const Text(
                    'DOMOLIA',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: DomoliaColors.goldLight,
                      fontFamily: 'serif',
                      fontSize: 37,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Des histoires à vivre, un monde à explorer.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: DomoliaColors.cream,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 25),
                  const _GoldSeparator(),
                  const SizedBox(height: 25),
                  const _DomoliaPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Hello World !',
                          style: TextStyle(
                            color: DomoliaColors.goldLight,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 10),
                        Text(
                          'Votre aventure commence ici. '
                          'Cette première version présente l’identité de '
                          'Domolia et son système de mises à jour.',
                          style: TextStyle(
                            color: DomoliaColors.cream,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _openBooks,
                    icon: const Icon(Icons.library_books_outlined),
                    label: const Text('Ouvrir mes Livres'),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _checkForUpdates,
                    icon: const Icon(Icons.system_update_alt_rounded),
                    label: const Text('Mise à jour'),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'Canal de développement · ${_updates.channel}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: DomoliaColors.muted,
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
                      'Domolia est une future application de jeu de rôle '
                      'narratif, pensée pour des histoires vivantes, '
                      'des personnages persistants et des mondes à explorer.\n\n'
                      'Cette version est un premier prototype Android.',
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
