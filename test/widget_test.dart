import 'package:domolia/main.dart';
import 'package:domolia/theme/domolia_theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Accueil Domolia : identité, boutons et thème vert-or',
      (tester) async {
    await tester.pumpWidget(const DomoliaApp());

    expect(find.text('Bonjour, monde !'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Mise à jour'), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, 'Toutes les versions'),
      findsOneWidget,
    );
    expect(find.byType(Image), findsWidgets);

    final context = tester.element(find.byType(Scaffold));
    final theme = Theme.of(context);
    expect(theme.scaffoldBackgroundColor, DomoliaColors.background);
    expect(theme.colorScheme.primary, DomoliaColors.gold);
  });

  testWidgets('Le menu permet de naviguer vers À propos', (tester) async {
    await tester.pumpWidget(const DomoliaApp());

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('Accueil'), findsOneWidget);
    expect(find.text('À propos'), findsOneWidget);

    await tester.tap(find.text('À propos'));
    await tester.pumpAndSettle();
    expect(find.text('À propos de Domolia'), findsOneWidget);
  });
}
