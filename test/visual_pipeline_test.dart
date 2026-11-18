// ignore_for_file: prefer_interpolation_to_compose_strings, curly_braces_in_flow_control_structures
import 'dart:convert';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/books/book_lore.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/illustration/visual_pipeline.dart';
import 'package:domolia/memory/live_memory.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingDirectorProvider implements AiChatProvider {
  List<AiMessage> messages = const [];

  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => const [];

  @override
  Future<String> complete(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) async {
    this.messages = messages;
    return jsonEncode({
      'shot': 'medium_full',
      'angle': 'three_quarter',
      'focusIds': ['naelle'],
      'composition': 'leading_lines',
      'lighting': 'dramatic',
      'palette': 'muted',
      'mood': 'tense',
      'visualSubject': 'Naëlle près du sol',
      'visualAction': 'Naëlle saisit un tissu près de sa cuisse',
      'visualSetting': 'Parquet sombre de l’atelier',
      'bodyPose': 'Main droite au sol, genoux pliés, main gauche au tissu',
      'mustShow': ['Main droite appuyée au sol', 'Main gauche au tissu'],
      'appearances': [{
        'id': 'naelle',
        'identity': 'Cheveux noirs longs',
        'current': 'Jupe sombre et collants noirs',
      }],
    });
  }
}

void main() {
  const intent = ChatIllustrationIntent(
      id:4,playerEventId:1,description:'Soren referme le tiroir.');
  const lore=BookLore(characters:[
    LoreCharacter(id:'lea-monel',name:'Léa Monel',
        appearance:'Cheveux roux, vêtement vert'),
    LoreCharacter(id:'lea-monnel',name:'Léa Monnel',
        appearance:'Cheveux noirs, vêtement bleu'),
  ]);
  List<ChatTimelineEvent> scene() => [
    const ChatEntry(id:1,speaker:ChatSpeaker.player,name:'Vous',
        text:'Je regarde Léa Monel.'),
    const ChatEntry(id:2,speaker:ChatSpeaker.narrator,name:'Narrateur',
        text:'Soren referme lentement le tiroir derrière lui.'),
    intent,
    const ChatEntry(id:5,speaker:ChatSpeaker.narrator,name:'Narrateur',
        text:'La clé est révélée une heure plus tard.'),
  ];

  test('Visual scene freezes historical position and only exact person', () {
    final selected=const VisualSceneSelector().select(
        intent:intent,timeline:scene(),lore:lore);
    expect(selected.intentId,4);
    expect(selected.excerpts.join(' '),contains('tiroir'));
    expect(selected.excerpts.join(' '),isNot(contains('révélée')));
    expect(selected.characters.map((c)=>c.id), ['lea-monel']);
  });

  test('Lore rumors and conditional claims are never promoted', () {
    final lines=[
      const ChatEntry(id:1,speaker:ChatSpeaker.player,name:'Vous',
          text:'Le jeton n°62 proposé mais non accepté reste sur la table.'),
      const ChatEntry(id:2,speaker:ChatSpeaker.narrator,name:'Narrateur',
          text:'Une rumeur prétend que la gardienne du fanal a une clé.'),
      const ChatEntry(id:3,speaker:ChatSpeaker.narrator,name:'Narrateur',
          text:'Le dossier scellé repose sur le bureau.'),
      const ChatIllustrationIntent(id:4,playerEventId:1,
          description:'Scène du dossier scellé.'),
    ];
    final selected=const VisualSceneSelector().select(
      intent:lines.last as ChatIllustrationIntent,
      timeline:lines, lore:const BookLore(),
    );
    expect(selected.description,'Scène du dossier scellé.');
    expect(selected.restrictions,hasLength(3));
    expect(selected.excerpts,isEmpty);
    final prompt = validatedImagePrompt(selected,
       const VisualDirection(shot:'wide',angle:'eye_level',focusIds:[],
        composition:'centered',lighting:'natural',palette:'muted',
        mood:'mysterious',visualSubject:'Bureau',visualAction:'Dossier posé',
        visualSetting:'Une pièce'));
    expect(prompt,contains('Dossier posé'));
  });

  test('Director cannot add cast or arbitrary narrative fields', () {
    final selected=const VisualSceneSelector().select(
        intent:intent,timeline:scene(),lore:lore);
    Map<String,dynamic> direction() => {
      'shot':'medium','angle':'eye_level','focusIds':['lea-monel'],
      'composition':'rule_of_thirds','lighting':'soft',
      'palette':'warm','mood':'calm',
      'visualSubject':'Léa aux cheveux roux, vêtement vert',
      'visualAction':'Soren ferme un tiroir',
      'visualSetting':'Un meuble à tiroirs',
    };
    expect(VisualDirection.parse(jsonEncode(direction()),selected).focusIds,
        ['lea-monel']);
    expect(()=>VisualDirection.parse(jsonEncode(
       direction()..['focusIds']=['lea-monnel']),selected),throwsFormatException);
    expect(()=>VisualDirection.parse(jsonEncode(
       direction()..['unverifiedProp']='key'),selected),throwsFormatException);
    expect(validatedImagePrompt(selected,
       VisualDirection.parse(jsonEncode(direction()),selected)),
       isNot(contains('Cheveux noirs')));
  });


  test('Director JSON fences are accepted without admitting extra text', () {
    final selected = const VisualSceneSelector().select(
      intent:intent, timeline:scene(), lore:lore,
    );
    final values = <String,dynamic>{
      'shot':'medium_full', 'angle':'three_quarter',
      'focusIds':['lea-monel'], 'composition':'leading_lines',
      'lighting':'soft', 'palette':'warm', 'mood':'calm',
      'visualSubject':'Léa devant le meuble',
      'visualAction':'Elle touche le tiroir',
      'visualSetting':'Un intérieur avec un meuble',
      'bodyPose':'Sa main repose sur la poignée',
    };
    final raw = jsonEncode(values);
    final fenced = '```json\n$raw\n```';
    expect(VisualDirection.parse(raw, selected).shot, 'medium_full');
    expect(VisualDirection.parse(fenced, selected).shot, 'medium_full');
    expect(VisualDirection.parse(' ```JSON\r\n$raw\r\n``` ', selected)
        .angle, 'three_quarter');
    expect(() => VisualDirection.parse(
      'Explication :\n$fenced', selected), throwsFormatException);
    expect(() => VisualDirection.parse(
      '$fenced\nTexte supplémentaire', selected), throwsFormatException);
    expect(() => VisualDirection.parse(
      '```json\n{}\n```', selected), throwsFormatException);
    expect(() => VisualDirection.parse(
      '```json\n$raw\n```\n```json\n{}\n```',
      selected), throwsFormatException);
  });

  test('Director accepts a single Markdown JSON fence without prose', () {
    final selected = const VisualSceneSelector().select(
        intent: intent, timeline: scene(), lore: lore);
    final raw = jsonEncode({
      'shot': 'medium', 'angle': 'eye_level', 'focusIds': ['lea-monel'],
      'composition': 'centered', 'lighting': 'soft',
      'palette': 'warm', 'mood': 'calm',
      'visualSubject': 'Léa', 'visualAction': 'Ferme le tiroir',
      'visualSetting': 'Pièce éclairée',
    });
    expect(VisualDirection.parse('```json\\n$raw\\n```', selected).shot,
        'medium');
    expect(() => VisualDirection.parse(
        'Préambule\\n```json\\n$raw\\n```', selected),
        throwsFormatException);
  });

  test('Book exclusions are added without treating scene dialogue as overlay', () {
    final selected=const VisualSceneSelector().select(
        intent:intent,timeline:scene(),lore:lore);
    const director=VisualDirection(
      shot:'medium',angle:'eye_level',focusIds:[],
      composition:'centered',lighting:'soft',
      palette:'muted',mood:'calm',
      visualSubject:'Soren',visualAction:'Il ferme un tiroir',
      visualSetting:'Un meuble à tiroirs');
    final prompt=validatedImagePrompt(selected,director,
      style:'gravure sombre',
      negativePrompt:'sous-titres, textes, filigranes');
    expect(prompt,contains('gravure sombre'));
    expect(prompt,contains('À exclure : sous-titres'));
    expect(prompt,contains('Il ferme un tiroir'));
    expect(prompt,isNot(contains('Texte établi')));
    expect(prompt,isNot(contains('Je regarde Léa Monel')));
    expect(prompt,isNot(contains('Soren referme lentement le tiroir derrière lui.')));
    expect(()=>validatedImagePrompt(selected,director,
      negativePrompt:'x' * 1501),throwsFormatException);
  });

  test('Quoted dialogue is not accepted or injected in image prompt', () {
    final selected=const VisualSceneSelector().select(
      intent:intent,timeline:[
        const ChatEntry(id:2,speaker:ChatSpeaker.character,name:'Soren',
          text:'« Le train est en retard depuis ce matin. »'),
        intent,
      ],lore:lore);
    final data={
      'shot':'medium','angle':'eye_level',
      'focusIds':<String>[],'composition':'centered','lighting':'soft',
      'palette':'muted','mood':'calm','visualSubject':'Soren',
      'visualAction':'Ferme un tiroir','visualSetting':'Un meuble en bois',
    };
    final good=VisualDirection.parse(jsonEncode(data),selected);
    final prompt=validatedImagePrompt(selected,good);
    expect(prompt,isNot(contains('Le train est en retard')));
    expect(prompt,isNot(contains('Mémoire confirmée')));
    expect(()=>VisualDirection.parse(jsonEncode(
      {...data,'visualAction':'Le train est en retard depuis ce matin.'}),
      selected),throwsFormatException);
    // Backward-compatible: an old director response can include a veto
    // flag, but it is ignored as long as the camera JSON is valid.
    expect(VisualDirection.parse(jsonEncode(
      {...data,'illustratable':false}),selected).visualAction,
      'Ferme un tiroir');
    expect(()=>VisualDirection.parse(jsonEncode(
      {...data,'visualSetting':'a' * 401}),selected),throwsFormatException);
  });

  test('Every existing intent can be composed without director veto', () {
    final events = [
      const ChatEntry(id:1,speaker:ChatSpeaker.narrator,
          name:'Narrateur',text:'La gardienne attend près de la porte.'),
      const ChatIllustrationIntent(
          id:2,playerEventId:1,description:'Une porte mystérieuse.'),
    ];
    final selected=const VisualSceneSelector().select(
        intent:events.last as ChatIllustrationIntent,
        timeline:events,lore:const BookLore());
    final data={
      'shot':'wide','angle':'eye_level','focusIds':<String>[],
      'composition':'centered','lighting':'natural','palette':'muted',
      'mood':'mysterious','visualSubject':'La gardienne',
      'visualAction':'Elle reste immobile',
      'visualSetting':'Une porte',
    };
    final direction=VisualDirection.parse(jsonEncode(data),selected);
    expect(validatedImagePrompt(selected,direction),
      contains('Elle reste immobile'));
    expect(VisualDirection.parse(
      jsonEncode({...data,'illustratable':false}),selected).visualSubject,
      'La gardienne');
  });

  test('New Party characters receive proposed appearances without Book Lore', () {
    final timeline = <ChatTimelineEvent>[
      const ChatEntry(id:1, speaker:ChatSpeaker.character,
          name:'Boulangère', text:'Bonjour.'),
      const ChatEntry(id:2, speaker:ChatSpeaker.narrator,
          name:'Narrateur', text:'La boulangère ouvre son tablier.'),
      const ChatIllustrationIntent(id:3, playerEventId:1,
          description:'La boulangère près du comptoir.'),
    ];
    final scene = const VisualSceneSelector().select(
      intent:timeline.last as ChatIllustrationIntent,
      timeline:timeline, lore:const BookLore(),
    );
    expect(scene.partyCharacters['party:boulangere'], 'Boulangère');
    final direction = VisualDirection.parse(jsonEncode({
      'shot':'medium', 'angle':'eye_level',
      'focusIds':['party:boulangere'],
      'composition':'centered', 'lighting':'soft',
      'palette':'warm', 'mood':'calm',
      'visualSubject':'Une boulangère au comptoir',
      'visualAction':'Elle ajuste son tablier',
      'visualSetting':'Une boulangerie',
      'appearances':[{
        'id':'party:boulangere',
        'identity':'Cheveux bruns et yeux verts',
        'current':'Tablier beige et collier cyan',
      }],
    }), scene);
    final prompt = validatedImagePrompt(scene, direction);
    expect(prompt, contains('Apparence de Boulangère :'));
    expect(prompt, contains('Cheveux bruns et yeux verts'));
    expect(prompt, contains(' ; Tablier beige'));
    expect(() => VisualDirection.parse(jsonEncode({
      'shot':'medium', 'angle':'eye_level', 'focusIds':<String>[],
      'composition':'centered', 'lighting':'soft', 'palette':'warm',
      'mood':'calm', 'visualSubject':'Boulangère',
      'visualAction':'Elle attend', 'visualSetting':'Boulangerie',
      'appearances':[{
        'id':'party:inconnue',
        'identity':'Cheveux bruns', 'current':'Tablier blanc',
      }],
    }), scene), throwsFormatException);
  });

  test('Confirmed visual details survive a pronoun-only subsequent scene', () {
    final events = <ChatTimelineEvent>[
      const ChatEntry(id:1, speaker:ChatSpeaker.character,
          name:'Boulangère', text:'Bonjour.'),
      const ChatEntry(id:2, speaker:ChatSpeaker.narrator,
          name:'Narrateur', text:'Elle s’approche du comptoir.'),
      const ChatIllustrationIntent(id:3, playerEventId:1,
          description:'Elle ajuste sa tenue.'),
    ];
    final memory = <LiveMemoryFact>[
      const LiveMemoryFact(
        id:'visual:party:boulangere:identity',
        category:'character', entityId:'party:boulangere',
        label:'Boulangère', field:'visual_identity',
        text:'Cheveux bruns et yeux verts',
        kind:'stable', certainty:'confirmed', visibility:'player',
        importance:4, sourceTurnId:1,
        sourceSide:'manual', sourceQuote:'Apparence validée',
      ),
    ];
    final selected = const VisualSceneSelector().select(
      intent: events.last as ChatIllustrationIntent,
      timeline:events, lore:const BookLore(), memory:memory,
    );
    expect(selected.memoryFacts.join(' '),
        contains('Cheveux bruns et yeux verts'));
    expect(selected.evidence, contains('Boulangère (visual_identity)'));
  });


  test('Longer scene context includes Book visuals and prior confirmed memory',
      () {
    const bookLore = BookLore(
      global: LoreGlobal(universe: 'Une ville actuelle alternative',
        era: 'Présent alternatif', secrets: 'NE PAS RÉVÉLER'),
      characters: [
        LoreCharacter(id: 'naelle', name: 'Naëlle',
          appearance: 'Cheveux noirs très longs, teint clair',
          role: 'Visiteuse', secrets: 'Information jamais révélée'),
      ],
      places: [
        LorePlace(id: 'atelier', name: 'Pièce au parquet sombre',
          description: 'Pièce avec parquet, placard et fenêtre haute',
          features: 'Lattes de parquet sombres et placard fermé',
          secrets: 'Local secret'),
      ],
    );
    final events = <ChatTimelineEvent>[
      const ChatEntry(id: 1, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Naëlle entre dans la pièce au parquet sombre.'),
      const ChatEntry(id: 2, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Je reste près de la porte.'),
      const ChatEntry(id: 3, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Elle s’accroupit sur le parquet.'),
      const ChatEntry(id: 4, speaker: ChatSpeaker.character,
          name: 'Naëlle', text: 'Ce parquet est très froid.'),
      const ChatEntry(id: 5, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Sa main droite rejoint le sol.'),
      const ChatEntry(id: 6, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Je ne bouge pas.'),
      const ChatEntry(id: 7, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Son genou gauche reste plié.'),
      const ChatEntry(id: 8, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Un pli se forme dans le tissu.'),
      const ChatEntry(id: 9, speaker: ChatSpeaker.player,
          name: 'Vous', text: 'Je regarde ses gestes.'),
      const ChatEntry(id: 10, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Sa main gauche approche du tissu.'),
      const ChatEntry(id: 11, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Elle saisit délicatement le pli.'),
      const ChatIllustrationIntent(
          id: 12, playerEventId: 9,
          description: 'Naëlle saisit le pli du tissu de la main gauche.'),
      const ChatEntry(id: 13, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Elle se redresse plus tard.'),
    ];
    final memory = <LiveMemoryFact>[
      const LiveMemoryFact(
        id: 'mem-naelle', category: 'character', entityId: 'naelle',
        label: 'Naëlle', field: 'visual_current',
        text: 'Collants noirs et jupe sombre',
        kind: 'dynamic', certainty: 'confirmed', visibility: 'player',
        importance: 4, sourceTurnId: 7,
        sourceSide: 'manual', sourceQuote: 'Tenue confirmée',
      ),
      const LiveMemoryFact(
        id: 'future', category: 'character', entityId: 'naelle',
        label: 'Naëlle', field: 'visual_current',
        text: 'Manteau rouge aperçu seulement plus tard',
        kind: 'dynamic', certainty: 'confirmed', visibility: 'player',
        importance: 4, sourceTurnId: 20,
        sourceSide: 'manual', sourceQuote: 'Fait futur',
      ),
    ];
    final selected = const VisualSceneSelector().select(
      intent: events[11] as ChatIllustrationIntent,
      timeline: events, lore: bookLore, memory: memory,
    );
    expect(selected.excerpts, hasLength(10));
    expect(selected.chronology.join(' '), contains('Joueur'));
    expect(selected.chronology.join(' '), contains('Sa main droite rejoint'));
    expect(selected.characters.single.id, 'naelle');
    expect(selected.places.single.id, 'atelier');
    expect(selected.evidence, contains('Cheveux noirs très longs'));
    expect(selected.evidence, contains('Collants noirs et jupe sombre'));
    expect(selected.evidence, contains('parquet sombre'));
    expect(selected.evidence, isNot(contains('Manteau rouge')));
    expect(selected.evidence, isNot(contains('Elle se redresse plus tard')));
    expect(selected.evidence, isNot(contains('NE PAS RÉVÉLER')));
    expect(selected.evidence, isNot(contains('Local secret')));
  });

  test('Latest motion survives truncation of a very long narrator turn', () {
    const intent = ChatIllustrationIntent(
      id: 9, playerEventId: 1,
      description: 'Elle déplace une main sous son bras.');
    final timeline = <ChatTimelineEvent>[
      ChatEntry(id: 1, speaker: ChatSpeaker.narrator,
        name: 'Narrateur',
        text: 'Dans la salle au parquet. ' +
            ('Des détails de décor et de dialogue. ' * 50) +
            'Finalement la main gauche se glisse sous l’avant-bras droit.'),
      intent,
    ];
    final selected = const VisualSceneSelector().select(
      intent: intent, timeline: timeline, lore: const BookLore(),
    );
    expect(selected.chronology.single,
        contains('Dans la salle au parquet'));
    expect(selected.chronology.single,
        contains('main gauche se glisse sous l’avant-bras droit'));
    expect(selected.chronology.single.length, lessThan(650));
  });

  test('Director uses the exact action, body geometry and must-show details',
      () async {
    final provider = _RecordingDirectorProvider();
    const bookLore = BookLore(characters: [
      LoreCharacter(id: 'naelle', name: 'Naëlle',
        appearance: 'Cheveux noirs très longs'),
    ]);
    const event = ChatIllustrationIntent(
      id: 4, playerEventId: 1,
      description: 'Naëlle attrape le tissu de sa main gauche.');
    final selected = const VisualSceneSelector().select(
      intent: event,
      timeline: const [
        ChatEntry(id: 1, speaker: ChatSpeaker.player, name: 'Vous',
          text: 'Je regarde Naëlle s’accroupir.'),
        ChatEntry(id: 2, speaker: ChatSpeaker.narrator, name: 'Narrateur',
          text: 'Naëlle pose la main droite au sol.'),
        event,
      ],
      lore: bookLore,
    );
    final direction = await const VisualDirector().direct(
      scene: selected, provider: provider,
      connection: const AiConfiguration(
        baseUrl: 'https://example.org/v1', model: 'fake', apiKey: 'fake'),
    );
    expect(provider.messages, hasLength(2));
    expect(provider.messages.last.content,
      contains('INSTANT À ILLUSTRER (prioritaire)'));
    expect(provider.messages.last.content, contains('Tour : Narrateur'));
    expect(direction.shot, 'medium_full');
    expect(direction.angle, 'three_quarter');
    expect(direction.mustShow, hasLength(2));
    final prompt = validatedImagePrompt(selected, direction);
    expect(prompt, contains('Main droite au sol'));
    expect(prompt, contains('Main gauche au tissu'));
    expect(prompt.indexOf('Naëlle saisit un tissu'),
        lessThan(prompt.indexOf('Parquet sombre de l’atelier')));
    expect(prompt, isNot(contains('ACTION PRIORITAIRE')));
    expect(prompt, isNot(contains('Personnage naelle')));
    expect(prompt.length, lessThan(800));
    expect(prompt, isNot(contains('Je regarde Naëlle s’accroupir.')));
    expect(() => VisualDirection.parse(jsonEncode({
      'shot': 'medium_full', 'angle': 'three_quarter',
      'focusIds': ['naelle'],
      'composition': 'centered', 'lighting': 'soft',
      'palette': 'muted', 'mood': 'calm',
      'visualSubject': 'Naëlle', 'visualAction': 'Elle saisit le tissu',
      'visualSetting': 'Une pièce',
      'bodyPose': 'Position stable',
      'mustShow': ['x' * 181],
    }), selected), throwsFormatException);
  });

  test('Rewind removes source and changes hash of same ID', () {
    final selected=const VisualSceneSelector().select(
        intent:intent,timeline:scene(),lore:lore);
    final altered=[
      const ChatEntry(id:1,speaker:ChatSpeaker.player,name:'Vous',
          text:'Je m’éloigne du quai.'),
      ...scene().skip(1),
    ];
    final replacement=const VisualSceneSelector().select(
        intent:intent,timeline:altered,lore:lore);
    expect(replacement.sourceHash,isNot(selected.sourceHash));
    expect(()=>const VisualSceneSelector().select(
        intent:intent,timeline:scene().take(2).toList(),lore:lore),
        throwsStateError);
  });
}
