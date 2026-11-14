import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/domolia_theme.dart';

/// A local storage limit, per conversation. Setting it to zero disables
/// recording and deletes all previously persisted AI diagnostics.
class AiDiagnosticsRetentionPreferences {
  const AiDiagnosticsRetentionPreferences();

  static const allowedLimits = <int>[0, 5, 10, 20, 50];
  static const defaultLimit = 10;
  static const _key = 'aiDiagnosticsRetentionPerSession';

  Future<int> limit() async {
    final saved = (await SharedPreferences.getInstance()).getInt(_key);
    return allowedLimits.contains(saved) ? saved! : defaultLimit;
  }

  Future<void> setLimit(int value) async {
    if (!allowedLimits.contains(value)) {
      throw ArgumentError.value(value, 'value', 'Invalid diagnostics limit');
    }
    await (await SharedPreferences.getInstance()).setInt(_key, value);
  }
}

class AiDiagnosticsSettingsPage extends StatefulWidget {
  const AiDiagnosticsSettingsPage({
    super.key,
    required this.onBack,
    required this.onPrune,
    this.preferences = const AiDiagnosticsRetentionPreferences(),
  });

  final VoidCallback onBack;
  final Future<void> Function(int limit) onPrune;
  final AiDiagnosticsRetentionPreferences preferences;

  @override
  State<AiDiagnosticsSettingsPage> createState() =>
      _AiDiagnosticsSettingsPageState();
}

class _AiDiagnosticsSettingsPageState extends State<AiDiagnosticsSettingsPage> {
  int? _limit;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await widget.preferences.limit();
      if (mounted) setState(() => _limit = value);
    } catch (_) {
      if (mounted) {
        setState(() => _limit = AiDiagnosticsRetentionPreferences.defaultLimit);
      }
    }
  }

  Future<void> _change(int? value) async {
    if (_saving || value == null || value == _limit) return;
    setState(() => _saving = true);
    try {
      await widget.preferences.setLimit(value);
      await widget.onPrune(value);
      if (mounted) setState(() => _limit = value);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Impossible de modifier la conservation des diagnostics.'),
        ));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          TextButton.icon(
            onPressed: widget.onBack,
            icon: const Icon(Icons.arrow_back),
            label: const Text('Retour aux paramètres'),
          ),
          const SizedBox(height: 12),
          const Text('Diagnostics IA', style: TextStyle(
            color: DomoliaColors.goldLight,
            fontSize: 25,
            fontWeight: FontWeight.bold,
          )),
          const SizedBox(height: 18),
          const Text(
            'Lors de chaque génération, Domolia peut conserver localement '
            'le corps de la requête réellement envoyée et le flux brut reçu. '
            'Les clés API et les jetons sont masqués. Les données de narration '
            'restent sensibles : ne partagez un export que volontairement.',
          ),
          const SizedBox(height: 24),
          DropdownButtonFormField<int>(
            key: const ValueKey('diagnosticsRetention'),
            initialValue: _limit,
            decoration: const InputDecoration(
              labelText: 'Diagnostics conservés par partie',
            ),
            items: [
              for (final value in AiDiagnosticsRetentionPreferences.allowedLimits)
                DropdownMenuItem<int>(
                  value: value,
                  child: Text(value == 0 ? 'Désactivé (tout effacer)' :
                      '$value derniers échanges'),
                ),
            ],
            onChanged: _saving || _limit == null ? null : _change,
          ),
          const SizedBox(height: 14),
          const Text(
            'Les traces les plus anciennes sont supprimées automatiquement. '
            'La suppression d’une partie efface également ses diagnostics. '
            'Les fichiers déjà exportés restent sous votre contrôle.',
            style: TextStyle(color: DomoliaColors.muted),
          ),
        ],
      ),
    );
  }
}
