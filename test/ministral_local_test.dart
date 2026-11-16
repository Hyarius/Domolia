import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/ministral_local_provider.dart';
import 'package:domolia/ai/ministral_model_manager.dart';
import 'package:domolia/ai/ministral_settings_page.dart';

class FakeMinistralModels extends MinistralModelManager {
  int installCalls = 0;
  MinistralVariant? lastInstalled;
  @override
  Future<void> initialize() async {}

  @override
  Future<void> install(MinistralVariant variant) async {
    installCalls++;
    lastInstalled = variant;
  }

  @override
  Future<void> setEnabled(bool next) async {
    enabled = next;
    notifyListeners();
  }
}

class FakeMinistralProvider extends MinistralLocalProvider {
  FakeMinistralProvider(super.models);
  @override
  Future<void> unload() async {}
}

void main() {
  test('Catalog only contains official Mistral GGUF weights', () {
    expect(ministralVariants, hasLength(2));
    expect(ministralVariants.first.id, 'ministral-3-3b-q4');
    expect(ministralVariants.first.bytes, lessThan(ministralVariants.last.bytes));
    for (final variant in ministralVariants) {
      expect(variant.downloadUrl,
          startsWith('https://huggingface.co/mistralai/'));
      expect(variant.downloadUrl, endsWith('.gguf'));
      expect(variant.bytes, greaterThan(2 * 1000 * 1000 * 1000));
    }
  });

  test('Mistral prompt uses published INST and SYSTEM_PROMPT markers', () {
    final prompt = MinistralPrompt.format(const [
      AiMessage(role: 'system', content: 'Ne joue pas le joueur.'),
      AiMessage(role: 'assistant', content: 'Ancienne scène.'),
      AiMessage(role: 'user', content: 'Je regarde la pluie.'),
    ]);
    expect(prompt, startsWith('<s>[SYSTEM_PROMPT]'));
    expect(prompt, contains('[/SYSTEM_PROMPT]'));
    expect(prompt, contains('Ancienne scène.</s>[INST]'));
    expect(prompt, endsWith('Je regarde la pluie.[/INST]'));
    expect(prompt, isNot(contains('<|im_start|>')));
  });

  test('Mistral prompt rejects an interaction without player input', () {
    expect(
      () => MinistralPrompt.format(const [
        AiMessage(role: 'system', content: 'Narrateur'),
      ]),
      throwsFormatException,
    );
  });

  testWidgets('A model is never removed or downloaded without confirmation',
      (tester) async {
    final models = FakeMinistralModels();
    final provider = FakeMinistralProvider(models);
    addTearDown(models.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: MinistralSettingsPage(
        models: models,
        provider: provider,
        onBack: () {},
      )),
    ));
    await tester.pumpAndSettle();
    expect(models.installCalls, 0);
    await tester.tap(find.byKey(const ValueKey('ministralInstall')));
    await tester.pumpAndSettle();
    expect(find.text('Remplacer le modèle IA local ?'), findsOneWidget);
    expect(models.installCalls, 0);
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(models.installCalls, 0);
    await tester.tap(find.byKey(const ValueKey('ministralInstall')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Désinstaller et télécharger'));
    await tester.pumpAndSettle();
    expect(models.installCalls, 1);
    expect(models.lastInstalled?.id, 'ministral-3-3b-q4');
  });
}
