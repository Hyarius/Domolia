import 'dart:convert';
import 'dart:io';

import 'package:domolia/ai/ai_diagnostics.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/chat/chat_controller.dart';
import 'package:domolia/chat/chat_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';

import 'fixtures/print_shop.dart';

void main() {
  group(
    'Local narrator',
    () {
      late IOClient client;
      late AiConfiguration config;
      late NarrativeChatController chat;
      late List<AiExchange> requests;
      final samples = <Map<String, Object?>>[];

      setUpAll(() {
        final env = Platform.environment;
        final tls = SecurityContext()
          ..setTrustedCertificates(env['DOMOLIA_AI_CERT']!);
        client = IOClient(
          HttpClient(context: tls)..findProxy = (_) => 'DIRECT',
        );
        final port = int.parse(env['DOMOLIA_AI_PORT']!);
        config = AiConfiguration(
          baseUrl: 'https://127.0.0.1:$port/v1',
          model: 'domolia-tests',
          apiKey: 'local-test-only',
        );
      });
      tearDownAll(() {
        client.close();
        final output = File('build/local-ai/report.json');
        output.parent.createSync(recursive: true);
        output.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
            'model': Platform.environment['DOMOLIA_AI_GGUF'],
            'runner': Platform.environment['DOMOLIA_AI_RUNNER_VERSION'],
            'seed': 41,
            'temperature': 0,
            'samples': samples,
          }),
        );
      });
      void newParty() {
        final diagnostics = AiExchangeRecorder();
        requests = [];
        chat = NarrativeChatController(
          provider: OpenAiCompatibleChatProvider(
            client: client,
            diagnostics: diagnostics,
          ),
          configuration: () => config,
          structuredStreamingEnabled: true,
          narrator: book.narrator,
          loreProvider: () => book.lore,
          diagnostics: diagnostics,
          onExchangeCaptured: requests.add,
        );
      }

      setUp(newParty);
      tearDown(() => chat.dispose());

      Future<List<ChatEntry>> play(
        String scenario,
        String action, {
        required int inputLimit,
      }) async {
        final before = requests.length;
        final firstNew = chat.messages.length;
        await chat.send(action);
        final exchanges = requests.skip(before).toList();
        final reply = chat.messages.skip(firstNew + 1).toList();
        samples.add({
          'scenario': scenario,
          'action': action,
          'inputTokens': chat.promptTokens,
          'outputTokens': chat.completionTokens,
          'inputLimit': inputLimit,
          'outputLimit': 320,
          'calls': exchanges.length,
          'error': chat.error,
          'exchanges': [for (final e in exchanges) e.toJson()],
          'reply': [
            for (final e in reply)
              {'role': e.speaker.name, 'name': e.name, 'text': e.text},
          ],
        });
        expect(chat.error, isNull, reason: scenario);
        expect(exchanges, hasLength(1));
        expect(chat.promptTokens, inInclusiveRange(1, inputLimit));
        expect(chat.completionTokens, inInclusiveRange(1, 320));
        expect(reply, isNotEmpty);
        expect(
          reply.any((e) => e.speaker == ChatSpeaker.player || e.inProgress),
          isFalse,
        );
        expect(
          reply.map((e) => e.text).join(' '),
          isNot(contains('Le syndic est son frère')),
        );
        return reply;
      }

      test('opening and a second player intervention', () async {
        final first = await play(
          'opening',
          'Je demande à Liv le prix de cette feuille.',
          inputLimit: 550,
        );
        final offer = first.where(
          (line) => line.name == 'Liv' && line.speaker == ChatSpeaker.character,
        );
        expect(
          offer.any(
            (line) => RegExp(
              r'\b(?:8|huit)\b',
              caseSensitive: false,
            ).hasMatch(line.text),
          ),
          isTrue,
          reason: 'Liv should quote the price set by the Book.',
        );
        final next = await play(
          'negotiation',
          'Je pousse ma montre vers Liv. « Vous la garderiez en gage ? »',
          inputLimit: 850,
        );
        // The NPC can answer in words or by reaching for the watch.
        final answer = next.map((line) => line.text).join(' ');
        expect(answer, matches(RegExp(r'montre|gage', caseSensitive: false)));
        expect(answer, isNot(matches(RegExp(r'(^|\n)[*@]|---$'))));
      });

      test(
        'an old clue survives 40 and 80 turns at a stable input cost',
        () async {
          final costs = <int>[];
          for (final turns in [40, 80]) {
            if (costs.isNotEmpty) {
              chat.dispose();
              newParty();
            }
            chat.restoreTimeline(played(turns));
            final lines = await play(
              'recall-$turns',
              'Quel numéro figure sur la consigne ?',
              inputLimit: 820,
            );
            expect(
              lines
                  .where(
                    (e) =>
                        e.speaker == ChatSpeaker.character && e.name == 'Liv',
                  )
                  .any((e) => RegExp(r'\b517\b').hasMatch(e.text)),
              isTrue,
            );
            costs.add(chat.promptTokens!);
          }
          expect((costs.last - costs.first).abs(), lessThanOrEqualTo(16));
        },
      );
    },
    skip: const bool.fromEnvironment('DOMOLIA_LOCAL_AI')
        ? false
        : 'Use tool/test_local_ai.sh to run the pinned model.',
  );
}
