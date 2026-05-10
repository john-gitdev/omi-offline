import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/devices/device_crash_log.dart';

/// Manages persistence of device crash logs to daily files.
/// Matches the implementation of DebugLogManager for consistency.
class DeviceCrashLogManager {
  DeviceCrashLogManager._();

  static String _dailyFileName() {
    final d = DateTime.now().toUtc();
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return 'omi_crash_$y$m$day.log';
  }

  static const int _maxFileBytes = 2 * 1024 * 1024; // 2MB cap (crash logs are small)

  static File? _file;
  static bool _initializing = false;
  static bool _prunedOnce = false;

  static bool get isEnabled => SharedPreferencesUtil().devCrashLogsToFileEnabled;

  static Future<File> _ensureFile() async {
    if (_file != null) return _file!;
    if (_initializing) {
      for (int i = 0; i < 10 && _file == null; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      if (_file != null) return _file!;
    }
    _initializing = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      if (!_prunedOnce) {
        await _pruneOldLogs(retainDays: 3);
        _prunedOnce = true;
      }
      final f = File('${dir.path}/${_dailyFileName()}');
      if (!(await f.exists())) {
        await f.create(recursive: true);
      }
      _file = f;
      return f;
    } finally {
      _initializing = false;
    }
  }

  static Future<File?> getLogFile() async {
    try {
      return await _ensureFile();
    } catch (_) {
      return null;
    }
  }

  static Future<void> setEnabled(bool enabled) async {
    SharedPreferencesUtil().devCrashLogsToFileEnabled = enabled;
    if (!enabled) return;
    await _ensureFile();
    await _pruneOldLogs(retainDays: 3);
  }

  static Future<void> _rotateIfNeeded(File f) async {
    try {
      final len = await f.length();
      if (len <= _maxFileBytes) return;
      await f.writeAsString('', mode: FileMode.write, flush: true);
    } catch (_) {}
  }

  static Future<void> logCrash(DeviceCrashLog log) async {
    if (!isEnabled) return;
    try {
      final f = await _ensureFile();
      await _rotateIfNeeded(f);
      final line = jsonEncode({
        ...log.toJson(),
        'cause_label': log.causeLabel,
        'uptime_label': log.uptimeStr,
      });
      await f.writeAsString('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      final f = await _ensureFile();
      await f.writeAsString('', mode: FileMode.write, flush: true);
      // Also delete any other crash logs in the directory
      final dir = await getApplicationDocumentsDirectory();
      await for (final entity in Directory(dir.path).list()) {
        if (entity is File && entity.path.split('/').last.startsWith('omi_crash_')) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }

  static Future<List<File>> listLogFiles() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final files = <File>[];
      await for (final entity in Directory(dir.path).list()) {
        if (entity is! File) continue;
        final name = entity.path.split('/').last;
        if (!name.startsWith('omi_crash_') || !name.endsWith('.log')) continue;
        files.add(entity);
      }
      files.sort((a, b) => b.path.compareTo(a.path));
      return files;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _pruneOldLogs({int retainDays = 7}) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final now = DateTime.now().toUtc();
      await for (final entity in Directory(dir.path).list()) {
        if (entity is! File) continue;
        final name = entity.path.split('/').last;
        if (!name.startsWith('omi_crash_') || !name.endsWith('.log')) continue;
        final datePart = name.replaceAll('omi_crash_', '').replaceAll('.log', '');
        if (datePart.length != 8) continue;
        final y = int.tryParse(datePart.substring(0, 4));
        final m = int.tryParse(datePart.substring(4, 6));
        final d = int.tryParse(datePart.substring(6, 8));
        if (y == null || m == null || d == null) continue;
        final fileDate = DateTime.utc(y, m, d);
        if (now.difference(fileDate).inDays > retainDays) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }
}
