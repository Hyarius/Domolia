import 'package:material_ui/material_ui.dart';
import '../theme/domolia_theme.dart';
import 'update_service.dart';

class UpdateProgressStrip extends StatelessWidget {
  const UpdateProgressStrip({super.key, required this.controller});
  final UpdateController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: DomoliaColors.surface,
      padding: const EdgeInsets.fromLTRB(18, 10, 12, 8),
      child: Row(children: [
        const Icon(Icons.system_update_alt_rounded,color:DomoliaColors.gold),
        const SizedBox(width:12),
        Expanded(child: Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('Mise à jour de Domolia en cours…',
            style:TextStyle(color:DomoliaColors.goldLight)),
          const SizedBox(height:6),
          LinearProgressIndicator(value:controller.progress,
            backgroundColor:DomoliaColors.raisedSurface,
            color:DomoliaColors.gold),
        ])),
        IconButton(tooltip:'Annuler le téléchargement',
          onPressed:controller.cancelDownload,icon:const Icon(Icons.close)),
      ]),
    );
  }
}

class UpdateSettingsPanel extends StatefulWidget {
  const UpdateSettingsPanel({
    super.key,
    required this.controller,
    this.onConfigureAi,
    this.onConfigureNarrator,
    this.onCheckManually,
  });
  final UpdateController controller;
  final VoidCallback? onConfigureAi;
  final VoidCallback? onConfigureNarrator;
  final VoidCallback? onCheckManually;
  @override
  State<UpdateSettingsPanel> createState()=>_UpdateSettingsPanelState();
}
class _UpdateSettingsPanelState extends State<UpdateSettingsPanel> {
  late final TextEditingController _channelInput;

  @override
  void initState() {
    super.initState();
    _channelInput=TextEditingController(text:widget.controller.channel);
  }
  @override
  void dispose() { _channelInput.dispose(); super.dispose(); }

  Future<void> _saveChannel(String value) async {
    try {
      await widget.controller.changeChannel(value);
      if(mounted) {
        _channelInput.text=widget.controller.channel;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content:Text('Canal de mise à jour enregistré.')));
      }
    } catch(error) {
      if(mounted) { ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content:Text('$error'))); }
    }
  }

  @override
  Widget build(BuildContext context) {
    final updater=widget.controller;
    final version=updater.installed;
    final checking=updater.phase==UpdatePhase.checking;
    final downloading=updater.phase==UpdatePhase.downloading;
    return SafeArea(child: ListView(padding:const EdgeInsets.all(24),children:[
      const Text('Mises à jour',style:TextStyle(
        color:DomoliaColors.goldLight,fontSize:25,fontWeight:FontWeight.bold)),
      const SizedBox(height:20),
      Text('Version installée : ${version == null ? 'inconnue' : '${version.versionName} (build ${version.versionCode})'}'),
      const SizedBox(height:18),
      SwitchListTile(
        title:const Text('Vérifier automatiquement au démarrage'),
        subtitle:const Text('Télécharger sans bloquer la navigation.'),
        value:updater.automatic,
        activeTrackColor:DomoliaColors.goldDark,
        onChanged:(enabled) => updater.changeAutomatic(enabled),
      ),
      const SizedBox(height:20),
      TextField(
        controller:_channelInput,
        decoration:const InputDecoration(
          labelText:'Canal de mise à jour',
          helperText:'dev-latest ou tag preview-… de votre branche',
        ),
        onSubmitted:_saveChannel,
      ),
      const SizedBox(height:12),
      OutlinedButton(
        onPressed:()=>_saveChannel(_channelInput.text),
        child:const Text('Enregistrer le canal'),
      ),
      TextButton(onPressed:()=>_saveChannel('dev-latest'),
        child:const Text('Revenir au canal dev-latest')),
      const SizedBox(height:20),
      Text('Dernière vérification : ${updater.lastCheck?.toLocal() ?? 'jamais'}',
        style:const TextStyle(color:DomoliaColors.muted)),
      const SizedBox(height:8),
      Text('État : ${switch(updater.phase) {
        UpdatePhase.idle => 'en attente',
        UpdatePhase.checking => 'vérification en cours',
        UpdatePhase.upToDate => 'à jour',
        UpdatePhase.downloading => 'téléchargement en cours',
        UpdatePhase.cancelled => 'annulé',
        UpdatePhase.installationRequested => 'installation proposée',
        UpdatePhase.permissionRequired => 'autorisation Android requise',
        UpdatePhase.failed => 'erreur',
      }}'),
      if(updater.message!=null) Padding(
        padding:const EdgeInsets.only(top:8),
        child:Text(updater.message!,style:const TextStyle(color:DomoliaColors.muted))),
      const SizedBox(height:18),
      FilledButton.icon(
        onPressed:checking || downloading ? null : widget.onCheckManually ?? updater.checkNow,
        icon:const Icon(Icons.refresh),
        label:const Text('Vérifier maintenant'),
      ),
      if(downloading) TextButton.icon(
        onPressed:updater.cancelDownload,
        icon:const Icon(Icons.close),label:const Text('Annuler le téléchargement')),
      if (widget.onConfigureNarrator != null) ...[
        const SizedBox(height: 12),
        ListTile(
          leading: const Icon(
            Icons.auto_stories_outlined,
            color: DomoliaColors.gold,
          ),
          title: const Text('Narrateur'),
          subtitle: const Text('Style et messages d’ouverture'),
          onTap: widget.onConfigureNarrator,
        ),
      ],
      if(widget.onConfigureAi!=null) ...[
        const SizedBox(height:20),
        const Divider(),
        ListTile(
          leading:const Icon(Icons.smart_toy_outlined,color:DomoliaColors.gold),
          title:const Text('Fournisseur IA'),
          subtitle:const Text('Configurer OpenUncensored et tester la connexion'),
          onTap:widget.onConfigureAi,
        ),
      ],
    ]));
  }
}

/// Feedback is shown only for user-initiated checks, never for the startup check.
class UpdateCheckDialog extends StatelessWidget {
  const UpdateCheckDialog({super.key, required this.controller});

  final UpdateController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final phase = controller.phase;
        final pending = phase == UpdatePhase.checking ||
            phase == UpdatePhase.downloading ||
            phase == UpdatePhase.idle;
        final status = switch (phase) {
          UpdatePhase.idle || UpdatePhase.checking =>
            'Recherche de mises à jour sur ${controller.channel}…',
          UpdatePhase.upToDate =>
            'Domolia est déjà à jour sur le canal ${controller.channel}.',
          UpdatePhase.downloading =>
            'Une nouvelle version est disponible. Téléchargement en cours…',
          UpdatePhase.cancelled => 'Le téléchargement a été annulé.',
          UpdatePhase.installationRequested =>
            controller.message ?? 'Installation Android proposée.',
          UpdatePhase.permissionRequired =>
            controller.message ?? 'Autorisation Android nécessaire.',
          UpdatePhase.failed =>
            controller.message ?? 'Impossible de vérifier les mises à jour.',
        };
        return AlertDialog(
          key: const ValueKey('updateCheckDialog'),
          title: const Text('Mise à jour de Domolia'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(status, key: const ValueKey('updateCheckStatus')),
              if (pending) ...[
                const SizedBox(height: 18),
                LinearProgressIndicator(
                  value: phase == UpdatePhase.downloading
                      ? controller.progress
                      : null,
                  color: DomoliaColors.gold,
                ),
              ],
              if (controller.installed != null) ...[
                const SizedBox(height: 12),
                Text(
                  'Version installée : build ${controller.installed!.versionCode}',
                  style: const TextStyle(color: DomoliaColors.muted),
                ),
              ],
            ],
          ),
          actions: [
            if (phase == UpdatePhase.downloading)
              TextButton(
                onPressed: controller.cancelDownload,
                child: const Text('Annuler'),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Fermer'),
            ),
          ],
        );
      },
    );
  }
}
