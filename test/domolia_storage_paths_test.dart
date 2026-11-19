import 'package:domolia/storage/domolia_storage_paths.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('domolia/updates');

  test('Native support directory preserves Android filesDir for existing data',
      () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'applicationSupportPath');
      return '/data/user/0/fr.domolia.domolia/files';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final directory = await DomoliaStoragePaths.androidSupportDirectory();
    expect(directory!.path, '/data/user/0/fr.domolia.domolia/files');
  });

  test('Unavailable native directory does not invent a new storage path',
      () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'applicationSupportPath');
      return '';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    expect(await DomoliaStoragePaths.androidSupportDirectory(), isNull);
  });
}
