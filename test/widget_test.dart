import 'dart:async';

import 'package:domolia/main.dart';
import 'package:domolia/ai/openuncensored_credits_page.dart';
import 'package:domolia/ai/openuncensored_api.dart';
import 'package:domolia/ai/openuncensored_vault.dart';
import 'package:domolia/ai/openuncensored_controller.dart';
import 'package:domolia/ai/ai_task_routing.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:domolia/ai/ai_controller.dart';
import 'package:domolia/ai/ai_provider.dart';
import 'package:domolia/theme/domolia_theme.dart';
import 'package:domolia/updates/update_service.dart';
import 'package:domolia/updates/update_widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Release implements ReleaseSource {
  UpdateCandidate? candidate;
  Object? failure;
  Completer<UpdateCandidate?>? gate;
  @override
  Future<UpdateCandidate?> latest(String channel) async {
    if (gate != null) return gate!.future;
    if (failure != null) throw failure!;
    return candidate;
  }
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

class _MemoryAiProfiles implements AiProfileStore {
  AiProfilesState? state;

  @override
  Future<AiProfilesState?> read() async => state;

  @override
  Future<void> write(AiProfilesState value) async { state = value; }
}

class _NeverCallAi implements AiChatProvider {
  @override
  Future<List<AiModel>> listModels(AiConfiguration configuration) async =>
      throw StateError('Aucun appel réseau dans le test de navigation');

  @override
  Future<String> complete(AiConfiguration configuration, {
    required List<AiMessage> messages, int maxTokens = 1200,
  }) async => throw StateError('Aucun appel réseau dans le test de navigation');
}

class _FakeOuVault implements OuVaultStore {
  OuVaultState state = const OuVaultState();
  @override
  Future<OuVaultState> read() async => state;
  @override
  Future<void> write(OuVaultState value) async { state = value; }
}

Future<void> _openSettings(WidgetTester tester, {String tab = 'settingsTabApp'}) async {
  await tester.tap(find.byKey(const ValueKey('navSettings')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(tab)));
  await tester.pumpAndSettle();
}

Future<void> _openUpdates(WidgetTester tester) async {
  await _openSettings(tester);
  await tester.tap(find.widgetWithText(ListTile, 'Mises à jour'));
  await tester.pumpAndSettle();
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
    expect(find.text('Hello World !'),findsNothing);
    expect(find.byTooltip('Mise à jour'),findsNothing);
    expect(find.byKey(const ValueKey('homeBooks')),findsOneWidget);
    expect(find.byKey(const ValueKey('homeCreateBook')),findsOneWidget);
    expect(find.text('Mes Parties'),findsOneWidget);
    expect(
      find.text('Aucune aventure commencée').evaluate().isNotEmpty ||
      find.text('Chargement de vos Parties...').evaluate().isNotEmpty,
      isTrue,
    );
    final theme=Theme.of(tester.element(find.byType(Scaffold)));
    expect(theme.colorScheme.primary,DomoliaColors.gold);
  });
  testWidgets('Onglets permettent navigation vers À propos et Paramètres',
      (tester) async {
    await tester.pumpWidget(DomoliaApp(updateController:updates));
    await tester.pumpAndSettle();
    await _openSettings(tester);
    expect(find.widgetWithText(ListTile, 'À propos'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'À propos'));
    await tester.pumpAndSettle();
    expect(find.text('À propos de Domolia'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('appBack')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Mises à jour'));
    await tester.pumpAndSettle();
    expect(find.text('Vérifier maintenant'), findsOneWidget);
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
    await _openSettings(tester);
    expect(find.widgetWithText(ListTile, 'À propos'), findsOneWidget);
    downloader.gate!.complete();
    await tester.pumpAndSettle();
  });
  testWidgets('Auto-check switch persists preference',(tester) async {
    await tester.pumpWidget(DomoliaApp(updateController:updates));
    await tester.pumpAndSettle();
    await _openUpdates(tester);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(prefs.enabled,false);
  });
  testWidgets('Manual update check always confirms already up to date',
      (tester) async {
    prefs.enabled = false;
    await tester.pumpWidget(DomoliaApp(updateController: updates));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('updateCheckDialog')), findsNothing);
    await _openUpdates(tester);
    await tester.tap(find.text('Vérifier maintenant'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('updateCheckDialog')), findsOneWidget);
    expect(find.textContaining('déjà à jour'), findsOneWidget);
    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('updateCheckDialog')), findsNothing);
  });

  testWidgets('Dialog shows checking, download and installation permission',
      (tester) async {
    prefs.enabled = false;
    release.candidate = UpdateCandidate(
      channel: 'dev-latest',
      versionName: '0.2.0',
      versionCode: 2,
      packageName: 'fr.domolia.domolia',
      apkName: 'Domolia-dev.apk',
      sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      downloadUrl: Uri(scheme: 'https', host: 'github.com'),
    );
    release.gate = Completer<UpdateCandidate?>();
    downloader.gate = Completer<void>();
    await tester.pumpWidget(DomoliaApp(updateController: updates));
    await tester.pumpAndSettle();
    await _openUpdates(tester);
    await tester.tap(find.text('Vérifier maintenant'));
    await tester.pump();
    expect(find.textContaining('Recherche de mises à jour'), findsOneWidget);
    release.gate!.complete(release.candidate);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Téléchargement en cours'), findsOneWidget);
    downloader.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('Autorisez les installations'), findsOneWidget);
    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();
  });

  testWidgets('Manual check displays network error and settings feedback',
      (tester) async {
    prefs.enabled = false;
    release.failure = const FormatException('Réseau indisponible');
    await tester.pumpWidget(DomoliaApp(updateController: updates));
    await tester.pumpAndSettle();
    await _openUpdates(tester);
    await tester.tap(find.text('Vérifier maintenant'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('updateCheckDialog')), findsOneWidget);
    final status = tester.widget<Text>(
      find.byKey(const ValueKey('updateCheckStatus')),
    );
    expect(status.data, contains('Mise à jour impossible'));
    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();
  });

  testWidgets('La page Mises à jour affiche une vérification explicite', (tester) async {
    prefs.enabled = false;
    await tester.pumpWidget(DomoliaApp(updateController: updates));
    await tester.pumpAndSettle();
    await _openUpdates(tester);
    await tester.tap(find.text('Vérifier maintenant'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('updateCheckDialog')), findsOneWidget);
    expect(find.textContaining('déjà à jour'), findsOneWidget);
  });

  testWidgets('Les réglages IA et les versions sont dans Paramètres',
      (tester) async {
    prefs.enabled = false;
    // Inject a deterministic, local AI profile store. Secure storage plugins
    // are unavailable in Flutter widget tests and leave a pending spinner.
    final ai = AiConnectionController(
      store: _MemoryAiProfiles(), provider: _NeverCallAi(),
    );
    addTearDown(ai.dispose);
    await ai.initialize();
    SharedPreferences.setMockInitialValues({});
    final routing = AiTaskRouting();
    final credits = OuCreditsController(
      ai: ai, routing: routing, vault: _FakeOuVault(),
      api: OpenUncensoredApi(client: MockClient((_) async =>
        http.Response('Never call payment or model API in widget test', 500))),
    );
    addTearDown(credits.dispose);
    addTearDown(routing.dispose);
    await tester.pumpWidget(DomoliaApp(
      updateController: updates, aiController: ai, creditsController: credits,
    ));
    await tester.pumpAndSettle();

    await _openSettings(tester, tab: 'settingsTabAi');
    expect(find.widgetWithText(ListTile, 'Fournisseur IA'), findsNothing);
    expect(find.widgetWithText(ListTile, 'Mise à jour'), findsNothing);
    expect(find.widgetWithText(ListTile, 'Toutes les versions'), findsNothing);
    expect(find.widgetWithText(ListTile, 'Crédits IA'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Mises à jour'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('settingsTabApp')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Mises à jour'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'Mises à jour'));
    await tester.pumpAndSettle();
    expect(find.text('Vérifier maintenant'), findsOneWidget);
    final updatesList = find.descendant(
      of: find.byType(UpdateSettingsPanel),
      matching: find.byType(ListView),
    );
    await tester.drag(updatesList, const Offset(0, -650));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('allVersionsLink')), findsOneWidget);
    await tester.drag(updatesList, const Offset(0, 900));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('appBack')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settingsTabAi')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Crédits IA'));
    await tester.pumpAndSettle();
    expect(find.byType(OpenUncensoredCreditsPage), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('appBack')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Crédits IA'), findsOneWidget);
  });

}
