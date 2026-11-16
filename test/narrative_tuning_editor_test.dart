import 'package:domolia/chat/narrative_tuning_editor.dart';
import 'package:domolia/chat/narrator.dart';
import 'package:domolia/theme/domolia_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('Length, scene pacing and style chips are independent',
      (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final keywords = TextEditingController();
    addTearDown(keywords.dispose);
    var tuning = const NarrativeTuning();

    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: Scaffold(body: StatefulBuilder(
        builder: (context, refresh) => SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: NarrativeTuningEditor(
              keyPrefix: 'test',
              tuning: tuning,
              keywordsController: keywords,
              onTuningChanged: (value) => refresh(() => tuning = value),
              onKeywordsChanged: () => refresh(() {}),
            ),
          ),
        ),
      )),
    ));

    expect(tuning.responseLength, 2);
    expect(tuning.scenePacing, 2);
    final length = tester.widget<Slider>(
        find.byKey(const ValueKey('testResponseLengthSlider')));
    length.onChanged!(5);
    await tester.pump();
    expect(tuning.responseLength, 5);
    expect(tuning.scenePacing, 2);
    final pacing = tester.widget<Slider>(
        find.byKey(const ValueKey('testScenePacingSlider')));
    pacing.onChanged!(1);
    await tester.pump();
    expect(tuning.responseLength, 5);
    expect(tuning.scenePacing, 1);

    final chip = find.byKey(const ValueKey('testKeyword-Dialogué'));
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pump();
    expect(keywords.text, 'Dialogué');
    expect(tester.widget<FilterChip>(chip).selected, isTrue);

    final field = find.byKey(const ValueKey('testStyleKeywordsField'));
    await tester.ensureVisible(field);
    await tester.enterText(field, 'Sobre, Sensoriel, Sobre');
    await tester.pump();
    expect(NarrativeTuning.parseKeywords(keywords.text),
        ['Sobre', 'Sensoriel']);
    expect(tuning.responseLength, 5);
    expect(tuning.scenePacing, 1);
    expect(tester.takeException(), isNull);
  });
}
