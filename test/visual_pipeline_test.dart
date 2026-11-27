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
  String? response;

  @override
  Future<List<AiModel>> listModels(AiConfiguration config) async => const [];

  @override
  Future<String> complete(AiConfiguration config, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) async {
    this.messages = messages;
    if (response != null) return response!;
    return jsonEncode({
      'prompt': 'Naëlle, jeune femme adulte aux cheveux noirs très longs, '
          'porte une jupe sombre et des collants noirs. Elle est accroupie '
          'sur le parquet sombre de l’atelier, genoux pliés, main droite '
          'appuyée au sol, main gauche saisissant un tissu près de sa '
          'cuisse. Le geste est net et les doigts touchent le tissu. '
          'Vue de trois quarts, plan moyen en pied, lumière dramatique.',
      'negativePrompt': 'texte, sous-titres',
      'appearances': [{
        'id': 'naelle',
        'identity': 'Femme adulte, cheveux noirs très longs',
        'current': 'Jupe sombre et collants noirs, accroupie',
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
       const VisualDirection(
         prompt:'Un dossier scellé est posé au centre d’un bureau, '
             'dans une pièce faiblement éclairée, cadrage de face.',
       ));
    expect(prompt,contains('dossier scellé est posé'));
  });

  test('Only the authored prompt is transmitted, and cast IDs are checked',
      () {
    final selected=const VisualSceneSelector().select(
        intent:intent,timeline:scene(),lore:lore);
    Map<String,dynamic> direction() => {
      'prompt': 'Léa Monel, femme adulte aux cheveux roux, vêtue de vert, '
          'se trouve près de Soren devant un meuble à tiroirs. '
          'Vue à hauteur des yeux, lumière douce.',
      'appearances': [{
        'id':'lea-monel',
        'identity':'Femme adulte aux cheveux roux',
        'current':'Tenue verte et posture debout',
      }],
    };
    final parsed=VisualDirection.parse(jsonEncode(direction()),selected);
    expect(parsed.appearances.single.id,'lea-monel');
    expect(validatedImagePrompt(selected,parsed),startsWith(parsed.prompt));
    expect(validatedImagePrompt(selected,parsed),
        contains('illustration cinématographique'));
    expect(parsed.prompt,isNot(contains('Personnage lea-monel')));
    expect(VisualDirection.parse(jsonEncode(
       direction()..['appearances']=[{
         'id':'party:inconnue',
         'identity':'Cheveux roux','current':'Tenue verte',
       }]),selected).appearances, isEmpty);
    expect(()=>VisualDirection.parse(jsonEncode(
       direction()..['unverifiedProp']='key'),selected),throwsFormatException);
  });


  test('Director keeps image prompt when appearance proposals are invalid', () {
    const currentIntent = ChatIllustrationIntent(
      id: 3, playerEventId: 1, description: 'Maëlle se tient face au joueur.');
    const events = <ChatTimelineEvent>[
      ChatEntry(id: 1, speaker: ChatSpeaker.character,
          name: 'Maëlle', text: 'Bonjour.'),
      ChatEntry(id: 2, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Elle est face au joueur.'),
      currentIntent,
    ];
    final scene = const VisualSceneSelector().select(
      intent: currentIntent, timeline: events, lore: const BookLore());
    final parsed = VisualDirection.parse(jsonEncode({
      'prompt': 'Maëlle, adulte aux cheveux noirs, est debout en face '
          'du joueur dans un couloir. Plan moyen, lumière douce.',
      'appearances': [
        {
          'id': 'party:maelle',
          'identity': 'Une grande femme aux cheveux noirs. ' +
              List.filled(12, 'Visage anguleux aux yeux clairs. ').join(),
          'current': 'Veste de travail anthracite. ' +
              List.filled(8, 'Elle reste debout près de la porte. ').join(),
        },
        {
          'id': 'party:missing',
          'identity': 'Inconnue',
          'current': 'Tenue inconnue',
        },
        {
          'id': 'party:maelle',
          'identity': 'Doublon',
          'current': 'Doublon',
        },
      ],
    }), scene);
    expect(parsed.prompt, contains('Maëlle, adulte'));
    expect(parsed.appearances, hasLength(1));
    expect(parsed.appearances.single.id, 'party:maelle');
    expect(parsed.appearances.single.identity.length, greaterThan(250));
    final invalidMetadata = VisualDirection.parse(jsonEncode({
      'prompt': parsed.prompt,
      'appearances': 'not a list',
    }), scene);
    expect(invalidMetadata.appearances, isEmpty);
    expect(invalidMetadata.prompt, parsed.prompt);
    expect(VisualDirection.parse(jsonEncode({
      'prompt': parsed.prompt,
      'appearances': [
        {'id': 'party:maelle', 'identity': 'x' * 900, 'current': 'Veste'},
      ],
    }), scene).appearances, isEmpty);
  });

  test('Earlier speakers are historical context, not the visible cast', () {
    final timeline = <ChatTimelineEvent>[
      const ChatEntry(id: 1, speaker: ChatSpeaker.character,
          name: 'Élodie', text: 'Je te laisse passer.'),
      const ChatEntry(id: 2, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Élodie s’éloigne du couloir.'),
      for (var i = 3; i <= 13; i++)
        ChatEntry(id: i, speaker: ChatSpeaker.narrator,
            name: 'Narrateur', text: 'Le couloir reste calme.'),
      const ChatEntry(id: 14, speaker: ChatSpeaker.character,
          name: 'Maëlle', text: 'Je suis ici.'),
      const ChatEntry(id: 15, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Maëlle est face au joueur.'),
      const ChatIllustrationIntent(id: 16, playerEventId: 8,
          description: 'Maëlle, debout devant le joueur.'),
    ];
    final selected = const VisualSceneSelector().select(
      intent: timeline.last as ChatIllustrationIntent,
      timeline: timeline, lore: const BookLore());
    expect(selected.partyCharacters.keys, contains('party:maelle'));
    expect(selected.partyCharacters.keys, isNot(contains('party:elodie')));
    expect(selected.evidence, isNot(contains('party:elodie')));
  });

  test('Director JSON fences are accepted without admitting extra text', () {
    final selected = const VisualSceneSelector().select(
      intent:intent, timeline:scene(), lore:lore,
    );
    final values = <String,dynamic>{
      'prompt': 'Léa Monel se tient devant le meuble à tiroirs, '
          'dans un intérieur éclairé. Sa main repose sur la poignée.',
      'negativePrompt': 'texte, watermark',
    };
    final raw = jsonEncode(values);
    final fenced = '```json\n$raw\n```';
    expect(VisualDirection.parse(raw, selected).prompt, values['prompt']);
    expect(VisualDirection.parse(fenced, selected).prompt, values['prompt']);
    expect(VisualDirection.parse(' ```JSON\r\n$raw\r\n``` ', selected)
        .negativePrompt, 'texte, watermark');
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

  test('Book exclusions remain out of the positive image prompt', () {
    final selected=const VisualSceneSelector().select(
        intent:intent,timeline:scene(),lore:lore);
    const director=VisualDirection(
      prompt:'Soren ferme un tiroir sur un meuble en bois. '
          'Sa main serre la poignée, avec une lumière de gravure sombre.',
      negativePrompt:'filigranes');
    final prompt=validatedImagePrompt(selected,director,
      style:'gravure sombre',
      negativePrompt:'sous-titres, textes');
    expect(prompt,startsWith(director.prompt));
    expect(prompt,contains('gravure sombre'));
    expect(prompt, isNot(contains('À exclure :')));
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
      'prompt':'Soren, adulte portant une veste sombre, '
          'ferme un tiroir sur un meuble en bois, vue de côté.',
    };
    final good=VisualDirection.parse(jsonEncode(data),selected);
    final prompt=validatedImagePrompt(selected,good);
    expect(prompt,isNot(contains('Le train est en retard')));
    expect(prompt,isNot(contains('Mémoire confirmée')));
    expect(()=>VisualDirection.parse(jsonEncode(
      {...data,'prompt':'Soren parle : Le train est en retard '
          'depuis ce matin. Le décor est un meuble.'}),
      selected),throwsFormatException);
    expect(()=>VisualDirection.parse(jsonEncode(
      {...data,'prompt':'[NARRATION] Soren ferme son tiroir.'}),
      selected),throwsFormatException);
    expect(()=>VisualDirection.parse(jsonEncode(
      {...data,'prompt':'x' * 6001}),selected),throwsFormatException);
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
      'prompt':'La gardienne reste immobile à côté d’une porte ancienne, '
          'dans un couloir sombre, avec une lumière venant de profil.',
    };
    final direction=VisualDirection.parse(jsonEncode(data),selected);
    expect(validatedImagePrompt(selected,direction),
      contains('La gardienne reste immobile'));
    expect(direction.prompt, contains('porte ancienne'));
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
      'prompt':'Une boulangère adulte aux cheveux bruns et aux yeux verts '
          'ajuste son tablier beige et son collier cyan près du comptoir '
          'd’une boulangerie. Ses mains tiennent le tissu, vue de face.',
      'appearances':[{
        'id':'party:boulangere',
        'identity':'Cheveux bruns et yeux verts',
        'current':'Tablier beige et collier cyan',
      }],
    }), scene);
    final prompt = validatedImagePrompt(scene, direction);
    expect(prompt, contains('cheveux bruns et aux yeux verts'));
    expect(prompt, isNot(contains('Apparence de')));
    expect(direction.appearances.single.identity,
        'Cheveux bruns et yeux verts');
    expect(VisualDirection.parse(jsonEncode({
      'prompt':'Une boulangère adulte se tient derrière un comptoir '
          'de cuisine et ajuste son tablier.',
      'appearances':[{
        'id':'party:inconnue',
        'identity':'Cheveux bruns', 'current':'Tablier blanc',
      }],
    }), scene).appearances, isEmpty);
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
          description: 'Femme adulte de 32 ans, silhouette élancée',
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
        id: 'later-same-turn', category: 'character', entityId: 'naelle',
        label: 'Naëlle', field: 'visual_current', text: 'Veste orange enfilée après le geste',
        kind: 'state', certainty: 'confirmed', visibility: 'player',
        importance: 4, sourceTurnId: 9, sourceSide: 'raw', sourceQuote: 'Elle se redresse.',
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
    expect(selected.evidence, contains('32 ans, silhouette élancée'));
    expect(selected.evidence, contains('Collants noirs et jupe sombre'));
    expect(selected.evidence, contains('parquet sombre'));
    expect(selected.evidence, isNot(contains('Manteau rouge')));
    expect(selected.evidence, isNot(contains('Veste orange')));
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

  test('Director writes a detailed visual prompt with scene continuity',
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
      style: 'aquarelle délicate', negativePrompt: 'texte incrusté',
      connection: const AiConfiguration(
        baseUrl: 'https://example.org/v1', model: 'fake', apiKey: 'fake'),
    );
    expect(provider.messages, hasLength(2));
    expect(provider.messages.first.content,contains('âge apparent'));
    expect(provider.messages.first.content,contains('cheveux'));
    expect(provider.messages.first.content,contains('contacts physiques'));
    expect(provider.messages.first.content,contains('300 à 700 caractères'));
    expect(provider.messages.first.content,contains('QUI touche QUOI'));
    expect(provider.messages.first.content,contains('cadrage'));
    expect(provider.messages.last.content,
      contains('INSTANT À ILLUSTRER (prioritaire)'));
    expect(provider.messages.last.content, contains('Tour : Narrateur'));
    expect(provider.messages.last.content, contains('aquarelle délicate'));
    expect(provider.messages.last.content, contains('texte incrusté'));
    expect(direction.appearances.single.id,'naelle');
    final prompt = validatedImagePrompt(selected, direction);
    expect(prompt, startsWith(direction.prompt));
    expect(prompt, contains('main droite'));
    expect(prompt, contains('main gauche'));
    expect(prompt, contains('main gauche saisissant un tissu'));
    expect(prompt, contains('parquet sombre de l’atelier'));
    expect(prompt, isNot(contains('ACTION PRIORITAIRE')));
    expect(prompt, isNot(contains('Personnage naelle')));
    expect(prompt, isNot(contains('Je regarde Naëlle s’accroupir.')));
    expect(prompt, isNot(contains('À exclure :')));
    expect(VisualDirection.parse(jsonEncode({
      'prompt': 'Naëlle se tient sur le parquet sombre et '
          'porte une jupe et des collants.',
      'appearances': [{
        'id': 'not-allowed',
        'identity': 'Cheveux noirs',
        'current': 'Jupe sombre',
      }],
    }), selected).appearances, isEmpty);
  });


  test('Director favors a blank background for a manga character closeup',
      () async {
    final provider = _RecordingDirectorProvider()
      ..response = jsonEncode({
        'prompt':'Mila, femme adulte aux cheveux roux courts et '
            'aux yeux verts, sourit avec malice et lève une main. '
            'Gros plan à hauteur des yeux, fond blanc sans décor.',
      });
    const subject = ChatIllustrationIntent(
      id: 2, playerEventId: 1,
      description: 'Mila sourit et lève une main.',
    );
    final selected = const VisualSceneSelector().select(
      intent: subject,
      timeline: const [
        ChatEntry(id: 1, speaker: ChatSpeaker.narrator,
          name: 'Narrateur', text: 'Mila sourit et lève une main.'),
        subject,
      ],
      lore: const BookLore(characters: [
        LoreCharacter(id: 'mila', name: 'Mila',
            appearance: 'Femme adulte, cheveux roux courts, yeux verts'),
      ]),
    );
    final result = await const VisualDirector().direct(
      scene: selected, provider: provider,
      style: 'manga noir et blanc',
      connection: const AiConfiguration(
          baseUrl: 'https://example.org/v1', model: 'fake', apiKey: 'fake'),
    );
    final instructions = provider.messages.first.content;
    expect(instructions, contains('fond blanc'));
    expect(instructions, contains('style manga'));
    expect(instructions, contains('En style réaliste'));
    expect(instructions, contains('ne remplis JAMAIS'));
    expect(instructions, contains('caractéristiques physiques nécessaires'));
    expect(provider.messages.last.content,
        contains('Femme adulte, cheveux roux courts, yeux verts'));
    expect(provider.messages.last.content, contains('manga noir et blanc'));
    final prompt = validatedImagePrompt(selected, result,
        style:'manga noir et blanc');
    expect(prompt, contains('fond blanc sans décor'));
    expect(prompt, isNot(contains('salon')));
    expect(prompt, isNot(contains('parquet')));
    expect(prompt, isNot(contains('fenêtre')));
    expect(prompt, contains('manga noir et blanc'));
  });

  test('Director preserves only needed location anchors for a doorway',
      () async {
    final provider = _RecordingDirectorProvider()
      ..response = jsonEncode({
        'prompt': 'Une voisine adulte aux cheveux courts se tient '
            'sur le palier intérieur, devant la porte ouverte '
            'de l’appartement. Un encadrement simple la situe, '
            'le reste de l’arrière-plan est blanc et neutre.',
      });
    const illustration = ChatIllustrationIntent(
      id: 2, playerEventId: 1,
      description: 'La voisine attend sur le palier devant la porte ouverte.',
    );
    final selected = const VisualSceneSelector().select(
      intent: illustration,
      timeline: const [
        ChatEntry(id: 1, speaker: ChatSpeaker.narrator,
          name: 'Narrateur',
          text: 'La voisine attend sur le palier devant la porte ouverte.'),
        illustration,
      ],
      lore: const BookLore(),
    );
    final result = await const VisualDirector().direct(
      scene: selected, provider: provider,
      connection: const AiConfiguration(
          baseUrl: 'https://example.org/v1', model: 'fake', apiKey: 'fake'),
    );
    final instructions = provider.messages.first.content;
    expect(instructions, contains('une porte et son encadrement'));
    expect(instructions,
        contains('Un palier d’immeuble ne doit pas devenir un porche extérieur'));
    final prompt = validatedImagePrompt(selected, result);
    expect(prompt, contains('palier intérieur'));
    expect(prompt, contains('encadrement simple'));
    expect(prompt, isNot(contains('porche extérieur')));
    expect(prompt, isNot(contains('carrelage')));
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
