import 'package:domolia/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('L’accueil affiche le message et le bouton de mise à jour',
      (tester) async {
    await tester.pumpWidget(const DomoliaApp());

    expect(find.text('Bonjour, monde !'), findsOneWidget);
    expect(find.text('Domolia, le début de votre aventure.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Mise à jour'), findsOneWidget);
  });
}
