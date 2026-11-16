import 'dart:convert';
import 'dart:io';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/books/book_definition.dart';
import 'package:domolia/books/book_lore.dart';
import 'package:domolia/books/lore_context_builder.dart';
import 'package:domolia/books/book_session.dart';
import 'package:domolia/books/book_store.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const testLore = BookLore(
  global: LoreGlobal(
    universe:'Érévia', overview:'Les royaumes ont signé une trêve.',
    initialContext:'Le roi a convoqué les conseillers.',
    rules:'La magie a un prix.', directions:'Privilégier le mystère.',
    secrets:'Le roi connaît le secret de l’éclipse.',
  ),
  characters:[
    LoreCharacter(id:'king',name:'Roi Émeric',
      aliases:['Le Souverain'],description:'Le roi du Nord.',
      role:'Souverain',motivations:'Protéger le prince.',
      homePlaceId:'palace',relatedCharacterIds:['captain'],
      tags:['cour'],secrets:'Il a menti au conseil.'),
    LoreCharacter(id:'captain',name:'Éloïse',
      description:'Capitaine de la garde.',homePlaceId:'palace',
      tags:['garde']),
    LoreCharacter(id:'merchant',name:'Marchand',role:'Commerçant',
      description:'Il vit loin du royaume.'),
  ],
  places:[
    LorePlace(id:'palace',name:'Palais d’Érévia',
      type:'Château',characterIds:['king','captain'],
      description:'Une forteresse de pierre.',
      placeIds:['forest']),
    LorePlace(id:'forest',name:'Forêt ancienne',type:'Forêt'),
  ],
  scenarios:[
    LoreScenario(id:'missing',name:'Prince disparu',
      summary:'Le prince héritier est introuvable.',
      importance:LoreScenarioImportance.main,
      characterIds:['king'],placeIds:['palace'],eventIds:['eclipse'],
      introduction:'Lorsque la garde signale la disparition.',
      secrets:'Le prince se cache volontairement.'),
  ],
  events:[
    LoreEvent(id:'eclipse',name:'Éclipse royale',
      trigger:LoreEventTrigger.planned,mandatory:true,priority:8,
      timing:'Pendant le festival.',description:'Le soleil disparaît.',
      scenarioIds:['missing'],placeIds:['palace']),
    LoreEvent(id:'prisoner',name:'Ancien prisonnier',
      trigger:LoreEventTrigger.conditional,
      condition:'Si le joueur trouve le passage secret.',
      description:'Un prisonnier propose son aide.',
      characterIds:['captain']),
    LoreEvent(id:'market',name:'Offre au marché',
      trigger:LoreEventTrigger.optional,
      description:'Un marchand propose une relique.'),
  ],
);

const config = AiConfiguration(
  baseUrl: defaultAiBaseUrl,model:defaultAiModel,apiKey:'mock-only',
);

class _FakeProvider implements AiChatProvider {
  final calls = <List<AiMessage>>[];
  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => [];
  @override
  Future<String> complete(AiConfiguration config,{
    required List<AiMessage> messages,int maxTokens=1200,
  }) async {
    calls.add(messages);
    if (calls.length.isOdd) return 'Le palais s’illumine.';
    return jsonEncode({'events':[
      {'type':'message','start':0,'end':'Le palais s’illumine.'.length,
        'speaker':'narrator','name':'Narrateur'},
    ]});
  }
}

void main() {
  sqfliteFfiInit();

  test('Empty lore defaults to a portable v2 Book', () {
    const book = BookDefinition(id:'empty',title:'Vide');
    final parsed = BookDefinition.importJson(book.exportJson());
    expect(parsed.lore.isEmpty,true);
    expect(parsed.toPortableJson()['version'],2);
    expect(parsed.lore.characters,isEmpty);
  });

  test('v1 portable import upgrades to v2 without changing old fields', () {
    final old = jsonDecode(const BookDefinition(
      id:'old',title:'Livre ancien',narrativeStyle:'Style original',
    ).exportJson()) as Map<String,dynamic>;
    old['version'] = 1;
    old.remove('lore');
    final imported = BookDefinition.importJson(jsonEncode(old));
    expect(imported.lore.isEmpty,true);
    expect(imported.narrativeStyle,'Style original');
    expect(jsonDecode(imported.exportJson())['version'],2);
    old['lore'] = {};
    expect(() => BookDefinition.importJson(jsonEncode(old)),throwsFormatException);
  });

  test('Complete canon round-trips Unicode, links, scenarios and all event types', () {
    final original = const BookDefinition(id:'full',title:'Légende',lore:testLore);
    final exported = original.exportJson();
    final restored = BookDefinition.importJson(exported);
    expect(restored.lore.global.universe,'Érévia');
    expect(restored.lore.characters.map((c)=>c.name),
      containsAll(['Roi Émeric','Éloïse']));
    expect(restored.lore.characters.first.relatedCharacterIds,['captain']);
    expect(restored.lore.places.first.characterIds,['king','captain']);
    expect(restored.lore.scenarios.single.eventIds,['eclipse']);
    expect(restored.lore.events.map((e)=>e.trigger),
      containsAll(LoreEventTrigger.values));
    expect(restored.lore.events.last.mandatory,false);
    expect(exported,isNot(contains('apiKey')));
    expect(exported,isNot(contains('sessionId')));
  });

  test('Dangling or duplicated entity references fail validation', () {
    final broken = testLore.copyWith(characters:[
      testLore.characters.first.copyWith(relatedCharacterIds:['unknown']),
      ...testLore.characters.skip(1),
    ]);
    expect(broken.validate,throwsFormatException);
    final repeated = testLore.copyWith(places:[
      ...testLore.places,
      const LorePlace(id:'king',name:'Duplicate'),
    ]);
    expect(repeated.validate,throwsFormatException);
    final map = jsonDecode(const BookDefinition(
      id:'full',title:'Légende',lore:testLore,
    ).exportJson()) as Map<String,dynamic>;
    (map['lore'] as Map<String,dynamic>)['credentials'] = 'secret';
    expect(()=>BookDefinition.importJson(jsonEncode(map)),throwsFormatException);
  });

  test('Removal needs explicit unlink and detaches cross-links', () {
    expect(testLore.referencesTo('king'),isNotEmpty);
    expect(()=>testLore.remove('characters','king'),throwsFormatException);
    final removed = testLore.remove('characters','king',unlink:true);
    expect(removed.characters.any((c)=>c.id=='king'),false);
    expect(removed.places.first.characterIds, ['captain']);
    expect(removed.scenarios.single.characterIds,isEmpty);
    removed.validate();
    final withoutPlace = removed.remove('places','palace',unlink:true);
    expect(withoutPlace.characters.first.homePlaceId,isNull);
    withoutPlace.validate();
  });

  test('Lore limits reject oversize fields and documents', () {
    expect(()=>BookLore(global:LoreGlobal(rules:'X'*12001)).validate(),
      throwsFormatException);
    final tooMany = BookLore(characters:[
      for(var i=0;i<=BookLore.maxEntriesPerSection;i++)
        LoreCharacter(id:'p$i',name:'Perso $i'),
    ]);
    expect(tooMany.validate,throwsFormatException);
    expect(()=>BookDefinition.importJson(' '*(BookDefinition.maxJsonBytes+1)),
      throwsFormatException);
  });

  test('Context priorities select accents and references, exclude irrelevant NPCs', () {
    final builder = LoreContextBuilder(maxCharacters:2200);
    final context = builder.build(testLore,['Je rencontre Eloise au palais.']);
    expect(context,contains('Érévia'));
    expect(context,contains('La magie a un prix'));
    expect(context,contains('Éloïse'));
    expect(context,contains('Palais d’Érévia'));
    expect(context,isNot(contains('Il vit loin du royaume')));
    expect(context,contains('pas des faits déjà accomplis'));
    expect(context,contains('SECRETS DU NARRATEUR'));
  });

  test('Local Lore budget cannot fail only because its omission notice is long', () {
    final lore = BookLore(
      global: const LoreGlobal(
        universe: 'Les Marches de Verre',
        rules: 'Les secrets restent secrets et les choix sont au joueur.',
      ),
      characters: const [
        LoreCharacter(id: 'oren', name: 'Oren',
          description: 'Aubergiste qui connaît le pont.',
          secrets: 'Il détient une clé de cuivre.'),
      ],
      scenarios: const [
        LoreScenario(id: 'missing', name: 'Voyageur disparu',
          summary: 'Un voyageur a disparu hier soir.',
          importance: LoreScenarioImportance.main),
      ],
      events: const [
        LoreEvent(id: 'registry', name: 'Registre des voyageurs',
          trigger: LoreEventTrigger.conditional,
          condition: 'Uniquement si le joueur demande le registre.',
          description: 'Oren révèle une page du registre.',
          scenarioIds: ['missing']),
      ],
    );
    final full = const LoreContextBuilder(maxCharacters: 10000)
        .build(lore, ['Je demande à Oren ce qui est arrivé.']);
    final eventStart = full.indexOf('ÉVÉNEMENT POTENTIEL — Registre des voyageurs');
    expect(eventStart, greaterThan(0));
    // The main plot fits, the event does not, and no complete explanation
    // can fit unless the selector shortens the warning or drops optional data.
    final partial = LoreContextBuilder(maxCharacters: eventStart + 5)
        .build(lore, ['Je demande à Oren ce qui est arrivé.']);
    expect(partial, contains('CANON DU MONDE'));
    expect(partial, contains('PERSONNAGE CANONIQUE — Oren'));
    expect(partial, contains('LORE PARTIEL'));
    expect(partial, isNot(contains('ÉVÉNEMENT POTENTIEL — Registre')));
    expect(partial.length, lessThanOrEqualTo(eventStart + 5));
  });

  test('Conditional story events are always possibilities, never marked done', () {
    final context = const LoreContextBuilder(maxCharacters:7000)
        .build(testLore,['Je trouve un passage secret. Ancien prisonnier.']);
    expect(context,contains('Condition NON vérifiée'));
    expect(context,contains('Si le joueur trouve le passage secret.'));
    expect(context,contains('Description (pas une réalisation constatée)'));
    expect(context,contains('Ne jamais imposer une action du joueur'));
  });

  test('Mandatory global facts never truncate silently', () {
    const lore = BookLore(global:LoreGlobal(
      universe:'Monde',rules:'Faits canoniques à respecter.'));
    expect(()=>const LoreContextBuilder(maxCharacters:50)
        .build(lore,['Monde']),throwsFormatException);
  });

  test('Only RAW narrator sees lore; JSONifier and RAW persistence unchanged',
      () async {
    final provider = _FakeProvider();
    final chat = NarrativeChatController(
      provider:provider,configuration:()=>config,
      loreProvider:()=>testLore,loreContextBudget:8000,
    );
    addTearDown(chat.dispose);
    await chat.send('Je vois le palais et Éloïse.');
    expect(chat.error,isNull);
    expect(provider.calls,hasLength(2));
    expect(provider.calls.first.first.content,contains('Érévia'));
    expect(provider.calls.first.first.content,contains('Éloïse'));
    expect(provider.calls.last.first.content,isNot(contains('Érévia')));
    expect(provider.calls.last.first.content,contains('JSONificateur'));
    expect(chat.rawGenerations.single.rawText,'Le palais s’illumine.');
    expect(chat.rawGenerations.single.isStructured,true);
  });

  test('SQLite reopening preserves lore and independent session timelines',
      () async {
    final temp = await Directory.systemTemp.createTemp('domolia-lore-');
    final file = '${temp.path}/lore.sqlite';
    final first = SqliteBookStore(
      factory:databaseFactoryFfi,databasePath:file);
    addTearDown(() async {
      await first.close();
      await temp.delete(recursive:true);
    });
    const bookA = BookDefinition(id:'a',title:'Monde A',lore:testLore);
    const bookB = BookDefinition(id:'b',title:'Monde B');
    await first.putBook(bookA);
    await first.putBook(bookB);
    const session = BookSession(id:'s',bookId:'b',title:'Partie B',
      timeline:[ChatEntry(id:0,speaker:ChatSpeaker.player,
        name:'Vous',text:'Premier tour')]);
    await first.putSession(session);
    await first.close();
    final reopened = SqliteBookStore(
      factory:databaseFactoryFfi,databasePath:file);
    addTearDown(reopened.close);
    expect((await reopened.findBook('a'))!.lore.scenarios.single.name,
      'Prince disparu');
    await reopened.putBook(bookA.copyWith(lore:
      testLore.copyWith(global:const LoreGlobal(universe:'Monde corrigé'))));
    expect((await reopened.findBook('b'))!.lore.isEmpty,true);
    expect((await reopened.findSession('s'))!.timeline.single,
      isA<ChatEntry>());
  });
}
