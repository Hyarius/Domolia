import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:domolia/updates/update_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Le SHA-256 du fichier sur disque est vérifié', () async {
    final dir = await Directory.systemTemp.createTemp('domolia-sha-');
    try {
      final apk = File('${dir.path}/candidate.apk.part');
      final contents = <int>[1, 2, 3, 4, 5, 255];
      await apk.writeAsBytes(contents, flush: true);
      final correct = sha256.convert(contents).toString();
      await verifyApkSha256(apk, correct);
      await expectLater(
        verifyApkSha256(apk, List.filled(64, '0').join()),
        throwsFormatException,
      );
      await apk.writeAsBytes(<int>[9, 9, 9], flush: true);
      await expectLater(verifyApkSha256(apk, correct), throwsFormatException);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
