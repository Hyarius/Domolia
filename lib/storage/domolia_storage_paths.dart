import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// The Android support directory is the existing Context.getFilesDir path,
/// never a new database location. Use the app's native MethodChannel first
/// because JNI-based path_provider_android can fail in release APKs.
class DomoliaStoragePaths {
  static const MethodChannel _android = MethodChannel('domolia/updates');

  /// Returns null when an older or locally generated Android Activity has no
  /// native bridge, so path_provider remains a backwards-compatible fallback.
  static Future<Directory?> androidSupportDirectory() async {
    final location =
        await _android.invokeMethod<String>('applicationSupportPath');
    if (location == null || location.isEmpty) return null;
    return Directory(location);
  }

  static Future<Directory> getSupportDirectory() async {
    if (Platform.isAndroid) {
      try {
        final location = await androidSupportDirectory();
        if (location != null) return location;
      } on MissingPluginException {
        // Old Activity without Domolia's native Android updater bridge.
      } on PlatformException {
        // Fall back only if the native bridge cannot return a path.
      }
    }
    return getApplicationSupportDirectory();
  }
}
