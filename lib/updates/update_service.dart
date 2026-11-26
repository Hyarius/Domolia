import 'dart:async';
import 'package:flutter/foundation.dart';

enum UpdatePhase { idle, checking, upToDate, downloading, readyToInstall, installing, installed, cancelled, installationRequested, permissionRequired, failed }

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
  UpdateController({required this.releases, required this.downloader, required this.android, required this.preferences, this.canAutoInstall});
  final ReleaseSource releases;
  final ApkDownloader downloader;
  final AndroidUpdater android;
  final UpdatePreferences preferences;
  final bool Function()? canAutoInstall;
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
  ({int version, String path})? _prepared;
  static const recheckInterval = Duration(minutes: 15);

  void _notify() { if(!_closed) notifyListeners(); }

  Future<void> initialize() async {
    if(initialized || _closed) return;
    try {
      installed=await android.installedApp();
      final saved=await preferences.channel();
      channel=isValidUpdateChannel(saved)?saved:'dev-latest';
      automatic=await preferences.automatic();
      initialized=true; _notify();
      if(automatic && !_closed) await checkAutomatically();
    } catch(error) {
      initialized=true; phase=UpdatePhase.failed;
      message='Initialisation des mises à jour impossible : $error'; _notify();
    }
  }
  /// Called on a cold start, foreground resume or return to the home screen.
  Future<void> checkAutomatically() {
    if (_closed || !initialized || !automatic || canAutoInstall?.call() == false) {
      return Future<void>.value();
    }
    final last = lastCheck;
    if (_prepared == null && last != null &&
        DateTime.now().difference(last) < recheckInterval) {
      return Future<void>.value();
    }
    return _startCheck(manual: false);
  }

  Future<void> checkNow() => _startCheck(manual: true);

  Future<void> _startCheck({required bool manual}) {
    if (_closed) return Future<void>.value();
    if (_running != null) return _running!;
    _running = _check(manual: manual).whenComplete(() {
      _running = null;
      _cancellation = null;
    });
    return _running!;
  }

  Future<void> _check({required bool manual}) async {
    try {
      final prepared = _prepared;
      if (prepared != null) {
        await _install(prepared.version, prepared.path);
        return;
      }
      final cancellation = DownloadCancellation();
      _cancellation = cancellation;
      installed ??= await android.installedApp();
      final previousPhase = phase;
      final previousMessage = message;
      phase=UpdatePhase.checking; message=null; progress=null; _notify();
      final candidate=await releases.latest(channel);
      if(_closed) return;
      if(cancellation.cancelled) throw const DownloadCancelled();
      lastCheck=DateTime.now();
      if(candidate==null || candidate.versionCode<=installed!.versionCode) {
        phase=UpdatePhase.upToDate;
        message='Aucune version plus récente sur ce canal.'; _notify(); return;
      }
      if(candidate.channel!=channel || candidate.packageName!=installed!.packageName) {
        throw const FormatException('Canal ou paquet Android incompatible.');
      }
      if(!manual && _installationAttempted==candidate.versionCode) {
        phase=previousPhase;
        message=previousMessage;
        _notify(); return;
      }
      phase=UpdatePhase.downloading; _notify();
      final path=await downloader.download(candidate,cancellation,(value) {
        if(_closed) return;
        progress=value; _notify();
      });
      if(_closed) return;
      if(cancellation.cancelled) throw const DownloadCancelled();
      if (!manual && (!automatic || canAutoInstall?.call() == false)) {
        _prepared = (version: candidate.versionCode, path: path);
        phase = UpdatePhase.readyToInstall;
        message = 'La mise à jour est prête. Elle sera installée depuis l’accueil.';
        _notify();
        return;
      }
      await _install(candidate.versionCode, path);
    } on DownloadCancelled {
      if(_closed) return;
      phase=UpdatePhase.cancelled; message='Téléchargement annulé.'; _notify();
    } catch(error) {
      if(_closed) return;
      phase=UpdatePhase.failed; lastCheck = DateTime.now();
      message='Mise à jour impossible : $error'; _notify();
    }
  }
  Future<void> _install(int version, String path) async {
    _prepared = null;
    phase = UpdatePhase.installing;
    message = 'Installation de la mise à jour par Android…';
    _notify();
    final result = await android.install(path);
    if (_closed) return;
    _installationAttempted = version;
    (phase, message) = switch (result) {
      'installed' => (UpdatePhase.installed, 'Mise à jour installée.'),
      'launched' => (UpdatePhase.installationRequested, 'Confirmez la mise à jour dans Android.'),
      'permissionRequired' => (UpdatePhase.permissionRequired, 'Installation non autorisée. Touchez Vérifier maintenant pour réessayer.'),
      'cancelled' => (UpdatePhase.cancelled, 'Installation reportée.'),
      _ => throw StateError('Réponse inconnue de l’installateur Android.'),
    };
    _notify();
  }

  void cancelDownload() => _cancellation?.cancel();
  Future<void> changeAutomatic(bool value) async {
    automatic=value; _notify(); await preferences.setAutomatic(value);
    if (value) await checkAutomatically();
  }
  Future<void> changeChannel(String value) async {
    final next=value.trim();
    if(!isValidUpdateChannel(next)) {
      throw const FormatException('Canal attendu : dev-latest ou preview-… de GitHub Actions.');
    }
    if(next==channel) return;
    cancelDownload();
    if(_running!=null) await _running;
    channel=next; _installationAttempted=null; _prepared=null;
    await preferences.setChannel(next); _notify();
    await checkNow();
  }
  @override
  void dispose() { _closed=true; cancelDownload(); super.dispose(); }
}
