import 'package:material_ui/material_ui.dart';

import '../theme/domolia_theme.dart';
import 'book_lore.dart';

/// Card browser: collapsible catalogues, bounded scrolling and full-screen forms.
class BookLoreTab extends StatefulWidget {
  const BookLoreTab({
    super.key,
    required this.lore,
    required this.onSave,
  });
  final BookLore lore;
  final Future<void> Function(BookLore) onSave;

  @override
  State<BookLoreTab> createState() => _BookLoreTabState();
}

class _BookLoreTabState extends State<BookLoreTab> {
  final Map<String, String> _queries = {};
  final Map<String, String> _tagFilters = {};
  final Map<String, String> _typeFilters = {};
  final Set<String> _expanded = {'global'};

  Future<bool> _commit(BookLore next) async {
    try {
      next.validate();
      await widget.onSave(next);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Lore enregistré.')));
      }
      return true;
    } on FormatException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Échec de sauvegarde du Lore.')));
      }
    }
    return false;
  }

  List<_Field> _globalFields(LoreGlobal g) => [
    _Field('universe', 'Nom de l’univers', g.universe, max:120),
    _Field('overview', 'Présentation et faits établis', g.overview),
    _Field('genre', 'Genre et ambiance', g.genre, max:250),
    _Field('era', 'Époque', g.era, max:250),
    _Field('initialContext', 'Contexte initial', g.initialContext),
    _Field('history', 'Histoire du monde', g.history),
    _Field('rules', 'Règles fondamentales du monde', g.rules),
    _Field('conflicts', 'Conflits majeurs', g.conflicts),
    _Field('directions', 'Indications narratives de l’auteur', g.directions),
    _Field('secrets', 'Secrets réservés au narrateur', g.secrets),
  ];

  Future<void> _editGlobal() async {
    await Navigator.push<void>(
      context, MaterialPageRoute(builder: (_) => _LoreForm(
        title: 'Lore global',
        fields: _globalFields(widget.lore.global),
        onSubmit: (result) {
          String v(String key) => result.values[key] ?? '';
          return _commit(widget.lore.copyWith(global: LoreGlobal(
            universe:v('universe'),overview:v('overview'),genre:v('genre'),
            era:v('era'),initialContext:v('initialContext'),history:v('history'),
            rules:v('rules'),conflicts:v('conflicts'),directions:v('directions'),
            secrets:v('secrets'),
          )));
        },
      )),
    );
  }

  List<_Field> _baseFields(LoreRecord? record) => [
    _Field('name','Nom / titre',record?.name ?? '',max:150),
    _Field('aliases','Alias (séparés par des virgules)',
        record?.aliases.join(', ') ?? '',max:3000,short:true),
    _Field('tags','Tags (séparés par des virgules)',
        record?.tags.join(', ') ?? '',max:3000,short:true),
    _Field('description','Description',record?.description ?? ''),
    _Field('secrets','Secrets réservés au narrateur',record?.secrets ?? ''),
  ];

  Future<void> _edit(String category, [LoreRecord? record]) async {
    final lore = widget.lore;
    final fields = <_Field>[
      ..._baseFields(record),
      if (category == 'characters') ...[
        _Field('appearance','Apparence',(record as LoreCharacter?)?.appearance ?? ''),
        _Field('personality','Personnalité',record?.personality ?? ''),
        _Field('background','Histoire personnelle',record?.background ?? ''),
        _Field('role','Rôle ou catégorie',record?.role ?? '',max:150),
        _Field('motivations','Motivations',record?.motivations ?? ''),
        _Field('values','Valeurs et comportements',record?.values ?? ''),
      ],
      if (category == 'places') ...[
        _Field('type','Type de lieu',(record as LorePlace?)?.type ?? '',max:150),
        _Field('atmosphere','Atmosphère',record?.atmosphere ?? ''),
        _Field('history','Histoire',record?.history ?? ''),
        _Field('features','Caractéristiques importantes',record?.features ?? ''),
      ],
      if (category == 'scenarios') ...[
        _Field('summary','Synopsis',(record as LoreScenario?)?.summary ?? ''),
        _Field('importance','Importance',
            record?.importance.name ?? 'secondary',
            choices: const {'main':'Principal','secondary':'Secondaire'}),
        _Field('initialContext','Contexte initial',record?.initialContext ?? ''),
        _Field('objectives','Objectifs narratifs',record?.objectives ?? ''),
        _Field('introduction','Conditions d’introduction',
            record?.introduction ?? ''),
      ],
      if (category == 'events') ...[
        _Field('trigger','Catégorie de déclenchement',
            (record as LoreEvent?)?.trigger.name ?? 'optional',
            choices: const {
              'planned':'Prévu / inévitable',
              'conditional':'Conditionnel',
              'optional':'Facultatif',
            }),
        _Field('mandatory','Comportement attendu',
            record?.mandatory == true ? 'true' : 'false',
            choices: const {'false':'Facultatif','true':'Obligatoire'}),
        _Field('condition','Condition narrative (si applicable)',
            record?.condition ?? ''),
        _Field('timing','Moment souhaité',record?.timing ?? ''),
        _Field('consequences','Conséquences possibles',
            record?.consequences ?? ''),
        _Field('priority','Priorité',
            (record?.priority ?? 0).toString(),
            choices: {for(var i=0;i<=10;i++) '$i':'$i'}),
      ],
    ];
    List<_ReferenceField> references = [];
    final characters = lore.characters.where((p) => p.id != record?.id).toList();
    final places = lore.places.where((p) => p.id != record?.id).toList();
    if (category == 'characters') {
      final c = record as LoreCharacter?;
      references = [
        _ReferenceField('relatedCharacterIds','Relations initiales',characters,
          c?.relatedCharacterIds ?? []),
        _ReferenceField('homePlaceId','Lieu habituel',places,
          c?.homePlaceId == null ? [] : [c!.homePlaceId!],single:true),
      ];
    } else if (category == 'places') {
      final p = record as LorePlace?;
      references = [
        _ReferenceField('characterIds','Personnages associés',
          characters,p?.characterIds ?? []),
        _ReferenceField('placeIds','Lieux associés',places,p?.placeIds ?? []),
      ];
    } else if (category == 'scenarios') {
      final s = record as LoreScenario?;
      references = [
        _ReferenceField('characterIds','Personnages',characters,s?.characterIds ?? []),
        _ReferenceField('placeIds','Lieux',places,s?.placeIds ?? []),
        _ReferenceField('eventIds','Événements',lore.events,s?.eventIds ?? []),
      ];
    } else if (category == 'events') {
      final e = record as LoreEvent?;
      references = [
        _ReferenceField('characterIds','Personnages',characters,e?.characterIds ?? []),
        _ReferenceField('placeIds','Lieux',places,e?.placeIds ?? []),
        _ReferenceField('scenarioIds','Scénarios',lore.scenarios,e?.scenarioIds ?? []),
      ];
    }
    if (!mounted) return;
    await Navigator.push<void>(
      context, MaterialPageRoute(builder: (_) => _LoreForm(
        title: record == null ? 'Nouvelle fiche' : record.name,
        fields: fields, references: references,
        onSubmit: (result) => _saveRecord(category, record, result),
      )),
    );
  }

  /// Keep the editor open when model validation or SQLite persistence fails.
  Future<bool> _saveRecord(
      String category, LoreRecord? record, _EditResult result) async {
    try {
      final lore = widget.lore;
      String v(String key) => result.values[key] ?? '';
      List<String> values(String key) => v(key).split(',')
          .map((s) => s.trim()).where((s) => s.isNotEmpty).toSet().toList();
      List<String> refs(String key) => result.references[key] ?? [];
      final id = record?.id ?? newLoreId();
      final common = <String, Object?>{
        'id': id,'name':v('name').trim(),'description':v('description'),
        'aliases':values('aliases'),'tags':values('tags'),'secrets':v('secrets'),
      };
      BookLore next;
      switch (category) {
        case 'characters':
          next = lore.putCharacter(LoreCharacter.fromJson({
            ...common,'appearance':v('appearance'),'personality':v('personality'),
            'background':v('background'),'role':v('role'),
            'motivations':v('motivations'),'values':v('values'),
            'relatedCharacterIds':refs('relatedCharacterIds'),
            'homePlaceId':refs('homePlaceId').firstOrNull,
          }));
        case 'places':
          next = lore.putPlace(LorePlace.fromJson({
            ...common,'type':v('type'),'atmosphere':v('atmosphere'),
            'history':v('history'),'features':v('features'),
            'characterIds':refs('characterIds'),'placeIds':refs('placeIds'),
          }));
        case 'scenarios':
          next = lore.putScenario(LoreScenario.fromJson({
            ...common,'summary':v('summary'),'importance':v('importance'),
            'initialContext':v('initialContext'),'objectives':v('objectives'),
            'introduction':v('introduction'),
            'characterIds':refs('characterIds'),'placeIds':refs('placeIds'),
            'eventIds':refs('eventIds'),
          }));
        case 'events':
          next = lore.putEvent(LoreEvent.fromJson({
            ...common,'trigger':v('trigger'),'mandatory':v('mandatory') == 'true',
            'condition':v('condition'),'timing':v('timing'),
            'consequences':v('consequences'),
            'priority':int.parse(v('priority')),
            'characterIds':refs('characterIds'),'placeIds':refs('placeIds'),
            'scenarioIds':refs('scenarioIds'),
          }));
        default:
          return false;
      }
      return await _commit(next);
    } on FormatException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)));
      }
      return false;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Fiche de Lore invalide.')));
      }
      return false;
    }
  }

  Future<void> _duplicate(String category, LoreRecord record) async {
    final source = switch (record) {
      LoreCharacter c => c.toJson(),
      LorePlace p => p.toJson(),
      LoreScenario s => s.toJson(),
      LoreEvent e => e.toJson(),
      _ => <String, Object?>{},
    };
    // The suffix must not invalidate a maximum-length name.
    final baseName = record.name.length > 142
        ? record.name.substring(0, 142) : record.name;
    final copy = {...source, 'id': newLoreId(),
      'name': '$baseName (copie)'};
    final next = switch (category) {
      'characters' => widget.lore.putCharacter(LoreCharacter.fromJson(copy)),
      'places' => widget.lore.putPlace(LorePlace.fromJson(copy)),
      'scenarios' => widget.lore.putScenario(LoreScenario.fromJson(copy)),
      'events' => widget.lore.putEvent(LoreEvent.fromJson(copy)),
      _ => widget.lore,
    };
    await _commit(next);
  }

  Future<void> _delete(String category, LoreRecord record) async {
    final incoming = widget.lore.referencesTo(record.id);
    final confirmed = await showDialog<bool>(context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Supprimer cette fiche ?'),
        content: SingleChildScrollView(child: Text(incoming.isEmpty
          ? 'Cette suppression est définitive.'
          : 'Cette fiche est référencée par :\n${incoming.join("\n")}\n\n'
            'La suppression détachera ces références.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog,false),
            child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(dialog,true),
            child: const Text('Supprimer et détacher')),
        ],
      ));
    if (confirmed == true) {
      await _commit(widget.lore.remove(category,record.id,unlink:true));
    }
  }

  String _type(LoreRecord record) => switch (record) {
    LoreCharacter c => c.role,
    LorePlace p => p.type,
    LoreScenario s => s.importance == LoreScenarioImportance.main
        ? 'Principal' : 'Secondaire',
    LoreEvent e => switch (e.trigger) {
      LoreEventTrigger.planned => 'Prévu',
      LoreEventTrigger.conditional => 'Conditionnel',
      LoreEventTrigger.optional => 'Facultatif',
    },
    _ => '',
  };

  Widget _section(String key, String title, List<LoreRecord> items) {
    final query = _normalize(_queries[key] ?? '');
    final tags = items.expand((e) => e.tags).toSet().toList()..sort();
    final types = items.map(_type).where((s) => s.isNotEmpty).toSet().toList()..sort();
    // A deleted/edited record may remove the selected filter from the options.
    final savedTag = _tagFilters[key] ?? '';
    final selectedTag = tags.contains(savedTag) ? savedTag : '';
    final savedType = _typeFilters[key] ?? '';
    final selectedType = types.contains(savedType) ? savedType : '';
    final filtered = items.where((e) =>
      (query.isEmpty || _normalize([e.name,...e.aliases].join(' ')).contains(query)) &&
      (selectedTag.isEmpty || e.tags.contains(selectedTag)) &&
      (selectedType.isEmpty || _type(e) == selectedType)
    ).toList()..sort((a,b) => _normalize(a.name).compareTo(_normalize(b.name)));
    return Card(
      child: ExpansionTile(
        key: ValueKey('loreSection-$key'),
        title: Text('$title (${items.length})',style: const TextStyle(
          color: DomoliaColors.goldLight,fontWeight: FontWeight.bold)),
        initiallyExpanded: _expanded.contains(key),
        maintainState: true,
        onExpansionChanged: (open) {
          if (open) { _expanded.add(key); } else { _expanded.remove(key); }
        },
        children: [
          Padding(padding: const EdgeInsets.symmetric(horizontal:12),
            child: TextField(
              key: ValueKey('loreSearch-$key'),
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search),
                labelText:'Rechercher par nom ou alias'),
              onChanged: (value) => setState(() => _queries[key] = value),
            )),
          if (tags.isNotEmpty) Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: KeyedSubtree(
              key: ValueKey('loreTagOptions-$key-${tags.join("|")}'),
              child: DropdownButtonFormField<String>(
              key: ValueKey('loreTags-$key'),
              initialValue: selectedTag,
              isExpanded:true,
              decoration:const InputDecoration(labelText:'Filtrer par tag'),
              items: [
                const DropdownMenuItem(value:'',child:Text('Tous les tags')),
                for(final tag in tags) DropdownMenuItem(value:tag,
                  child:Text(tag,overflow:TextOverflow.ellipsis)),
              ],
              onChanged:(v) => setState(() => _tagFilters[key] = v ?? ''),
            ))),
          if (types.isNotEmpty) Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: KeyedSubtree(
              key: ValueKey('loreTypeOptions-$key-${types.join("|")}'),
              child: DropdownButtonFormField<String>(
              key: ValueKey('loreTypes-$key'),
              initialValue: selectedType,
              isExpanded:true,
              decoration:const InputDecoration(labelText:'Rôle / catégorie'),
              items: [
                const DropdownMenuItem(value:'',child:Text('Toutes les catégories')),
                for(final type in types) DropdownMenuItem(value:type,
                  child:Text(type,overflow:TextOverflow.ellipsis)),
              ],
              onChanged:(v) => setState(() => _typeFilters[key] = v ?? ''),
            ))),
          Align(alignment:Alignment.centerRight,
            child:TextButton.icon(
              key:ValueKey('loreCreate-$key'),
              onPressed:() => _edit(key),
              icon:const Icon(Icons.add),label:const Text('Ajouter une fiche'),
            )),
          if (items.isEmpty)
            const Padding(padding:EdgeInsets.all(18),
              child:Text('Aucune fiche. Ajoutez un premier élément du monde.'))
          else if (filtered.isEmpty)
            const Padding(padding:EdgeInsets.all(18),
              child:Text('Aucun résultat pour ces filtres.'))
          else SizedBox(
            height: filtered.length <= 5 ? filtered.length * 76.0 : 380,
            child: ListView.builder(
              key:ValueKey('loreList-$key'),
              itemCount:filtered.length,
              itemBuilder:(context,index) {
                final record = filtered[index];
                return ListTile(
                  key:ValueKey('loreItem-${record.id}'),
                  title:Text(record.name,maxLines:1,
                    overflow:TextOverflow.ellipsis),
                  subtitle:Text([_type(record),record.description]
                    .where((s)=>s.isNotEmpty).join(' · '),
                    maxLines:2,overflow:TextOverflow.ellipsis),
                  onTap:() => _edit(key,record),
                  trailing:Row(mainAxisSize:MainAxisSize.min,children:[
                    IconButton(
                      key:ValueKey('loreDuplicate-${record.id}'),
                      icon:const Icon(Icons.copy_outlined),
                      tooltip:'Dupliquer ${record.name}',
                      onPressed:() => _duplicate(key,record),
                    ),
                    IconButton(
                      key:ValueKey('loreDelete-${record.id}'),
                      icon:const Icon(Icons.delete_outline),
                      tooltip:'Supprimer ${record.name}',
                      onPressed:() => _delete(key,record),
                    ),
                  ]),
                );
              },
            )),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment:CrossAxisAlignment.stretch,
    children:[
      Card(child:ExpansionTile(
        key:const ValueKey('loreSection-global'),
        initiallyExpanded:_expanded.contains('global'),
        title:const Text('Lore global',style:TextStyle(
          color:DomoliaColors.goldLight,fontWeight:FontWeight.bold)),
        onExpansionChanged:(open) {
          if(open){_expanded.add('global');}else{_expanded.remove('global');}
        },
        children:[
          ListTile(
            title:Text(widget.lore.global.universe.isEmpty
                ? 'Univers non défini' : widget.lore.global.universe),
            subtitle:Text(widget.lore.global.overview.isEmpty
                ? 'Définissez les faits, intentions et secrets de l’univers.'
                : widget.lore.global.overview,
              maxLines:3,overflow:TextOverflow.ellipsis),
            trailing:const Icon(Icons.edit_outlined),
            onTap:_editGlobal,
          ),
          TextButton.icon(
            key:const ValueKey('loreEditGlobal'),onPressed:_editGlobal,
            icon:const Icon(Icons.edit),label:const Text('Modifier le Lore global')),
        ],
      )),
      _section('characters','Personnages',widget.lore.characters),
      _section('places','Lieux',widget.lore.places),
      _section('scenarios','Scénarios',widget.lore.scenarios),
      _section('events','Événements',widget.lore.events),
    ],
  );

  static String _normalize(String input) {
    const accented = 'àáâäãåçèéêëìíîïñòóôöõùúûüýÿœæ';
    const plain = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final b=StringBuffer();
    for(final rune in input.toLowerCase().runes) {
      final ch=String.fromCharCode(rune);
      final i=accented.indexOf(ch);
      b.write(i<0?ch:plain[i]);
    }
    return b.toString();
  }
}

class _Field {
  const _Field(this.key,this.label,this.value,{
    this.max=12000,this.short=false,this.choices,
  });
  final String key,label,value;
  final int max;
  final bool short;
  final Map<String,String>? choices;
}

class _ReferenceField {
  const _ReferenceField(this.key,this.label,this.options,this.initial,{
    this.single=false,
  });
  final String key,label;
  final List<LoreRecord> options;
  final List<String> initial;
  final bool single;
}

class _EditResult {
  const _EditResult(this.values,this.references);
  final Map<String,String> values;
  final Map<String,List<String>> references;
}

class _LoreForm extends StatefulWidget {
  const _LoreForm({required this.title,required this.fields,
    required this.onSubmit, this.references=const []});
  final String title;
  final List<_Field> fields;
  final List<_ReferenceField> references;
  final Future<bool> Function(_EditResult) onSubmit;
  @override
  State<_LoreForm> createState()=>_LoreFormState();
}

class _LoreFormState extends State<_LoreForm> {
  late final Map<String,TextEditingController> _controllers;
  late final Map<String,String> _dropdowns;
  late final Map<String,List<String>> _references;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controllers={
      for(final field in widget.fields)
        if(field.choices==null) field.key:TextEditingController(text:field.value),
    };
    _dropdowns={
      for(final field in widget.fields)
        if(field.choices!=null) field.key:field.value,
    };
    _references={
      for(final field in widget.references) field.key:[...field.initial],
    };
  }

  @override
  void dispose() {
    for(final c in _controllers.values) { c.dispose(); }
    super.dispose();
  }

  Future<void> _selectReferences(_ReferenceField field) async {
    final chosen={...(_references[field.key] ?? <String>[])};
    var query='';
    final selected=await showDialog<List<String>>(
      context:context,builder:(dialog)=>StatefulBuilder(
        builder:(context,update)=>AlertDialog(
          title:Text(field.label),
          content:SizedBox(width:450,height:400,child:Column(children:[
            TextField(decoration:const InputDecoration(
              prefixIcon:Icon(Icons.search),labelText:'Rechercher une fiche'),
              onChanged:(text)=>update(
                ()=>query=_BookLoreTabState._normalize(text))),
            Expanded(child:ListView.builder(
              itemCount:field.options.length,
              itemBuilder:(context,index) {
                final option=field.options[index];
                if(!_BookLoreTabState._normalize(option.name).contains(query)) {
                  return const SizedBox.shrink();
                }
                return CheckboxListTile(
                  title:Text(option.name),
                  value:chosen.contains(option.id),
                  onChanged:(checked)=>update(() {
                    if(field.single) chosen.clear();
                    if(checked==true) chosen.add(option.id);
                    if(checked==false) chosen.remove(option.id);
                  }),
                );
              })),
          ])),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(dialog),
              child:const Text('Annuler')),
            FilledButton(onPressed:()=>Navigator.pop(dialog,chosen.toList()),
              child:const Text('Valider')),
          ],
        ),
      ),
    );
    if(selected!=null) setState(()=>_references[field.key]=selected);
  }

  Future<void> _save() async {
    if (_saving) return;
    final values={
      for(final entry in _controllers.entries)entry.key:entry.value.text,
      ..._dropdowns,
    };
    setState(() => _saving = true);
    var saved = false;
    try {
      saved = await widget.onSubmit(_EditResult(values,_references));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Échec de sauvegarde du Lore.')));
      }
    }
    if (!mounted) return;
    if (saved) {
      Navigator.pop(context);
    } else {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor:DomoliaColors.background,
    appBar:AppBar(title:Text(widget.title),actions:[
      IconButton(key:const ValueKey('loreFormSave'),
        onPressed:_saving?null:_save,icon:const Icon(Icons.save_outlined),
        tooltip:'Enregistrer la fiche'),
    ]),
    body:SafeArea(child:ListView(
      padding:const EdgeInsets.all(18),
      children:[
        const Text('Les secrets ne sont pas automatiquement révélés au joueur.',
          style:TextStyle(color:DomoliaColors.muted)),
        const SizedBox(height:16),
        for(final field in widget.fields) ...[
          if(field.choices==null)
            TextField(
              key:ValueKey('loreField-${field.key}'),
              controller:_controllers[field.key],
              maxLength:field.max,
              minLines:field.short?1:2,
              maxLines:field.short?1:5,
              decoration:InputDecoration(labelText:field.label,
                alignLabelWithHint:!field.short),
            )
          else
            DropdownButtonFormField<String>(
              key:ValueKey('loreField-${field.key}'),
              initialValue:_dropdowns[field.key],
              decoration:InputDecoration(labelText:field.label),
              items:[
                for(final choice in field.choices!.entries)
                  DropdownMenuItem(value:choice.key,child:Text(choice.value)),
              ],
              onChanged:(value)=>setState(
                ()=>_dropdowns[field.key]=value??field.value),
            ),
          const SizedBox(height:DomoliaSpacing.field),
        ],
        for(final reference in widget.references) ...[
          OutlinedButton.icon(
            key:ValueKey('loreReference-${reference.key}'),
            onPressed:()=>_selectReferences(reference),
            icon:const Icon(Icons.link),
            label:Text('${reference.label} (${_references[reference.key]?.length??0})'),
          ),
          const SizedBox(height:DomoliaSpacing.field),
        ],
        FilledButton.icon(
          key:const ValueKey('loreFormSaveButton'),
          onPressed:_saving?null:_save,icon:const Icon(Icons.save),
          label:const Text('Enregistrer')),
        const SizedBox(height:26),
      ],
    )),
  );
}
