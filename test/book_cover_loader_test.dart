import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:domolia/books/book_cover_loader.dart';
import 'package:domolia/books/book_definition.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final png = Uint8List.fromList([
    137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4,
  ]);
  final jpeg = Uint8List.fromList([255, 216, 255, 10, 20, 30]);
  final webp = Uint8List.fromList(
    [...ascii.encode('RIFF'), 12, 0, 0, 0, ...ascii.encode('WEBP'), 1],
  );

  test('accepts PNG, JPEG and WebP from Android picker bytes', () async {
    for (final (bytes, expectedMime) in <(Uint8List, String)>[
      (png, 'image/png'),
      (jpeg, 'image/jpeg'),
      (webp, 'image/webp'),
    ]) {
      final result = await BookCoverLoader.load(PlatformFile(
        name: 'selected.image', size: bytes.length, bytes: bytes,
      ));
      expect(result.mime, expectedMime);
      expect(base64Decode(result.base64), bytes);
      BookDefinition(id: 'book-test', title: 'Test',
          coverMime: result.mime, coverBase64: result.base64).validate();
    }
  });

  test('reads Android picker cache file when bytes are unavailable', () async {
    final directory = await Directory.systemTemp.createTemp('cover-android-');
    addTearDown(() async { await directory.delete(recursive: true); });
    final cache = File('${directory.path}/image.tmp');
    await cache.writeAsBytes(png);
    final result = await BookCoverLoader.load(PlatformFile(
      name: 'image.png', size: png.length, path: cache.path,
    ));
    expect(result.mime, 'image/png');
    expect(base64Decode(result.base64), png);
  });

  test('rejects unavailable, unsupported, and oversized cover data', () async {
    await expectLater(BookCoverLoader.load(PlatformFile(
      name: 'missing.png', size: 10, path: '/not/a/real/cover.png',
    )), throwsFormatException);
    await expectLater(BookCoverLoader.load(PlatformFile(
      name: 'invalid.png', size: 4, bytes: Uint8List.fromList([1, 2, 3, 4]),
    )), throwsFormatException);
    await expectLater(BookCoverLoader.load(PlatformFile(
      name: 'oversized.png', size: BookDefinition.maxCoverBytes + 1,
    )), throwsFormatException);
    await expectLater(BookCoverLoader.load(PlatformFile(
      name: 'empty.png', size: 0, bytes: Uint8List(0),
    )), throwsFormatException);
  });

  test('validates actual file size even if picker reports a smaller size', () async {
    final directory = await Directory.systemTemp.createTemp('cover-size-');
    addTearDown(() async { await directory.delete(recursive: true); });
    final cache = File('${directory.path}/large.png');
    await cache.writeAsBytes(List<int>.filled(
      BookDefinition.maxCoverBytes + 1, 1));
    await expectLater(BookCoverLoader.load(PlatformFile(
      name: 'large.png', size: 100, path: cache.path,
    )), throwsFormatException);
  });
}
