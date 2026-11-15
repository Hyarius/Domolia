import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import '../ai/ai_diagnostics.dart';
import '../ai/ai_provider.dart';
import '../ai/chatgpt_auth.dart';
import '../ai/web_ai_profile_store.dart';
import '../books/book_store.dart';
import '../updates/update_service.dart';

// Same SQLite tables and migrations as Android, different storage backend.
// On Web the database path is a stable logical name, not a file-system path.
BookStore createProductionBookStore() => SqliteBookStore(
  factory: databaseFactoryFfiWeb,
  databasePath: 'domolia_books.sqlite',
);

// Web credentials remain in memory: plain IndexedDB/localStorage is not an
// Android Keystore equivalent. Metadata is saved without tokens or API keys.
AiProfileStore createProductionAiProfileStore() => WebAiProfileStore();

// OAuth loopback on Android is not available on a static GitHub Pages site.
// Never advertise a working ChatGPT login until a compliant flow is verified.
ChatGptAccountService? createProductionChatGptAccountService() => null;

AiChatProvider? createProductionChatGptProvider(
  AiExchangeRecorder diagnostics,
) => null;

// Existing Android update system must not be invoked from a browser.
UpdateController createProductionUpdateController() => UpdateController(
  releases: _NoWebApkReleases(),
  downloader: _NoWebApkDownloader(),
  android: _NoWebAndroidInstaller(),
  preferences: _NoWebUpdatePreferences(),
);

class _NoWebApkReleases implements ReleaseSource {
  @override
  Future<UpdateCandidate?> latest(String channel) async => null;
}

class _NoWebApkDownloader implements ApkDownloader {
  @override
  Future<String> download(
    UpdateCandidate candidate,
    DownloadCancellation cancellation,
    void Function(double?) progress,
  ) => Future<String>.error(UnsupportedError('APK indisponible sur Web'));
}

class _NoWebAndroidInstaller implements AndroidUpdater {
  @override
  Future<InstalledApp> installedApp() async =>
      const InstalledApp('fr.domolia.web', 'Web', 0);

  @override
  Future<String> install(String path) =>
      Future<String>.error(UnsupportedError('Installation APK sur Web'));
}

class _NoWebUpdatePreferences implements UpdatePreferences {
  @override
  Future<String> channel() async => 'dev-latest';
  @override
  Future<bool> automatic() async => false;
  @override
  Future<void> setChannel(String value) async {}
  @override
  Future<void> setAutomatic(bool enabled) async {}
}
