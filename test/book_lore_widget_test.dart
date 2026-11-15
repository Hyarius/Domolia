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

  testWidgets('Invalid character name keeps form and allows correction',
      (tester) async {
    var lore = const BookLore();
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: StatefulBuilder(builder: (context, rebuild) => Scaffold(
        body: ListView(children: [
          BookLoreTab(lore: lore,
            onSave: (next) async => rebuild(() => lore = next)),
        ]),
      )),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(
      const ValueKey('loreSection-characters')));
    await tester.tap(find.byKey(const ValueKey('loreSection-characters')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(
      const ValueKey('loreCreate-characters')));
    await tester.tap(find.byKey(const ValueKey('loreCreate-characters')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('loreFormSave')));
    await tester.pumpAndSettle();
    expect(lore.characters, isEmpty);
    expect(find.byKey(const ValueKey('loreField-name')), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('loreField-name')),
      'Éloïse');
    await tester.tap(find.byKey(const ValueKey('loreFormSave')));
    await tester.pumpAndSettle();
    expect(lore.characters.single.name, 'Éloïse');
    expect(find.byKey(const ValueKey('loreField-name')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Disk save failure retains unsaved global lore in editor',
      (tester) async {
    var lore = const BookLore();
    var fail = true;
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: StatefulBuilder(builder: (context, rebuild) => Scaffold(
        body: ListView(children: [
          BookLoreTab(lore: lore, onSave: (next) async {
            if (fail) throw StateError('Simulated database failure');
            rebuild(() => lore = next);
          }),
        ]),
      )),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('loreEditGlobal')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('loreField-universe')),
      'Érévia');
    await tester.tap(find.byKey(const ValueKey('loreFormSave')));
    await tester.pumpAndSettle();
    expect(lore.global.universe, isEmpty);
    expect(find.byKey(const ValueKey('loreField-universe')), findsOneWidget);
    expect(find.text('Érévia'), findsOneWidget);

    fail = false;
    await tester.tap(find.byKey(const ValueKey('loreFormSave')));
    await tester.pumpAndSettle();
    expect(lore.global.universe, 'Érévia');
    expect(find.byKey(const ValueKey('loreField-universe')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Conditional event without condition stays editable',
      (tester) async {
    var lore = const BookLore();
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: StatefulBuilder(builder: (context, rebuild) => Scaffold(
        body: ListView(children: [
          BookLoreTab(lore: lore,
            onSave: (next) async => rebuild(() => lore = next)),
        ]),
      )),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(
      const ValueKey('loreSection-events')));
    await tester.tap(find.byKey(const ValueKey('loreSection-events')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('loreCreate-events')));
    await tester.tap(find.byKey(const ValueKey('loreCreate-events')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('loreField-name')),
      'Éclipse');
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('loreField-trigger')), 220,
      scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('loreField-trigger')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conditionnel').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('loreFormSave')));
    await tester.pumpAndSettle();
    expect(lore.events, isEmpty);
    expect(find.byKey(const ValueKey('loreField-condition')), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('loreField-condition')), 220,
      scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('loreField-condition')),
      'Le joueur découvre la prophétie');
    await tester.tap(find.byKey(const ValueKey('loreFormSave')));
    await tester.pumpAndSettle();
    expect(lore.events.single.trigger, LoreEventTrigger.conditional);
    expect(lore.events.single.condition,
      'Le joueur découvre la prophétie');
    expect(tester.takeException(), isNull);
  });


  testWidgets('Deleting the last matching tag resets the filter',
      (tester) async {
    var lore = const BookLore(characters: [
      LoreCharacter(id:'c1',name:'Ana',tags:['cour']),
      LoreCharacter(id:'c2',name:'Béatrice',tags:['rare']),
    ]);
    await tester.pumpWidget(MaterialApp(
      theme: DomoliaTheme.dark,
      home: StatefulBuilder(builder: (context, rebuild) => Scaffold(
        body: ListView(children: [
          BookLoreTab(lore: lore,
            onSave: (next) async => rebuild(() => lore = next)),
        ]),
      )),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(
      const ValueKey('loreSection-characters')));
    await tester.tap(find.byKey(const ValueKey('loreSection-characters')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(
      const ValueKey('loreTags-characters')));
    await tester.tap(find.byKey(const ValueKey('loreTags-characters')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('rare').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('loreItem-c2')), findsOneWidget);
    expect(find.byKey(const ValueKey('loreItem-c1')), findsNothing);

    await tester.ensureVisible(find.byKey(const ValueKey('loreDelete-c2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('loreDelete-c2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Supprimer et détacher'));
    await tester.pumpAndSettle();
    expect(lore.characters.single.id, 'c1');
    expect(find.byKey(const ValueKey('loreItem-c1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

}
