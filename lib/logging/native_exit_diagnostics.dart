import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

/// Android 11+ exposes the previous process exit reason even when a crash
/// occurs inside JNI and no Dart exception handler can run.
///
/// The diagnostic records only reason + memory metrics, never user text.
class NativeExitDiagnostics {
  static const _channel = MethodChannel('domolia/native_exit');
  static const _lastLoggedKey = 'native-exit-last-reported-ms';

  static Future<void> logLastUnexpectedExit() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      final data = await _channel.invokeMapMethod<String, dynamic>(
          'lastProcessExit');
      if (data == null) {
        return;
      }
      final reason = data['reason'] as String?;
      if (!const {
        'CRASH', 'CRASH_NATIVE', 'LOW_MEMORY', 'ANR', 'SIGNALED',
        'EXCESSIVE_RESOURCE_USAGE'
      }.contains(reason)) {
        return;
      }
      final timestampMs = (data['timestampMs'] as num?)?.toInt();
      if (timestampMs == null || timestampMs <= 0) {
        return;
      }
      final happened = DateTime.fromMillisecondsSinceEpoch(timestampMs);
      final age = DateTime.now().difference(happened);
      if (age.isNegative || age > const Duration(days: 2)) {
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getInt(_lastLoggedKey) == timestampMs) {
        return;
      }
      await prefs.setInt(_lastLoggedKey, timestampMs);
      AppLogger.warning('Android : arrêt inattendu du processus précédent',
          component: 'native_exit', details: {
            'reason': reason ?? 'UNKNOWN',
            'reasonCode': data['reasonCode'],
            'exitTimestampMs': timestampMs,
            'pssKb': data['pssKb'],
            'rssKb': data['rssKb'],
            'importance': data['importance'],
          });
      await AppLogger.current.flush();
    } catch (error) {
      // Never prevent application startup when the diagnostic is unavailable.
      AppLogger.debug('Diagnostic Android des arrêts indisponible',
          component: 'native_exit', details: {
            'type': error.runtimeType.toString()
          });
    }
  }
}
