import 'package:flutter_test/flutter_test.dart';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/local_context_budget.dart';
import 'package:domolia/ai/local_context_packer.dart';
import 'package:domolia/ai/local_model_catalog.dart';
import 'package:domolia/books/book_lore.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/jsonifier.dart';
import 'package:domolia/chat/narrator.dart';

void main() {
  final qwen = localModelVariants.first;
  final mistral = localModelVariants[1];

  LocalContextBudget window([int output = 320]) =>
      LocalContextBudget(model: qwen,
          estimator: LocalTokenEstimator(), outputTokens: output);

  test('Every prompt includes its template, output reserve and safety margin', () {
    final budget = window();
    expect(budget.capacity, 2048 - 320 - LocalContextBudget.safetyTokens);
    final turns = [
      const AiMessage(role: 'system', content: 'Raconte en français.'),
      const AiMessage(role: 'user', content: 'Bonjour Oren.'),
    ];
    expect(budget.format(turns), contains('<|im_start|>assistant'));
    expect(budget.fits(turns), isTrue);
    expect(budget.estimate(turns), greaterThan(0));
    final mistralBudget = LocalContextBudget(
        model: mistral, estimator: LocalTokenEstimator(), outputTokens: 320);
    expect(mistralBudget.format(turns), contains('[INST]'));
    expect(mistralBudget.format(turns), isNot(contains('<|im_start|>')));
    expect(() => budget.requireFit([
      ...turns,
      AiMessage(role: 'assistant', content: 'mot ' * 8000),
    ]), throwsFormatException);
  });

  test('Native measurements calibrate models independently', () {
    final estimator = LocalTokenEstimator();
    final prompt = 'La pluie tombe sur le Pont de Verre. ' * 30;
    final initial = estimator.estimate(qwen, prompt);
    final mistralInitial = estimator.estimate(mistral, prompt);
    estimator.observe(qwen, prompt, 90);
    expect(estimator.estimate(qwen, prompt), lessThan(initial));
    expect(estimator.estimate(mistral, prompt), mistralInitial);
  });

  test('Novel-like Lore packs canon and player action, omitting old dialogue', () {
    final lore = BookLore(
      global: const LoreGlobal(
        universe: 'Les Marches de Verre',
        overview: 'Une région pluvieuse entourant un pont très ancien.',
        initialContext: 'Oren tient l’auberge et Maëlys attend près du feu.',
        rules: 'Le joueur décide de ses propres actes.',
        secrets: 'Oren détient une clé de cuivre sous le comptoir.',
      ),
      characters: const [
        LoreCharacter(id: 'oren', name: 'Oren',
          description: 'Aubergiste de 43 ans, discret et prudent.',
          homePlaceId: 'auberge',
          secrets: 'Il ne donne sa clé que volontairement.'),
      ],
      places: const [
        LorePlace(id: 'auberge', name: 'Auberge du Pont de Verre',
          description: 'Une auberge près d’une rivière.',
          characterIds: ['oren']),
      ],
      scenarios: const [
        LoreScenario(id: 'disparition', name: 'Voyageur disparu',
          importance: LoreScenarioImportance.main,
          summary: 'Un visiteur a disparu hier soir.',
          characterIds: ['oren'], placeIds: ['auberge'],
          eventIds: ['registre']),
      ],
      events: const [
        LoreEvent(id: 'registre', name: 'Registre des voyageurs',
          trigger: LoreEventTrigger.conditional,
          condition: 'Seulement si le joueur le demande.',
          description: 'Oren peut montrer le prénom Lucan.',
          characterIds: ['oren'], scenarioIds: ['disparition']),
      ],
    );
    const narrator = Narrator(
      narrativePrompt: 'Raconte une réponse courte, avec des dialogues. '
          'Les personnages sont adultes. Respecte le choix du joueur.',
    );
    final history = [
      AiMessage(role: 'assistant', content: 'Ancien dialogue. ' * 1000),
      const AiMessage(role: 'user', content:
        'Je demande à Oren ce qui est arrivé au voyageur disparu.'),
    ];
    final budget = window();
    final messages = LocalContextPacker(budget).narrator(
        narrator: narrator, history: history, lore: lore);
    expect(budget.fits(messages), isTrue);
    expect(messages.last.content, contains('Je demande à Oren'));
    expect(messages.first.content, contains('Les Marches de Verre'));
    expect(messages.first.content, contains('Oren'));
    expect(messages.first.content, contains('clé de cuivre'));
    expect(messages.map((e) => e.content).join(''),
        isNot(contains('Ancien dialogue. ' * 50)));
  });

  test('JSONifier keeps exact RAW numbered parts, drops optional history', () {
    const raw = 'Oren essuie une tasse.\n\n'
        'Oren : « Vous cherchez quelqu’un ? »';
    final budget = window(700);
    final messages = LocalContextPacker(budget).jsonifier(
      raw: raw,
      previous: [
        ChatEntry(id: 1, speaker: ChatSpeaker.player, name: 'Vous',
          text: 'Vieil échange. ' * 1200),
      ],
    );
    expect(budget.fits(messages), isTrue);
    final parts = const Jsonifier().partsForPrompt(raw);
    expect(messages.last.content, contains(parts));
    expect(messages.last.content, isNot(contains('Vieil échange.')));
  });

  test('Oversized indispensable canon raises a specific, safe error', () {
    const tiny = LocalModelVariant(
      id: 'tiny', name: 'Tiny', filename: 'fake.gguf', bytes: 8,
      repository: 'test/tiny', modelId: 'tiny',
      format: LocalPromptFormat.chatMl, storageFolder: 'tiny',
      contextTokens: 750,
    );
    final budget = LocalContextBudget(model: tiny,
        estimator: LocalTokenEstimator(), outputTokens: 320);
    final lore = BookLore(global: LoreGlobal(
      universe: 'Exemple', rules: 'Le canon est indispensable. ' * 120,
    ));
    expect(
      () => LocalContextPacker(budget).narrator(
        narrator: const Narrator(narrativePrompt: 'Sois bref.',
          protocolPrompt: 'Narrateur.'),
        history: const [AiMessage(role: 'user', content: 'Je frappe.')],
        lore: lore,
      ),
      throwsFormatException,
    );
  });
}
