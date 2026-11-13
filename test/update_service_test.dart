import 'dart:async';

import 'package:domolia/updates/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

final candidate = UpdateCandidate(
  channel: 'dev-latest',
  versionName: '0.1.0',
  versionCode: 12,
  packageName: 'fr.domolia.domolia',
  apkName: 'Domolia-dev.apk',
  sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  downloadUrl: Uri(scheme: 'https',host:'github.com',path:'/Hyarius/Domolia/releases/download/dev-latest/Domolia-dev.apk'),
);

class FakeReleases implements ReleaseSource {
  UpdateCandidate? value;
  Object? failure;
  Completer<UpdateCandidate?>? gate;
  int calls=0;
  String? requestedChannel;
  @override
  Future<UpdateCandidate?> latest(String channel) async {
    calls++; requestedChannel=channel;
    if(gate!=null) return gate!.future;
    if(failure!=null) throw failure!;
    return value;
  }
}

class FakeDownloader implements ApkDownloader {
  int calls=0;
  bool fail=false, invalidHash=false;
  Completer<void>? gate;
  DownloadCancellation? token;
  @override
  Future<String> download(UpdateCandidate candidate, DownloadCancellation cancel,
      void Function(double?) progress) async {
    calls++; token=cancel;
    progress(0.5);
    if(gate!=null) await gate!.future;
    if(cancel.cancelled) throw const DownloadCancelled();
    if(fail) throw const FormatException('Réseau interrompu');
    if(invalidHash) throw const FormatException('SHA-256 différent');
    progress(1);
    return '/app/files/updates/update-12.apk';
  }
}

class FakeAndroid implements AndroidUpdater {
  InstalledApp current=const InstalledApp('fr.domolia.domolia','0.1.0',10);
  int installs=0;
  String result='launched';
  Object? failure;
  @override
  Future<InstalledApp> installedApp() async => current;
  @override
  Future<String> install(String path) async {
    installs++;
    if(failure!=null) throw failure!;
    return result;
  }
}
class FakePreferences implements UpdatePreferences {
  String selected='dev-latest';
  bool enabled=true;
  @override
  Future<String> channel() async=>selected;
  @override
  Future<bool> automatic() async=>enabled;
  @override
  Future<void> setChannel(String value) async { selected=value; }
  @override
  Future<void> setAutomatic(bool value) async { enabled=value; }
}

void main() {
  late FakeReleases releases;
  late FakeDownloader downloader;
  late FakeAndroid android;
  late FakePreferences preferences;
  late UpdateController controller;

  setUp(() {
    releases=FakeReleases();
    downloader=FakeDownloader();
    android=FakeAndroid();
    preferences=FakePreferences();
    controller=UpdateController(
      releases:releases,downloader:downloader,android:android,preferences:preferences);
  });
  tearDown(() => controller.dispose());

  test('01: no newer release is silent and does not download',() async {
    await controller.initialize();
    expect(controller.phase,UpdatePhase.upToDate);
    expect(downloader.calls,0);
    expect(android.installs,0);
  });
  test('02/03: new version starts downloading automatically on startup',() async {
    releases.value=candidate;
    await controller.initialize();
    expect(downloader.calls,1);
    expect(android.installs,1);
    expect(controller.phase,UpdatePhase.installationRequested);
  });
  test('04: progress is observable',() async {
    releases.value=candidate;
    downloader.gate=Completer<void>();
    final values=<double?>[];
    controller.addListener(() { values.add(controller.progress); });
    final pending=controller.initialize();
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase,UpdatePhase.downloading);
    expect(values,contains(0.5));
    downloader.gate!.complete();
    await pending;
    expect(values,contains(1));
  });
  test('05: broken and cancelled downloads do not install',() async {
    releases.value=candidate;
    downloader.fail=true;
    await controller.initialize();
    expect(controller.phase,UpdatePhase.failed);
    expect(android.installs,0);
    downloader.fail=false;
    downloader.gate=Completer<void>();
    final pending=controller.checkNow();
    await Future<void>.delayed(Duration.zero);
    controller.cancelDownload();
    downloader.gate!.complete();
    await pending;
    expect(controller.phase,UpdatePhase.cancelled);
    expect(android.installs,0);
  });
  test('06: wrong SHA prevents install',() async {
    releases.value=candidate;
    downloader.invalidHash=true;
    await controller.initialize();
    expect(controller.phase,UpdatePhase.failed);
    expect(controller.message,contains('SHA-256'));
    expect(android.installs,0);
  });
  test('07: old and equal version codes never download',() async {
    releases.value=candidate;
    android.current=const InstalledApp('fr.domolia.domolia','0.1.0',12);
    await controller.initialize();
    expect(downloader.calls,0);
    android.current=const InstalledApp('fr.domolia.domolia','0.1.0',15);
    controller.installed=android.current;
    await controller.checkNow();
    expect(downloader.calls,0);
  });
  test('08: GitHub unavailable leaves app usable',() async {
    releases.failure=const FormatException('GitHub unavailable');
    await controller.initialize();
    expect(controller.phase,UpdatePhase.failed);
    expect(controller.message,contains('GitHub'));
  });
  test('09: disabled automatic checks allow manual checks',() async {
    preferences.enabled=false;
    releases.value=candidate;
    await controller.initialize();
    expect(releases.calls,0);
    await controller.checkNow();
    expect(releases.calls,1);
    expect(android.installs,1);
  });
  test('10: authorization refused/installation deferred is not retried',() async {
    releases.value=candidate;
    android.result='permissionRequired';
    await controller.initialize();
    expect(controller.phase,UpdatePhase.permissionRequired);
    await controller.checkNow();
    expect(android.installs,2);
    expect(controller.phase,UpdatePhase.permissionRequired);
  });
  test('11: concurrent checks share one request and download',() async {
    preferences.enabled=false;
    await controller.initialize();
    releases.gate=Completer<UpdateCandidate?>();
    final first=controller.checkNow();
    final second=controller.checkNow();
    await Future<void>.delayed(Duration.zero);
    expect(releases.calls,1);
    releases.gate!.complete(candidate);
    await Future.wait([first,second]);
    expect(downloader.calls,1);
    expect(android.installs,1);
  });
  test('12: preview channels are isolated and version code still rules',() async {
    preferences.enabled=false;
    await controller.initialize();
    final preview=UpdateCandidate(
      channel:'preview-impl-pr02-1234567890',
      versionName:candidate.versionName,versionCode:11,
      packageName:candidate.packageName,apkName:'Domolia-preview.apk',
      sha256:candidate.sha256,downloadUrl:candidate.downloadUrl);
    releases.value=preview;
    await controller.changeChannel(preview.channel);
    expect(releases.requestedChannel,preview.channel);
    expect(android.installs,1);
    controller.installed=const InstalledApp('fr.domolia.domolia','0.1.0',20);
    await controller.checkNow();
    expect(android.installs,1);
  });
  test('package identity and channel are checked before downloading',() async {
    releases.value=UpdateCandidate(
      channel:candidate.channel,versionName:candidate.versionName,
      versionCode:candidate.versionCode,packageName:'com.other.app',
      apkName:candidate.apkName,sha256:candidate.sha256,downloadUrl:candidate.downloadUrl);
    await controller.initialize();
    expect(controller.phase,UpdatePhase.failed);
    expect(downloader.calls,0);
  });
  test('metadata validation rejects invalid sha and versionCode',() {
    expect(() => UpdateCandidate.parse({
      'channel':'dev-latest','versionName':'0.1.0',
      'versionCode':0,'applicationId':'fr.domolia.domolia',
      'apkName':'Domolia-dev.apk','sha256':'incorrect',
    },candidate.downloadUrl),throwsFormatException);
  });
}
