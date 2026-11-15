import 'dart:convert';

import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:domolia/chat/chat_exports.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:domolia/chat/raw_generation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Token totals add each tool continuation and JSONifier exactly once', () {
    StoredAiDiagnostic diagnostic(String stage, int at,
        int? prompt, int? completion) => StoredAiDiagnostic(
      id: stage,
      sessionId: 'part-A',
      createdAtUtc: DateTime.utc(2026, 1, 1, 0, 0, at),
      content: jsonEncode({
        'format': 'domolia-ai-exchange-v1',
        'recordedAtUtc': DateTime.utc(2026, 1, 1, 0, 0, at).toIso8601String(),
        'stage': stage,
        'playerEventId': 10,
        'request': {'body': {'model': 'fake'}},
        'interpretation': {
          'promptTokens': prompt,
          'completionTokens': completion,
        },
      }),
    );
    final data = exportAiPipelineTrace(
      const [
        ChatEntry(id: 10, speaker: ChatSpeaker.player,
            name: 'Joueur', text: 'Bonjour'),
      ],
      const [RawGeneration(playerEventId: 10, rawText: 'Réponse')],
      [
        diagnostic('narrator_tool_round_0', 1, 100, 20),
        diagnostic('narrator_tool_round_1', 2, 180, 30),
        diagnostic('jsonifier', 3, 80, 40),
      ],
    );
    final turn = (data['turns'] as List).single as Map<String, dynamic>;
    final usage = turn['usage'] as Map<String, dynamic>;
    expect(usage['requests'], 3);
    expect(usage['narratorRequests'], 2);
    expect(usage['jsonifierRequests'], 1);
    expect(usage['totalTokensKnown'], 450);
    expect(usage['complete'], true);
    expect(turn['raw']['text'], 'Réponse');
  });

  test('Missing provider usage is reported rather than silently assumed zero', () {
    final data = exportAiPipelineTrace(
      const [ChatEntry(id: 7, speaker: ChatSpeaker.player,
          name: 'Joueur', text: 'Question')],
      const [],
      [
        StoredAiDiagnostic(
          id: 'no-count', sessionId: 'part-B',
          createdAtUtc: DateTime.utc(2026),
          content: jsonEncode({
            'recordedAtUtc': DateTime.utc(2026).toIso8601String(),
            'stage': 'narrator_tool_round_0',
            'playerEventId': 7,
            'interpretation': {
              'promptTokens': null, 'completionTokens': null,
            },
          }),
        ),
      ],
    );
    final usage = (data['turns'] as List).single['usage'];
    expect(usage['complete'], false);
    expect(usage['requestsWithoutTokenUsage'], 1);
    expect(usage['totalTokensKnown'], 0);
  });
}
