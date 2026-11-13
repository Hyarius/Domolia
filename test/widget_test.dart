import 'dart:async';

import 'package:domolia/main.dart';
import 'package:domolia/theme/domolia_theme.dart';
import 'package:domolia/updates/update_service.dart';
import 'package:domolia/updates/update_widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Release implements ReleaseSource {
  UpdateCandidate? candidate;
  @override
  Future<UpdateCandidate?> latest(String channel) async => candidate;
}
class _Downloader implements ApkDownloader {
  Completer<void>? gate;
  void Function(double?)? progress;
  @override
  Future<String> download(UpdateCandidate c, DownloadCancellation token,
      void Function(double?) onProgress) async {
    progress=onProgress;
    onProgress(.4);
    if(gate!=null) await gate!.future;
    if(token.cancelled) throw const DownloadCancelled();
    return '/files/updates/update-2.apk';
  }
}
class _Android implements AndroidUpdater {
  @override
  Future<InstalledApp> installedApp() async =>
    const InstalledApp('fr.domolia.domolia','0.1.0',1);
  @override
  Future<String> install(String path) async => 'permissionRequired';
}
class _Prefs implements UpdatePreferences {
  bool enabled=true;
  @override
  Future<String> channel() async=>'dev-latest';
  @override
  Future<bool> automatic() async=>enabled;
  @override
  Future<void> setChannel(String c) async {}
  @override
  Future<void> setAutomatic(bool e) async {enabled=e;}
}

void main() {
  late _Release release;
  late _Downloader downloader;
  late _Prefs prefs;
  late UpdateController updates;
  setUp(() {
    release=_Release(); downloader=_Downloader(); prefs=_Prefs();
    updates=UpdateController(releases:release,downloader:downloader,
      android:_Android(),preferences:prefs);
  });
  tearDown(() => updates.dispose());

  testWidgets('Accueil et identité vert-or',(tester) async {
    await tester.pumpWidget(DomoliaApp(updateController:updates));
    await tester.pumpAndSettle();
    expect(find.text('Hello World !'),findsOneWidget);
    expect(find.widgetWithText(FilledButton,'Mise à jour'),findsOneWidget);
    final theme=Theme.of(tester.element(find.byType(Scaffold)));
    expect(theme.colorScheme.primary,DomoliaColors.gold);
  });
  testWidgets('Menu permet navigation vers À propos et Paramètres',(tester) async {
    await tester.pumpWidget(DomoliaApp(updateController:updates));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('Paramètres'),findsOneWidget);
    await tester.tap(find.text('À propos'));
    await tester.pumpAndSettle();
    expect(find.text('À propos de Domolia'),findsOneWidget);
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paramètres'));
    await tester.pumpAndSettle();
    expect(find.text('Mises à jour'),findsOneWidget);
    expect(find.text('Vérifier maintenant'),findsOneWidget);
  });
  testWidgets('Progression visible et navigation non bloquée',(tester) async {
    release.candidate=UpdateCandidate(
      channel:'dev-latest',versionName:'0.1.0',versionCode:2,
      packageName:'fr.domolia.domolia',apkName:'Domolia-dev.apk',
      sha256:'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      downloadUrl:Uri(scheme:'https',host:'github.com'));
    downloader.gate=Completer<void>();
    await tester.pumpWidget(DomoliaApp(updateController:updates));
    await tester.pump();
    await tester.pump(const Duration(milliseconds:100));
    expect(find.byType(UpdateProgressStrip),findsOneWidget);
    expect(find.byType(LinearProgressIndicator),findsOneWidget);
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('À propos'),findsOneWidget);
    downloader.gate!.complete();
    await tester.pumpAndSettle();
  });
  testWidgets('Auto-check switch persists preference',(tester) async {
    await tester.pumpWidget(DomoliaApp(updateController:updates));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paramètres'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(prefs.enabled,false);
  });
}
