import 'package:cupertino_ui/cupertino_ui.dart' as cupertino_ui;
import 'package:flutter_localizations/flutter_localizations.dart' as flutter_l10n;
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'theme/domolia_theme.dart';

void main() {
  runApp(const DomoliaApp());
}

class DomoliaApp extends StatelessWidget {
  const DomoliaApp({super.key});

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
      home: const HomePage(),
    );
  }
}

enum _Page { home, about }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  _Page _page = _Page.home;

  static final Uri _devReleaseUrl = Uri.parse(
    'https://github.com/Hyarius/Domolia/releases/tag/dev-latest',
  );
  static final Uri _allReleasesUrl = Uri.parse(
    'https://github.com/Hyarius/Domolia/releases',
  );

  Future<void> _openUrl(Uri url) async {
    final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d’ouvrir GitHub.')),
      );
    }
  }

  void _showPage(_Page page) {
    Navigator.pop(context); // Ferme le menu latéral.
    setState(() => _page = page);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
            onPressed: () => _openUrl(_devReleaseUrl),
            icon: const Icon(Icons.system_update_alt_rounded),
          ),
        ],
      ),
      drawer: _buildDrawer(),
      body: _page == _Page.home ? _buildHome() : _buildAbout(),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: SafeArea(
        child: Column(
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
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text('À propos'),
              selected: _page == _Page.about,
              selectedColor: DomoliaColors.goldLight,
              selectedTileColor: DomoliaColors.raisedSurface,
              onTap: () => _showPage(_Page.about),
            ),
            const Divider(indent: 16, endIndent: 16),
            ListTile(
              leading: const Icon(Icons.system_update_alt_rounded),
              title: const Text('Mise à jour'),
              iconColor: DomoliaColors.gold,
              onTap: () {
                Navigator.pop(context);
                _openUrl(_devReleaseUrl);
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
            const Spacer(),
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
                          'Bonjour, monde !',
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
                    onPressed: () => _openUrl(_devReleaseUrl),
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
                  const Text(
                    'Canal de développement · dev-latest',
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
