import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart' as cupertino_ui;
import 'package:flutter_localizations/flutter_localizations.dart' as flutter_l10n;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'theme/domolia_theme.dart';
import 'chat/chat_controller.dart';
import 'chat/group_chat_page.dart';
import 'ai/ai_controller.dart';
import 'ai/ai_provider.dart';
import 'ai/ai_settings_panel.dart';
import 'ai/ai_storage.dart';
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
  });

  final UpdateController? updateController;
  final AiConnectionController? aiController;
  final NarrativeChatController? chatController;

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
      ),
    );
  }
}

enum _Page { home, chat, about, updates, ai }

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.updates, this.ai, this.chat});
  final UpdateController? updates;
  final AiConnectionController? ai;
  final NarrativeChatController? chat;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  _Page _page = _Page.home;
  late final UpdateController _updates;
  late final bool _ownsUpdates;
  late final AiConnectionController _ai;
  late final bool _ownsAi;
  late final NarrativeChatController _chat;
  late final bool _ownsChat;

  @override
  void initState() {
    super.initState();
    _ownsUpdates = widget.updates == null;
    _updates = widget.updates ?? createProductionUpdateController();
    _ownsAi = widget.ai == null;
    _ai = widget.ai ?? AiConnectionController(
      store: SecureAiProfileStore(),
      provider: OpenAiCompatibleChatProvider(),
    );
    _ownsChat = widget.chat == null;
    _chat = widget.chat ?? NarrativeChatController(
      provider: _ai.provider,
      configuration: () => _ai.initialized && _ai.profiles.isNotEmpty
          ? _ai.selectedProfile.configuration
          : null,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_updates.initialize());
    });
  }

  @override
  void dispose() {
    if (_ownsUpdates) _updates.dispose();
    if (_ownsChat) _chat.dispose();
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

  void _openChat() {
    unawaited(_ai.initialize());
    setState(() => _page = _Page.chat);
  }

  void _openAiSettings() {
    unawaited(_ai.initialize());
    setState(() => _page = _Page.ai);
  }

  void _showPage(_Page page) {
    Navigator.pop(context); // Ferme le menu latéral.
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
          : _page == _Page.chat ? GroupChatPage(
              controller: _chat,
              onOpenSettings: _openAiSettings,
            )
          : _page == _Page.about ? _buildAbout()
          : _page == _Page.ai ? AiSettingsPanel(
              controller: _ai,
              onBack: () => setState(() => _page = _Page.updates),
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
              leading: const Icon(Icons.forum_outlined),
              title: const Text('Conversation'),
              selected: _page == _Page.chat,
              selectedColor: DomoliaColors.goldLight,
              selectedTileColor: DomoliaColors.raisedSurface,
              onTap: () {
                Navigator.pop(context);
                _openChat();
              },
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
              selected: _page == _Page.updates,
              onTap: () => _showPage(_Page.updates),
            ),
            ListTile(
              leading: const Icon(Icons.smart_toy_outlined),
              title: const Text('Fournisseur IA'),
              onTap: () => _showPage(_Page.ai),
            ),
            ListTile(
              leading: const Icon(Icons.system_update_alt_rounded),
              title: const Text('Mise à jour'),
              iconColor: DomoliaColors.gold,
              onTap: () {
                Navigator.pop(context);
                _checkForUpdates();
              },
            ),
            ListTile(
              leading: const Icon(Icons.new_releases_outlined),
              title: const Text('Toutes les versions'),
              iconColor: DomoliaColors.gold,
              onTap: () {
                Navigator.pop(context);
                _openUrl(_allReleasesUrl);
              },
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

  Widget _buildSettings() => UpdateSettingsPanel(
    controller: _updates,
    onConfigureAi: () => setState(() => _page = _Page.ai),
    onCheckManually: _checkForUpdates,
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
                    onPressed: _openChat,
                    icon: const Icon(Icons.forum_outlined),
                    label: const Text('Commencer une conversation'),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _checkForUpdates,
                    icon: const Icon(Icons.system_update_alt_rounded),
                    label: const Text('Mise à jour'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => _openUrl(_allReleasesUrl),
                    icon: const Icon(Icons.new_releases_outlined),
                    label: const Text('Toutes les versions'),
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
