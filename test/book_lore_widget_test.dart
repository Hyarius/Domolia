import 'package:domolia/books/book_lore.dart';
import 'package:domolia/books/book_lore_tab.dart';
import 'package:domolia/theme/domolia_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('Lore catalogue expands, edits, searches and deletes a character',
      (tester) async {
    var lore = const BookLore();
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: StatefulBuilder(builder: (context, rebuild) => Scaffold(
        body: ListView(children: [
          BookLoreTab(lore: lore, onSave: (next) async {
            rebuild(() => lore = next);
          }),
        ]),
      )),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('loreSection-global')),findsOneWidget);
    expect(find.byKey(const ValueKey('loreSection-characters')),findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('loreSection-characters')));
    await tester.tap(find.byKey(const ValueKey('loreSection-characters')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Aucune fiche'),findsWidgets);
    await tester.ensureVisible(find.byKey(const ValueKey('loreCreate-characters')));
    await tester.tap(find.byKey(const ValueKey('loreCreate-characters')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('loreField-name')),'Éloïse');
    await tester.tap(find.byKey(const ValueKey('loreFormSave')));
    await tester.pumpAndSettle();
    expect(lore.characters.single.name,'Éloïse');
    final id = lore.characters.single.id;
    expect(find.byKey(ValueKey('loreItem-$id')),findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('loreSearch-characters')),
      'eloise');
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('loreItem-$id')),findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('loreSearch-characters')),
      'introuvable');
    await tester.pumpAndSettle();
    expect(find.text('Aucun résultat pour ces filtres.'),findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('loreSearch-characters')),'');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('loreDelete-$id')));
    await tester.pumpAndSettle();
    expect(find.text('Supprimer cette fiche ?'),findsOneWidget);
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(lore.characters,hasLength(1));
    await tester.tap(find.byKey(ValueKey('loreDelete-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Supprimer et détacher'));
    await tester.pumpAndSettle();
    expect(lore.characters,isEmpty);
    expect(tester.takeException(),isNull);
  });

  testWidgets('Global canon editing and tag/category filters are persisted',
      (tester) async {
    var lore = const BookLore(characters:[
      LoreCharacter(id:'p1',name:'Éloïse',role:'Garde',tags:['cour']),
      LoreCharacter(id:'p2',name:'Zora',role:'Marchande',tags:['commerce']),
    ]);
    await tester.pumpWidget(MaterialApp(
      theme:DomoliaTheme.dark,
      home:StatefulBuilder(builder:(context,rebuild)=>Scaffold(
        body:ListView(children:[BookLoreTab(lore:lore,
          onSave:(next) async => rebuild(()=>lore=next))]),
      )),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('loreEditGlobal')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('loreField-universe')),
      'Érévia');
    await tester.tap(find.byKey(const ValueKey('loreFormSave')));
    await tester.pumpAndSettle();
    expect(lore.global.universe,'Érévia');
    await tester.ensureVisible(find.byKey(const ValueKey('loreSection-characters')));
    await tester.tap(find.byKey(const ValueKey('loreSection-characters')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('loreTags-characters')));
    await tester.tap(find.byKey(const ValueKey('loreTags-characters')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('commerce').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('loreItem-p2')),findsOneWidget);
    expect(find.byKey(const ValueKey('loreItem-p1')),findsNothing);
  });
}
