import 'dart:convert';
import 'dart:io';
import 'package:domolia/logging/app_logger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('writes all levels in order with UTC timestamps', () async {
    final storage = MemoryAppLogStorage();
    final logger = AppLogger(storage: storage);
    for (final level in AppLogLevel.values) {
      logger.log(level, level.name, component: 'unit');
    }
    await logger.flush();
    final entries = await logger.entries();
    expect(entries.map((entry) => entry.level), AppLogLevel.values);
    expect(entries.map((entry) => entry.message), AppLogLevel.values.map((level) => level.name));
    expect(entries.every((entry) => entry.timestamp.isUtc), true);
    expect(storage.lines.every((line) => jsonDecode(line) is Map), true);
  });

  test('concurrent calls are serialized and clearing allows further writes', () async {
    final logger = AppLogger(storage: MemoryAppLogStorage());
    for (var i = 0; i < 500; i++) {
      logger.log(AppLogLevel.info, 'event-$i');
    }
    await logger.flush();
    expect((await logger.entries()).length, 500);
    await logger.clear();
    expect(await logger.entries(), isEmpty);
    logger.log(AppLogLevel.info, 'after clear');
    await logger.flush();
    expect((await logger.entries()).single.message, 'after clear');
  });

  test('file storage persists through recreation and rotates oldest files', () async {
    final directory = await Directory.systemTemp.createTemp('domolia-logging-');
    addTearDown(() async { await directory.delete(recursive: true); });
    final first = AppLogger(storage: FileAppLogStorage(
      directory, maxFiles: 3, maxFileBytes: 300));
    for (var i = 0; i < 30; i++) {
      first.log(AppLogLevel.debug, 'line $i');
    }
    await first.flush();
    final second = AppLogger(storage: FileAppLogStorage(
      directory, maxFiles: 3, maxFileBytes: 300));
    final entries = await second.entries();
    expect(entries, isNotEmpty);
    expect(entries.last.message, 'line 29');
    expect(entries.length, lessThan(30));
    final files = directory.listSync().whereType<File>().toList();
    expect(files.length, lessThanOrEqualTo(3));
    for (final file in files) {
      expect(await file.length(), lessThanOrEqualTo(300));
    }
    await second.clear();
    expect(await second.entries(), isEmpty);
  });

  test('secrets are redacted from messages and metadata by key', () async {
    final logger = AppLogger(storage: MemoryAppLogStorage());
    logger.log(AppLogLevel.error, 'Authorization: Bearer sk-verysecret12345',
      details: const {'password': 'hard-to-guess', 'accessToken': 'opaque-token', 'count': 5},
      error: Exception('never include this exception body'));
    await logger.flush();
    final snapshot = await logger.snapshot();
    expect(snapshot, isNot(contains('verysecret12345')));
    expect(snapshot, isNot(contains('hard-to-guess')));
    expect(snapshot, isNot(contains('opaque-token')));
    expect(snapshot, isNot(contains('never include this exception body')));
    expect(snapshot, contains('[REDACTED]'));
  });
}
