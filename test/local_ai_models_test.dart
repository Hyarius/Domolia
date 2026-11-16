import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/ai/local_ai_provider.dart';
import 'package:domolia/ai/local_model_catalog.dart';
import 'package:domolia/ai/local_model_manager.dart';
import 'package:domolia/ai/local_ai_settings_page.dart';

class FakeLocalModels extends LocalModelManager {
  int installCalls = 0;
  LocalModelVariant? lastInstalled;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> install(LocalModelVariant variant) async {
    installCalls++;
    lastInstalled = variant;
  }

  @override
  Future<void> setEnabled(bool next) async {
    enabled = next;
    notifyListeners();
  }
}

class FakeLocalProvider extends LocalAiProvider {
  FakeLocalProvider(super.models);
  @override
  Future<void> unload() async {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Official Qwen 1.5B Q4 is the recommended model with pinned SHA-256', () {
    expect(localModelVariants.first.id, 'qwen2.5-1.5b-instruct-q4-k-m');
    expect(localModelVariants, hasLength(3));
    final qwen = localModelVariants.first;
    expect(qwen.bytes, 1117320736);
    expect(qwen.sha256,
        '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e');
    expect(qwen.format, LocalPromptFormat.chatMl);
    expect(qwen.downloadUrl,
        'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/'
        'resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf');
    expect(localModelVariants[1].id, 'ministral-3-3b-q4');
    expect(localModelVariants[2].id, 'ministral-3-3b-q5');
    for (final model in localModelVariants) {
      expect(model.downloadUrl, startsWith('https://huggingface.co/'));
      expect(model.downloadUrl, endsWith('.gguf'));
    }
  });

  test('Qwen ChatML preserves all roles and book NSFW instructions', () {
    final prompt = LocalPrompt.format(localModelVariants.first, const [
      AiMessage(role: 'system', content:
          'Livre en mode NSFW. Respecte les limites définies par le Livre.'),
      AiMessage(role: 'user', content: 'Je frappe à la porte.'),
      AiMessage(role: 'assistant', content: 'La porte s’ouvre.'),
      AiMessage(role: 'user', content: 'Je regarde autour de moi.'),
    ]);
    expect(prompt, startsWith(
        '<|im_start|>system\nLivre en mode NSFW.'));
    expect(prompt, contains(
        '<|im_start|>assistant\nLa porte s’ouvre.<|im_end|>'));
    expect(prompt, contains(
        '<|im_start|>user\nJe regarde autour de moi.<|im_end|>'));
    expect(prompt, endsWith('<|im_start|>assistant\n'));
    expect(prompt, isNot(contains('[INST]')));
  });

  test('Ministral prompt remains compatible with previous releases', () {
    final prompt = LocalPrompt.format(localModelVariants[1], const [
      AiMessage(role: 'system', content: 'Ne joue pas le joueur.'),
      AiMessage(role: 'assistant', content: 'Ancienne scène.'),
      AiMessage(role: 'user', content: 'Je regarde la pluie.'),
    ]);
    expect(prompt, startsWith('<s>[SYSTEM_PROMPT]'));
    expect(prompt, contains('[/SYSTEM_PROMPT]'));
    expect(prompt, contains('Ancienne scène.</s>[INST]'));
    expect(prompt, endsWith('Je regarde la pluie.[/INST]'));
  });

  test('Every template rejects prompts without player input', () {
    for (final model in localModelVariants) {
      expect(
        () => LocalPrompt.format(model, const [
          AiMessage(role: 'system', content: 'Narrateur'),
        ]),
        throwsFormatException,
      );
    }
  });

  test('Interrupted native inference disables automatic local mode', () async {
    SharedPreferences.setMockInitialValues({
      'ministral-local-inference-stage': 'génération du texte',
      'ministral-local-narrator-enabled': true,
    });
    final models = LocalModelManager();
    addTearDown(models.dispose);
    await models.initialize();
    expect(models.enabled, isFalse);
    expect(models.error, contains('génération du texte'));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ministral-local-inference-stage'), isNull);
    expect(prefs.getBool('local-model-enabled'), isFalse);
  });

  test('Existing Ministral model and enabled state survive upgrade', () async {
    final root = await Directory.systemTemp.createTemp('domolia-model-test-');
    addTearDown(() => root.delete(recursive: true));
    final old = localModelVariants[1];
    final dir = Directory('${root.path}/models/ministral');
    await dir.create(recursive: true);
    final file = File('${dir.path}/${old.filename}');
    final handle = await file.open(mode: FileMode.write);
    await handle.writeFrom([0x47, 0x47, 0x55, 0x46]);
    // Sparse file: exact size without allocating 2.15 GB of blocks.
    await handle.truncate(old.bytes);
    await handle.close();
    SharedPreferences.setMockInitialValues({
      'ministral-local-model-variant': old.id,
      'ministral-local-narrator-enabled': true,
    });
    final models = LocalModelManager(modelRoot: root);
    addTearDown(models.dispose);
    await models.initialize();
    expect(models.ready, isTrue);
    expect(models.installedId, old.id);
    expect(models.enabled, isTrue);
    expect(models.installedPath, file.path);
  });

  test('Failed verified replacement leaves previous model intact', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final root = await Directory.systemTemp.createTemp('domolia-model-switch-');
    addTearDown(() => root.delete(recursive: true));
    const old = LocalModelVariant(
      id: 'old', name: 'Old', filename: 'old.gguf', bytes: 8,
      repository: 'test/old', modelId: 'old',
      storageFolder: 'old', format: LocalPromptFormat.mistralInst,
    );
    const next = LocalModelVariant(
      id: 'next', name: 'Next', filename: 'next.gguf', bytes: 8,
      repository: 'test/next', modelId: 'next',
      storageFolder: 'next', format: LocalPromptFormat.chatMl,
      sha256: '0000000000000000000000000000000000000000000000000000000000000000',
    );
    final dir = Directory('${root.path}/models/old');
    await dir.create(recursive: true);
    final oldFile = File('${dir.path}/old.gguf');
    await oldFile.writeAsBytes(utf8.encode('GGUFold!'));
    SharedPreferences.setMockInitialValues({
      'local-model-variant': old.id,
      'local-model-enabled': true,
    });
    final models = LocalModelManager(modelRoot: root, catalog: const [old, next],
      client: MockClient((_) async => http.Response.bytes(
          utf8.encode('GGUFnew!'), 200)));
    addTearDown(models.dispose);
    await models.initialize();
    expect(models.ready, isTrue);
    await expectLater(models.install(next), throwsStateError);
    expect(models.installedId, old.id);
    expect(await oldFile.exists(), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('local-model-variant'), old.id);
    expect(models.error, contains('SHA-256'));
  });

  test('Verified replacement commits new model before deleting old', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final root = await Directory.systemTemp.createTemp('domolia-model-success-');
    addTearDown(() => root.delete(recursive: true));
    const old = LocalModelVariant(
      id: 'old', name: 'Old', filename: 'old.gguf', bytes: 8,
      repository: 'test/old', modelId: 'old',
      storageFolder: 'old', format: LocalPromptFormat.mistralInst,
    );
    final bytes = utf8.encode('GGUFnew!');
    final expectedSha = sha256.convert(bytes).toString();
    final next = LocalModelVariant(
      id: 'next', name: 'Next', filename: 'next.gguf', bytes: 8,
      repository: 'test/next', modelId: 'next',
      storageFolder: 'next', format: LocalPromptFormat.chatMl,
      sha256: expectedSha,
    );
    final dir = Directory('${root.path}/models/old');
    await dir.create(recursive: true);
    final oldFile = File('${dir.path}/old.gguf');
    await oldFile.writeAsBytes(utf8.encode('GGUFold!'));
    SharedPreferences.setMockInitialValues({'local-model-variant': old.id});
    final models = LocalModelManager(modelRoot: root, catalog: [old, next],
      client: MockClient((_) async => http.Response.bytes(bytes, 200)));
    addTearDown(models.dispose);
    await models.initialize();
    await models.install(next);
    expect(models.installedId, next.id);
    expect(models.ready, isTrue);
    expect(await oldFile.exists(), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('local-model-variant'), next.id);
    expect(prefs.getString('local-model-sha256'), expectedSha);
    expect(await File(models.installedPath!).readAsBytes(), bytes);
  });

  testWidgets('Qwen is first and no download occurs without confirmation',
      (tester) async {
    final models = FakeLocalModels();
    final provider = FakeLocalProvider(models);
    addTearDown(models.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: LocalAiSettingsPage(
        models: models,
        provider: provider,
        onBack: () {},
      )),
    ));
    await tester.pumpAndSettle();
    expect(models.installCalls, 0);
    expect(find.textContaining('Qwen2.5 1.5B'), findsWidgets);
    await tester.ensureVisible(find.byKey(const ValueKey('localModelInstall')));
    await tester.tap(find.byKey(const ValueKey('localModelInstall')));
    await tester.pumpAndSettle();
    expect(find.text('Remplacer le modèle IA local ?'), findsOneWidget);
    expect(models.installCalls, 0);
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(models.installCalls, 0);
    await tester.tap(find.byKey(const ValueKey('localModelInstall')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirmer le téléchargement'));
    await tester.pumpAndSettle();
    expect(models.installCalls, 1);
    expect(models.lastInstalled?.id, 'qwen2.5-1.5b-instruct-q4-k-m');
  });
}
