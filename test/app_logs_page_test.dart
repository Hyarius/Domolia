import 'package:domolia/logging/app_logger.dart';
import 'package:domolia/logging/app_logs_page.dart';
import 'package:domolia/theme/domolia_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('Log viewer searches, inspects and clears only after confirmation',
      (tester) async {
    final logger = AppLogger(storage: MemoryAppLogStorage());
    logger.log(AppLogLevel.info, 'Démarrage terminé', component: 'app');
    logger.log(AppLogLevel.warning, 'Couverture introuvable', component: 'cover',
        details: {'bytes': 123});
    await logger.flush();

    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: AppLogsPage(logger: logger)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Démarrage terminé'), findsOneWidget);
    expect(find.text('Couverture introuvable'), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('logsSearch')), 'couverture');
    await tester.pumpAndSettle();
    expect(find.text('Démarrage terminé'), findsNothing);
    expect(find.text('Couverture introuvable'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('logEntry-0')));
    await tester.pumpAndSettle();
    expect(find.textContaining('123'), findsWidgets);
    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('logsSearch')), '');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('logsClear')));
    await tester.pumpAndSettle();
    expect(find.text('Effacer les logs ?'), findsOneWidget);
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(await logger.entries(), hasLength(2));

    await tester.tap(find.byKey(const ValueKey('logsClear')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Effacer'));
    await tester.pumpAndSettle();
    expect(await logger.entries(), isEmpty);
    expect(find.text('Démarrage terminé'), findsNothing);
    expect(find.text('Couverture introuvable'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Copy action copies an unmodified JSONL snapshot', (tester) async {
    final logger = AppLogger(storage: MemoryAppLogStorage());
    logger.log(AppLogLevel.error, 'Échec de lecture', component: 'cover');
    await logger.flush();

    String? clipboardText;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardText = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: AppLogsPage(logger: logger)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('logsCopy')));
    await tester.pumpAndSettle();
    expect(clipboardText, await logger.snapshot());
    expect(clipboardText, contains('"component":"cover"'));
    expect(clipboardText, endsWith('\n'));
    expect(tester.takeException(), isNull);
  });
}
