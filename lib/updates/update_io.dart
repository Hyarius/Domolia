import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'update_service.dart';

const _repo='Hyarius/Domolia';

class GitHubReleaseSource implements ReleaseSource {
  const GitHubReleaseSource();

  Future<List<int>> _get(Uri url,{int limit=65536}) async {
    final client=HttpClient()..connectionTimeout=const Duration(seconds:12);
    try {
      final request=await client.getUrl(url).timeout(const Duration(seconds:15));
      request.headers.set(HttpHeaders.userAgentHeader,'Domolia-Android-Updater');
      request.headers.set(HttpHeaders.acceptHeader,'application/vnd.github+json');
      request.headers.set(HttpHeaders.cacheControlHeader,'no-cache');
      final response=await request.close().timeout(const Duration(seconds:20));
      if(response.statusCode!=HttpStatus.ok) throw HttpException('HTTP '+response.statusCode.toString(),uri:url);
      final bytes=<int>[];
      await for(final chunk in response.timeout(const Duration(seconds:20))) {
        bytes.addAll(chunk);
        if(bytes.length>limit) throw const FormatException('Réponse GitHub trop longue.');
      }
      return bytes;
    } finally { client.close(force:true); }
  }

  @override
  Future<UpdateCandidate?> latest(String channel) async {
    if(!isValidUpdateChannel(channel)) throw const FormatException('Canal invalide.');
    final uri=Uri.https('api.github.com','/repos/'+_repo+'/releases/tags/'+channel);
    final data=jsonDecode(utf8.decode(await _get(uri)));
    if(data is! Map<String,dynamic> || data['tag_name']!=channel) {
      throw const FormatException('Release GitHub inattendue.');
    }
    final assets=data['assets'];
    if(assets is! List) throw const FormatException('Assets GitHub manquants.');
    final names=assets.whereType<Map<String,dynamic>>().map((asset)=>asset['name']).whereType<String>().toSet();
    if(!names.contains('Domolia-update.json')) return null; // Ancient release.
    final metadata=jsonDecode(utf8.decode(await _get(
      Uri.https('github.com','/'+_repo+'/releases/download/'+channel+'/Domolia-update.json'),limit:16384)));
    if(metadata is! Map<String,dynamic>) throw const FormatException('Métadonnées invalides.');
    final apk=metadata['apkName'];
    if(apk is! String || !{'Domolia-dev.apk','Domolia-preview.apk','Domolia.apk'}.contains(apk)
        || !names.contains(apk)) throw const FormatException('APK absent.');
    return UpdateCandidate.parse(metadata,
      Uri.https('github.com','/'+_repo+'/releases/download/'+channel+'/'+apk));
  }
}

class _HashSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest digest) => value=digest;
  @override
  void close() {}
}

class HttpApkDownloader implements ApkDownloader {
  const HttpApkDownloader();

  @override
  Future<String> download(UpdateCandidate candidate,DownloadCancellation cancel,
      void Function(double?) onProgress) async {
    final root=await getApplicationSupportDirectory();
    final folder=Directory(root.path+'/updates');
    await folder.create(recursive:true);
    final temp=File(folder.path+'/candidate.apk.part');
    final ready=File(folder.path+'/update-'+candidate.versionCode.toString()+'.apk');
    if(await temp.exists()) await temp.delete();
    if(await ready.exists()) await ready.delete();
    final client=HttpClient()..connectionTimeout=const Duration(seconds:15);
    cancel.attach(()=>client.close(force:true));
    IOSink? output;
    try {
      if(cancel.cancelled) throw const DownloadCancelled();
      if(candidate.downloadUrl.scheme!='https' || candidate.downloadUrl.host!='github.com') {
        throw const FormatException('Hôte de téléchargement non autorisé.');
      }
      final request=await client.getUrl(candidate.downloadUrl).timeout(const Duration(seconds:20));
      request.headers.set(HttpHeaders.userAgentHeader,'Domolia-Android-Updater');
      request.headers.set(HttpHeaders.cacheControlHeader,'no-cache');
      final response=await request.close().timeout(const Duration(seconds:25));
      if(response.statusCode!=HttpStatus.ok) throw HttpException('HTTP '+response.statusCode.toString());
      final digest=_HashSink();
      final hasher=sha256.startChunkedConversion(digest);
      output=temp.openWrite();
      var received=0;
      await for(final chunk in response.timeout(const Duration(seconds:40))) {
        if(cancel.cancelled) throw const DownloadCancelled();
        received+=chunk.length;
        if(received>400*1024*1024) throw const FormatException('APK trop volumineux.');
        output.add(chunk);
        hasher.add(chunk);
        onProgress(response.contentLength>0?(received/response.contentLength).clamp(0.0,1.0):null);
      }
      await output.flush(); await output.close(); output=null;
      hasher.close();
      if(cancel.cancelled) throw const DownloadCancelled();
      if(received==0 || (response.contentLength>0 && received!=response.contentLength) ||
          digest.value.toString()!=candidate.sha256) {
        throw const FormatException('SHA-256 ou taille de l’APK incorrect.');
      }
      await temp.rename(ready.path);
      return ready.path;
    } catch(error) {
      if(cancel.cancelled) throw const DownloadCancelled();
      rethrow;
    } finally {
      client.close(force:true);
      if(output!=null) await output.close();
      if(await temp.exists()) await temp.delete();
    }
  }
}

class MethodChannelAndroidUpdater implements AndroidUpdater {
  const MethodChannelAndroidUpdater();
  static const _channel=MethodChannel('domolia/updates');
  @override
  Future<InstalledApp> installedApp() async {
    final info=await _channel.invokeMapMethod<String,dynamic>('installedApp');
    if(info==null || info['versionCode'] is! int) throw const FormatException('Version Android indisponible.');
    return InstalledApp(info['packageName'] as String,info['versionName'] as String,info['versionCode'] as int);
  }
  @override
  Future<String> install(String path) async =>
    await _channel.invokeMethod<String>('installApk',{'path':path}) ?? 'unavailable';
}

class SharedPreferencesUpdateStore implements UpdatePreferences {
  const SharedPreferencesUpdateStore();
  @override
  Future<String> channel() async =>
    (await SharedPreferences.getInstance()).getString('updateChannel')??'dev-latest';
  @override
  Future<bool> automatic() async =>
    (await SharedPreferences.getInstance()).getBool('automaticUpdates')??true;
  @override
  Future<void> setChannel(String value) async {
    await (await SharedPreferences.getInstance()).setString('updateChannel',value);
  }
  @override
  Future<void> setAutomatic(bool value) async {
    await (await SharedPreferences.getInstance()).setBool('automaticUpdates',value);
  }
}

UpdateController createProductionUpdateController()=>UpdateController(
  releases:const GitHubReleaseSource(),
  downloader:const HttpApkDownloader(),
  android:const MethodChannelAndroidUpdater(),
  preferences:const SharedPreferencesUpdateStore());
