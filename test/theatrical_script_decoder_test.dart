import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/theatrical_script_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

List<ChatOutputEvent> parse(String source, {int chunkSize = 1}) {
  final decoder = TheatricalScriptDecoder();
  final output = <ChatOutputEvent>[];
  for (var i = 0; i < source.length; i += chunkSize) {
    final end = i + chunkSize < source.length ? i + chunkSize : source.length;
    output.addAll(decoder.add(source.substring(i, end)));
  }
  output.addAll(decoder.finish());
  return output;
}

void main() {
  test('split markers, stage directions, dialogue and scene changes', () {
    final events = parse(
      '[NARRATION]\nLa pluie tombe.\n'
      '[PERSONNAGE:Tomas|méfiant]\n« Bonsoir. »\n'
      '[SCENE]\n[NARRATION]\nLa rue est vide.',
    );
    expect(events, hasLength(4));
    final stage = events[0] as ChatLine;
    expect(stage.speaker, ChatSpeaker.narrator);
    expect(stage.text, 'La pluie tombe.');
    final dialogue = events[1] as ChatLine;
    expect(dialogue.speaker, ChatSpeaker.character);
    expect(dialogue.name, 'Tomas');
    expect(dialogue.status, 'méfiant');
    expect(dialogue.text, '« Bonsoir. »');
    expect(events[2], isA<ChatSceneChangeOutput>());
    expect((events[3] as ChatLine).text, 'La rue est vide.');
  });

  test('new script headers stay hidden while streaming and retain the voice', () {
    final decoder = TheatricalScriptDecoder();
    decoder.add('@L');
    expect(decoder.preview, isNull);
    decoder.add('iv|surprise\nVraiment ?');
    expect(decoder.preview!.name, 'Liv');
    final events = [...decoder.add('\n*\nElle plie la lettre.\n---\n*\nLe matin.'), ...decoder.finish()];
    expect((events.first as ChatLine).status, 'surprise');
    expect((events[1] as ChatLine).speaker, ChatSpeaker.narrator);
    expect(events[2], isA<ChatSceneChangeOutput>());
    expect((events.last as ChatLine).text, 'Le matin.');
  });

  test('unmarked stage direction after a quoted PNJ line is narration', () {
    final events = parse(
      '[PERSONNAGE:Léa Monel|essoufflée]\n'
      '« Soren ? On m’a rapporté quelque chose. »\n\n'
      'Elle garde une main sur sa sacoche, hésitant à l’ouvrir.',
      chunkSize: 1,
    );
    expect(events, hasLength(2));
    expect((events[0] as ChatLine).speaker, ChatSpeaker.character);
    expect((events[0] as ChatLine).name, 'Léa Monel');
    expect((events[0] as ChatLine).text, '« Soren ? On m’a rapporté quelque chose. »');
    expect((events[1] as ChatLine).speaker, ChatSpeaker.narrator);
    expect((events[1] as ChatLine).text,
        'Elle garde une main sur sa sacoche, hésitant à l’ouvrir.');
  });

  test('separate quoted paragraphs stay the same character', () {
    final events = parse(
      '[PERSONNAGE:Léa Monel]\n« Une première nouvelle. »\n\n'
      '« Et une seconde nouvelle. »',
      chunkSize: 2,
    );
    expect(events, hasLength(1));
    expect((events.single as ChatLine).speaker, ChatSpeaker.character);
    expect((events.single as ChatLine).text, contains('seconde nouvelle'));
  });

  test('preview hides incomplete headers and exposes partial dialogue', () {
    final decoder = TheatricalScriptDecoder();
    decoder.add('[PERSONN');
    expect(decoder.preview, isNull);
    decoder.add('AGE:Tomas]\nBon');
    expect(decoder.preview!.speaker, ChatSpeaker.character);
    expect(decoder.preview!.name, 'Tomas');
    expect(decoder.preview!.text, 'Bon');
    decoder.add('soir !');
    expect(decoder.preview!.text, 'Bonsoir !');
    expect((decoder.finish().single as ChatLine).text, 'Bonsoir !');
  });

  test('ordinary prose is one narrator block without invented attribution', () {
    final events = parse(
      "L'homme soutient votre regard un instant.\r\n"
      '\r\n— Vous aussi, répond Tomas, avez-vous remarqué l’horloge ?',
    );
    expect(events, hasLength(1));
    expect((events.single as ChatLine).speaker, ChatSpeaker.narrator);
    expect((events.single as ChatLine).text, contains('répond Tomas'));
  });

  test('inline scene headers work even when fragmented', () {
    final events = parse(
      '[NARRATION] Un volet claque.\n'
      '[PERSONNAGE : Éline Varre] Je vous attendais.',
      chunkSize: 3,
    );
    expect(events.whereType<ChatLine>(), hasLength(2));
    expect((events.last as ChatLine).name, 'Éline Varre');
  });

  test('legacy NDJSON is rejected, not interpreted or displayed as prose', () {
    expect(
      () => parse(
        '{"type":"message","speaker":"narrator",'
        '"name":"Narrateur","text":"La porte s’ouvre."}\n',
      ),
      throwsFormatException,
    );
    final decoder = TheatricalScriptDecoder();
    decoder.add('{');
    expect(decoder.preview, isNull);
  });

  test('mixed theatrical and JSON output is rejected', () {
    expect(
      () => parse(
        '[NARRATION]\nBonjour.\n'
        '{"type":"message","speaker":"narrator",'
        '"name":"Narrateur","text":"Test"}\n',
      ),
      throwsFormatException,
    );
  });

  test('the narrator cannot impersonate the player', () {
    for (final speaker in [
      '[JOUEUR]', '[PLAYER]', '[PERSONNAGE:Vous]', '@Joueur', '@Vous|surpris',
    ]) {
      expect(() => parse('$speaker\nJe vole la clef.'), throwsFormatException);
    }
  });

  test('unknown or unfinished tags are rejected', () {
    expect(() => parse('[PERSONNAGE:Tomas'), throwsFormatException);
    expect(() => parse('[INCONNU]\nTexte.'), throwsFormatException);
    expect(parse('[PERSONNAGE:Tomas]'), isEmpty);
  });

  test('excessive block length and event count are rejected', () {
    expect(() => parse("[NARRATION]\n${List.filled(6001, 'a').join()}"),
        throwsFormatException);
    expect(
      () => parse(List.generate(21, (i) => '[NARRATION]\n$i\n').join()),
      throwsFormatException,
    );
  });

  test('a scene header creates a scene event, not a bubble', () {
    final events = parse('[SCENE]\n[NARRATION]\nLa porte s’ouvre.');
    expect(events.first, isA<ChatSceneChangeOutput>());
    expect(events.whereType<ChatLine>(), hasLength(1));
  });
}
