import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

enum AppLogLevel { trace, debug, info, warning, error }

class AppLogEntry {
  const AppLogEntry({
    required this.timestamp, required this.level, required this.component,
    required this.message, this.details = const {}, this.errorType, this.stackTrace,
  });
  final DateTime timestamp;
  final AppLogLevel level;
  final String component;
  final String message;
  final Map<String, Object?> details;
  final String? errorType;
  final String? stackTrace;

  Map<String, Object?> toJson() => {
    'timestamp': timestamp.toUtc().toIso8601String(),
    'level': level.name.toUpperCase(), 'component': component, 'message': message,
    if (details.isNotEmpty) 'details': details,
    if (errorType != null) 'errorType': errorType,
    if (stackTrace != null) 'stackTrace': stackTrace,
  };

  factory AppLogEntry.fromJson(Map<String, dynamic> data) => AppLogEntry(
    timestamp: DateTime.parse(data['timestamp'] as String),
    level: AppLogLevel.values.firstWhere(
      (level) => level.name.toUpperCase() == data['level']),
    component: data['component'] as String,
    message: data['message'] as String,
    details: Map<String, Object?>.from(data['details'] as Map? ?? const {}),
    errorType: data['errorType'] as String?,
    stackTrace: data['stackTrace'] as String?,
  );
}

abstract interface class AppLogStorage {
  Future<void> append(String line);
  Future<List<String>> readLines();
  Future<void> clear();
}

class MemoryAppLogStorage implements AppLogStorage {
  final List<String> lines = [];
  @override
  Future<void> append(String line) async { lines.add(line); }
  @override
  Future<List<String>> readLines() async => List.of(lines);
  @override
  Future<void> clear() async { lines.clear(); }
}

/// Active file index 0, older files at larger indices.
class FileAppLogStorage implements AppLogStorage {
  FileAppLogStorage(this.directory, {this.maxFiles = 4, this.maxFileBytes = 256 * 1024})
      : assert(maxFiles > 0), assert(maxFileBytes > 0);
  final Directory directory;
  final int maxFiles;
  final int maxFileBytes;
  File _file(int index) => File(path.join(directory.path, 'domolia-$index.jsonl'));

  @override
  Future<void> append(String line) async {
    await directory.create(recursive: true);
    final current = _file(0);
    final size = await current.exists() ? await current.length() : 0;
    if (size > 0 && size + utf8.encode(line).length > maxFileBytes) {
      for (var i = maxFiles - 1; i >= 1; i--) {
        final destination = _file(i);
        if (await destination.exists()) await destination.delete();
        final source = _file(i - 1);
        if (await source.exists()) await source.rename(destination.path);
      }
    }
    await current.writeAsString(line, mode: FileMode.append, flush: true);
  }
  @override
  Future<List<String>> readLines() async {
    final result = <String>[];
    for (var i = maxFiles - 1; i >= 0; i--) {
      final file = _file(i);
      if (await file.exists()) {
        for (final line in await file.readAsLines()) {
          if (line.isNotEmpty) result.add('$line\n');
        }
      }
    }
    return result;
  }
  @override
  Future<void> clear() async {
    if (!await directory.exists()) return;
    for (var i = 0; i < maxFiles; i++) {
      final file = _file(i);
      if (await file.exists()) await file.delete();
    }
  }
}

/// File mutations and snapshot reads are serialized by one queue.
class AppLogger {
  AppLogger({required this.storage});
  final AppLogStorage storage;
  static AppLogger _current = AppLogger(storage: MemoryAppLogStorage());
  static AppLogger get current => _current;
  static Future<void> initialize() async {
    try {
      final support = await getApplicationSupportDirectory();
      _current = AppLogger(
        storage: FileAppLogStorage(Directory(path.join(support.path, 'logs'))),
      );
      info('Journal initialisé', component: 'app');
      await _current.flush();
    } catch (_) {
      _current = AppLogger(storage: MemoryAppLogStorage());
      warning('Stockage du journal indisponible', component: 'app');
    }
  }

  int failedOperations = 0;
  Future<void> _tail = Future<void>.value();
  Future<void> _enqueue(Future<void> Function() action) {
    _tail = _tail.then((_) => action()).catchError((Object _) {
      failedOperations++;
    });
    return _tail;
  }
  Future<void> flush() => _tail;

  static String _clean(String input, {int limit = 1000}) {
    var safe = input.replaceAllMapped(
      RegExp(r'(authorization|api[_-]?key|access[_-]?token|password|secret)\s*[:=]\s*\S+',
          caseSensitive: false),
      (match) => '${match.group(1)}=[REDACTED]',
    );
    safe = safe.replaceAll(RegExp(r'Bearer\s+\S+', caseSensitive: false),
        'Bearer [REDACTED]');
    safe = safe.replaceAll(RegExp(r'sk-[A-Za-z0-9_-]{8,}'), '[REDACTED]');
    safe = safe.replaceAll(
      RegExp(r'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]*)?'),
      '[REDACTED]');

    return safe.length > limit ? '${safe.substring(0, limit)}…' : safe;
  }

  /// Pass only static operational messages and simple non-sensitive scalars.
  /// Exception text is deliberately omitted; only its runtime type is retained.
  void log(AppLogLevel level, String message, {
    String component = 'app', Map<String, Object?> details = const {},
    Object? error, StackTrace? stackTrace,
  }) {
    final safeDetails = <String, Object?>{};
    for (final item in details.entries.take(12)) {
      final value = item.value;
      final key = _clean(item.key, limit: 48);
      if (RegExp(r'authorization|token|secret|password|api.?key|credential|cookie|bearer',
          caseSensitive: false).hasMatch(key)) {
        safeDetails[key] = '[REDACTED]';
        continue;
      }
      safeDetails[key] = switch (value) {
        num() || bool() => value,
        String() => _clean(value, limit: 120),
        _ => '[OMITTED]',
      };
    }
    final entry = AppLogEntry(
      timestamp: DateTime.now().toUtc(), level: level,
      component: _clean(component, limit: 64),
      message: _clean(message, limit: 500),
      details: safeDetails,
      errorType: error?.runtimeType.toString(),
      stackTrace: stackTrace == null ? null : _clean(stackTrace.toString(), limit: 4096),
    );
    unawaited(_enqueue(() => storage.append('${jsonEncode(entry.toJson())}\n')));
  }
  static void trace(String message, {String component = 'app', Map<String, Object?> details = const {}}) =>
      _current.log(AppLogLevel.trace, message, component: component, details: details);
  static void debug(String message, {String component = 'app', Map<String, Object?> details = const {}}) =>
      _current.log(AppLogLevel.debug, message, component: component, details: details);
  static void info(String message, {String component = 'app', Map<String, Object?> details = const {}}) =>
      _current.log(AppLogLevel.info, message, component: component, details: details);
  static void warning(String message, {String component = 'app', Map<String, Object?> details = const {}}) =>
      _current.log(AppLogLevel.warning, message, component: component, details: details);
  static void error(String message, {String component = 'app', Object? error, StackTrace? stackTrace, Map<String, Object?> details = const {}}) =>
      _current.log(AppLogLevel.error, message, component: component,
          error: error, stackTrace: stackTrace, details: details);

  Future<String> snapshot() async {
    final result = Completer<String>();
    await _enqueue(() async {
      final lines = await storage.readLines();
      result.complete(lines.join());
    });
    return result.isCompleted ? result.future : '';
  }
  Future<List<AppLogEntry>> entries() async {
    final result = <AppLogEntry>[];
    for (final line in const LineSplitter().convert(await snapshot())) {
      try {
        result.add(AppLogEntry.fromJson(jsonDecode(line) as Map<String, dynamic>));
      } catch (_) {
        // Ignore any interrupted final JSONL record.
      }
    }
    return result;
  }
  Future<void> clear() => _enqueue(storage.clear);
}
