import 'dart:async';
import 'package:flutter/foundation.dart';

enum UpdatePhase { idle, checking, upToDate, downloading, cancelled, installationRequested, permissionRequired, failed }

class InstalledApp {
  const InstalledApp(this.packageName, this.versionName, this.versionCode);
  final String packageName;
  final String versionName;
  final int versionCode;
}

class UpdateCandidate {
  const UpdateCandidate({required this.channel, required this.versionName, required this.versionCode, required this.packageName, required this.apkName, required this.sha256, required this.downloadUrl});
  final String channel, versionName, packageName, apkName, sha256;
  final int versionCode;
  final Uri downloadUrl;

  factory UpdateCandidate.parse(Map<String, dynamic> json, Uri url) {
    final code=json['versionCode'], hash=json['sha256'];
    if (code is! int || code < 1 || json['channel'] is! String ||
        json['versionName'] is! String || json['applicationId'] is! String ||
        json['apkName'] is! String || hash is! String ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('Métadonnées de mise à jour invalides.');
    }
    return UpdateCandidate(channel:json['channel'] as String,versionName:json['versionName'] as String,
      versionCode:code,packageName:json['applicationId'] as String,apkName:json['apkName'] as String,
      sha256:hash.toLowerCase(),downloadUrl:url);
  }
}
bool isValidUpdateChannel(String value) => value=='dev-latest' ||
    RegExp(r'^preview-[a-z0-9-]{1,32}-[a-f0-9]{10}$').hasMatch(value);

abstract interface class ReleaseSource { Future<UpdateCandidate?> latest(String channel); }
abstract interface class ApkDownloader {
  Future<String> download(UpdateCandidate candidate, DownloadCancellation cancel, void Function(double?) progress);
}
abstract interface class AndroidUpdater {
  Future<InstalledApp> installedApp();
  /// 'launched' only indicates that the Android installer UI was opened.
  Future<String> install(String path);
}
abstract interface class UpdatePreferences {
  Future<String> channel();
  Future<bool> automatic();
  Future<void> setChannel(String channel);
  Future<void> setAutomatic(bool enabled);
}
class DownloadCancellation {
  bool cancelled=false;
  void Function()? _onCancel;
  void attach(void Function() close) { _onCancel=close; if(cancelled) close(); }
  void cancel() { if(cancelled) return; cancelled=true; _onCancel?.call(); }
}
class DownloadCancelled implements Exception { const DownloadCancelled(); }

class UpdateController extends ChangeNotifier {
  UpdateController({required this.releases, required this.downloader, required this.android, required this.preferences});
  final ReleaseSource releases;
  final ApkDownloader downloader;
  final AndroidUpdater android;
  final UpdatePreferences preferences;
  InstalledApp? installed;
  String channel='dev-latest';
  bool automatic=true, initialized=false;
  UpdatePhase phase=UpdatePhase.idle;
  String? message;
  DateTime? lastCheck;
  double? progress;
  bool _closed=false;
  Future<void>? _running;
  DownloadCancellation? _cancellation;
  int? _installationAttempted;

  void _notify() { if(!_closed) notifyListeners(); }

  Future<void> initialize() async {
    if(initialized || _closed) return;
    try {
      installed=await android.installedApp();
      final saved=await preferences.channel();
      channel=isValidUpdateChannel(saved)?saved:'dev-latest';
      automatic=await preferences.automatic();
      initialized=true; _notify();
      if(automatic && !_closed) await checkNow();
    } catch(error) {
      initialized=true; phase=UpdatePhase.failed;
      message='Initialisation des mises à jour impossible : $error'; _notify();
    }
  }
  Future<void> checkNow() {
    if(_closed) return Future<void>.value();
    if(_running!=null) return _running!;
    // Un clic manuel après l'écran d'autorisation Android peut relancer l'essai.
    if(phase==UpdatePhase.permissionRequired) _installationAttempted=null;
    final run=_check();
    _running=run.whenComplete(() { _running=null; _cancellation=null; });
    return _running!;
  }
  Future<void> _check() async {
    try {
      installed ??= await android.installedApp();
      phase=UpdatePhase.checking; message=null; progress=null; _notify();
      final candidate=await releases.latest(channel);
      if(_closed) return;
      lastCheck=DateTime.now();
      if(candidate==null || candidate.versionCode<=installed!.versionCode) {
        phase=UpdatePhase.upToDate;
        message='Aucune version plus récente sur ce canal.'; _notify(); return;
      }
      if(candidate.channel!=channel || candidate.packageName!=installed!.packageName) {
        throw const FormatException('Canal ou paquet Android incompatible.');
      }
      if(_installationAttempted==candidate.versionCode) {
        phase=UpdatePhase.installationRequested;
        message='Installation déjà proposée pendant ce démarrage.'; _notify(); return;
      }
      final cancellation=DownloadCancellation(); _cancellation=cancellation;
      phase=UpdatePhase.downloading; _notify();
      final path=await downloader.download(candidate,cancellation,(value) {
        if(_closed) return;
        progress=value; _notify();
      });
      if(_closed || cancellation.cancelled) return;
      _installationAttempted=candidate.versionCode;
      final result=await android.install(path);
      if(_closed) return;
      phase=result=='permissionRequired'?UpdatePhase.permissionRequired:UpdatePhase.installationRequested;
      message=result=='permissionRequired'
        ? 'Autorisez les installations depuis Domolia dans Android puis vérifiez de nouveau.'
        : 'Installateur Android ouvert. Confirmez ou reportez la mise à jour.';
      _notify();
    } on DownloadCancelled {
      if(_closed) return;
      phase=UpdatePhase.cancelled; message='Téléchargement annulé.'; _notify();
    } catch(error) {
      if(_closed) return;
      phase=UpdatePhase.failed; lastCheck ??= DateTime.now();
      message='Mise à jour impossible : $error'; _notify();
    }
  }
  void cancelDownload() => _cancellation?.cancel();
  Future<void> changeAutomatic(bool value) async {
    automatic=value; _notify(); await preferences.setAutomatic(value);
  }
  Future<void> changeChannel(String value) async {
    final next=value.trim();
    if(!isValidUpdateChannel(next)) {
      throw const FormatException('Canal attendu : dev-latest ou preview-… de GitHub Actions.');
    }
    if(next==channel) return;
    cancelDownload();
    if(_running!=null) await _running;
    channel=next; _installationAttempted=null;
    await preferences.setChannel(next); _notify();
    await checkNow();
  }
  @override
  void dispose() { _closed=true; cancelDownload(); super.dispose(); }
}
