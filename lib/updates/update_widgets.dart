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
  const UpdateSettingsPanel({super.key,required this.controller});
  final UpdateController controller;
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
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content:Text('$error')));
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
      Text('Version installée : '+(version==null?'inconnue':
        version.versionName+' (build '+version.versionCode.toString()+')')),
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
      Text('Dernière vérification : '+(updater.lastCheck?.toLocal().toString()??'jamais'),
        style:const TextStyle(color:DomoliaColors.muted)),
      const SizedBox(height:8),
      Text('État : '+switch(updater.phase) {
        UpdatePhase.idle => 'en attente',
        UpdatePhase.checking => 'vérification en cours',
        UpdatePhase.upToDate => 'à jour',
        UpdatePhase.downloading => 'téléchargement en cours',
        UpdatePhase.cancelled => 'annulé',
        UpdatePhase.installationRequested => 'installation proposée',
        UpdatePhase.permissionRequired => 'autorisation Android requise',
        UpdatePhase.failed => 'erreur',
      }),
      if(updater.message!=null) Padding(
        padding:const EdgeInsets.only(top:8),
        child:Text(updater.message!,style:const TextStyle(color:DomoliaColors.muted))),
      const SizedBox(height:18),
      FilledButton.icon(
        onPressed:checking || downloading ? null : updater.checkNow,
        icon:const Icon(Icons.refresh),
        label:const Text('Vérifier maintenant'),
      ),
      if(downloading) TextButton.icon(
        onPressed:updater.cancelDownload,
        icon:const Icon(Icons.close),label:const Text('Annuler le téléchargement')),
    ]));
  }
}
