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
    expect(selected.description,isEmpty);
    expect(selected.restrictions,hasLength(4));
    expect(selected.excerpts,isEmpty);
    expect(()=>validatedImagePrompt(selected,
       const VisualDirection(shot:'wide',angle:'eye_level',focusIds:[],
        composition:'centered',lighting:'natural',palette:'muted',
        mood:'mysterious')),throwsFormatException);
  });

  test('Director cannot add cast or arbitrary narrative fields', () {
    final selected=const VisualSceneSelector().select(
        intent:intent,timeline:scene(),lore:lore);
    Map<String,dynamic> direction() => {
      'shot':'medium','angle':'eye_level','focusIds':['lea-monel'],
      'composition':'rule_of_thirds','lighting':'soft',
      'palette':'warm','mood':'calm',
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
