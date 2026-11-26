// Test entry point for the old APK in the Android self-update smoke test.
// The replacement APK uses the normal lib/main.dart entry point.
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'package:domolia/storage/domolia_storage_paths.dart';
import 'package:domolia/updates/update_io.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = await DomoliaStoragePaths.getSupportDirectory();
  try {
    await File('${root.path}/before-update').writeAsString('still here', flush: true);
    await const MethodChannelAndroidUpdater().install('${root.path}/updates/update-2.apk');
  } catch (error) {
    await File('${root.path}/update-error').writeAsString(error.toString());
  }
}
