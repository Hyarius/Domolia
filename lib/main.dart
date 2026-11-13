import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

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
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF826AB5),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  static final Uri _releasesUrl =
      Uri.parse('https://github.com/Hyarius/Domolia/releases');

  Future<void> _openUpdates(BuildContext context) async {
    final opened = await launchUrl(
      _releasesUrl,
      mode: LaunchMode.externalApplication,
    );

    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Impossible d’ouvrir les versions sur GitHub.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Domolia')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.auto_stories_rounded, size: 76, color: colors.primary),
              const SizedBox(height: 28),
              Text(
                'Bonjour, monde !',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 10),
              Text(
                'Domolia, le début de votre aventure.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: () => _openUpdates(context),
                icon: const Icon(Icons.system_update_rounded),
                label: const Text('Mise à jour'),
              ),
              const SizedBox(height: 10),
              Text(
                'Les nouvelles versions s’installent depuis GitHub.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
