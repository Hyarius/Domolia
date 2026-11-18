import 'dart:convert';

import 'package:domolia/illustration/illustration_records.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Prompt export preserves the exact historical request without files',
      () {
    final record = StoredIllustration(
      requestId: 'request-example', sessionId: 'session-example',
      intentId: 9, sourceHash: 'hash',
      state: IllustrationJobState.available,
      provider: 'test-provider', model: 'test-image',
      createdAtUtc: DateTime.utc(2026, 1, 1),
      prompt: 'Style graphique : Aquarelle.\nSujet visible : Un phare.',
      negativePrompt: 'texte, filigranes',
      costUsd: 0.01, fileNames: ['private-image.png'],
    );
    final exported = jsonDecode(utf8.decode(record.exportPromptBytes()))
        as Map<String, dynamic>;
    expect(exported, {
      'format': 'domolia-illustration-prompt-v1',
      'createdAtUtc': '2026-01-01T00:00:00.000Z',
      'requestId': 'request-example', 'sessionId': 'session-example',
      'intentId': 9, 'provider': 'test-provider', 'model': 'test-image',
      'costUsd': 0.01, 'style': 'Aquarelle',
      'negativePrompt': record.negativePrompt, 'prompt': record.prompt,
    });
    expect(utf8.decode(record.exportPromptBytes()),
        isNot(contains('private-image.png')));
  });

  test('Legacy records without style or price export null values', () {
    final record = StoredIllustration(
      requestId: 'legacy', sessionId: 's', intentId: 1,
      sourceHash: 'hash', state: IllustrationJobState.available,
      provider: 'test', model: 'test', createdAtUtc: DateTime.utc(2026),
      prompt: 'Ancien prompt',
    );
    final exported = record.toPromptExportJson();
    expect(exported['style'], isNull);
    expect(exported['costUsd'], isNull);
    expect(exported['prompt'], 'Ancien prompt');
  });
}
