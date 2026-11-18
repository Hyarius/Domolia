// ignore_for_file: prefer_interpolation_to_compose_strings, curly_braces_in_flow_control_structures
import 'dart:convert';

import 'package:domolia/books/book_lore.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/illustration/visual_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

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
    expect(prompt,contains('Action visible : Dossier posé'));
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
    expect(prompt,contains('Style graphique : gravure sombre'));
    expect(prompt,contains('EXCLUSIONS VISUELLES : sous-titres'));
    expect(prompt,contains('sans bulles'));
    expect(prompt,contains('Action visible : Il ferme un tiroir'));
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
      contains('Action visible : Elle reste immobile'));
    expect(VisualDirection.parse(
      jsonEncode({...data,'illustratable':false}),selected).visualSubject,
      'La gardienne');
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
