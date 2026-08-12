import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'package:omi/backend/preferences.dart';

/// Lightweight debug log manager to persist important diagnostics when
/// developer debug logging is enabled.
class DebugLogManager {
  DebugLogManager._();

  // The on-disk log carries a fixed placeholder name for its whole life. It is
  // a working file, not a deliverable: the descriptive
  // `<os>_<app>_<fw>_omi_offline_debug_<YYYYMMDD>.log` name is applied only when
  // the user shares it (see `shareFileName`), so the name reflects the versions
  // and the day it was actually handed over rather than whenever the toggle
  // happened to be flipped.
  //
  // Keep the `omi_debug_` prefix and `.log` suffix: the native wedge-diagnostics
  // writer (`WedgeDiagnostics.currentLogFile`) locates this file by that pattern
  // and appends to it from outside Dart.
  static const String _tempFileName = 'omi_debug_current.log';

  // Single persistent file is capped here. On overflow the most recent half is
  // kept (see _rotateIfNeeded) rather than the whole file being wiped, so the
  // log stays a sliding window of recent activity spanning several days.
  static const int _maxFileBytes = 20 * 1024 * 1024; // 20MB cap

  static File? _file;
  static final DateFormat _ts = DateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'");
  static bool _initializing = false;

  /// Forces logging on/off regardless of SharedPreferences. Set this in
  /// background isolates, where SharedPreferences isn't initialised and
  /// `devLogsToFileEnabled` would otherwise always read its `false` default,
  /// silently dropping every log line. The main isolate reads the real pref
  /// and forwards it across the isolate boundary.
  static bool? enabledOverride;

  static bool get isEnabled => enabledOverride ?? SharedPreferencesUtil().devLogsToFileEnabled;

  // Resolves the current log file. Reusing the existing omi_debug_*.log (rather
  // than always creating a new one) keeps the main and background isolates on
  // the same file without sharing memory, preserves the file across app
  // restarts, and adopts a date-named file left by a build that predates the
  // placeholder name. The create path runs only when none exists, and the name
  // is fixed, so even two isolates cold-creating at once land on the same path.
  // Deleting/replacing files is done explicitly by setEnabled/clear, not here.
  static Future<File> _ensureFile() async {
    if (_file != null) return _file!;
    if (_initializing) {
      // Wait briefly if concurrent init
      for (int i = 0; i < 10 && _file == null; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      if (_file != null) return _file!;
    }
    _initializing = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final existing = await listLogFiles(); // active file first
      final f = existing.isNotEmpty ? existing.first : File('${dir.path}/$_tempFileName');
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
    SharedPreferencesUtil().devLogsToFileEnabled = enabled;
    if (enabled) {
      // Turning on: clean up any old log files, then open a fresh one.
      await _startFreshFile();
    } else {
      // Turning off: remove the log file entirely.
      await _deleteAllLogFiles();
    }
  }

  /// Deletes every debug log file and drops the cached handle.
  static Future<void> _deleteAllLogFiles() async {
    for (final f in await listLogFiles()) {
      try {
        await f.delete();
      } catch (_) {}
    }
    _file = null;
  }

  /// Deletes any existing log files, then opens a fresh one.
  static Future<void> _startFreshFile() async {
    await _deleteAllLogFiles();
    await _ensureFile();
  }

  static String _timestamp() => _ts.format(DateTime.now().toUtc());

  static Future<void> _rotateIfNeeded(File f) async {
    try {
      final len = await f.length();
      if (len <= _maxFileBytes) return;
      // Keep the most recent half so the log stays a sliding window of recent
      // activity instead of being wiped wholesale on overflow.
      const keep = _maxFileBytes ~/ 2;
      final raf = await f.open();
      late final List<int> tail;
      try {
        await raf.setPosition(len - keep);
        tail = await raf.read(keep);
      } finally {
        await raf.close();
      }
      // Drop the partial first line so the file starts on a clean boundary.
      final nl = tail.indexOf(0x0A);
      final body = (nl >= 0 && nl + 1 < tail.length) ? tail.sublist(nl + 1) : tail;
      await f.writeAsBytes(body, mode: FileMode.write, flush: true);
    } catch (_) {}
  }

  static Future<void> _append(String line) async {
    if (!isEnabled) return;
    try {
      final f = await _ensureFile();
      await _rotateIfNeeded(f);
      await f.writeAsString('$line\n', mode: FileMode.append, flush: false);
    } catch (_) {
      // Swallow to avoid impacting app flow
    }
  }

  static Future<List<Map<String, dynamic>>> getRecentLogs({int limit = 10}) async {
    try {
      final f = await _ensureFile();
      if (!await f.exists()) return [];
      // Read only the tail: the window shows the newest `limit` lines, and the
      // single persistent file can be many MB — re-reading all of it on the 2 s
      // poll would be wasteful. 256 KB easily covers the displayed lines.
      const tailBytes = 256 * 1024;
      final raf = await f.open();
      late final List<int> bytes;
      int start;
      try {
        final len = await raf.length();
        start = len > tailBytes ? len - tailBytes : 0;
        await raf.setPosition(start);
        bytes = await raf.read(len - start);
      } finally {
        await raf.close();
      }
      // Decode leniently. Strict UTF-8 (allowMalformed: false, the readAsLines
      // default) throws FormatException on a single bad byte — e.g. a torn append
      // when the main and background isolates write concurrently — which the
      // outer catch turns into an empty list, blanking the window even though the
      // file is fine to share. Replace bad bytes with U+FFFD instead of failing.
      final text = utf8.decode(bytes, allowMalformed: true);
      var lines = const LineSplitter().convert(text);
      // If we started mid-file the first line is partial — drop it.
      if (start > 0 && lines.isNotEmpty) lines = lines.sublist(1);
      return lines.reversed
          .take(limit)
          .map((l) {
            try {
              return jsonDecode(l) as Map<String, dynamic>;
            } catch (_) {
              return null;
            }
          })
          .whereType<Map<String, dynamic>>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Deletes the current log file and starts a new one.
  static Future<void> clear() async {
    await _startFreshFile();
  }

  /// The name the log is given when the user shares it. The on-disk file is a
  /// placeholder (`_tempFileName`); this is where it acquires an identity, so
  /// the date is the day of the share and the versions are the ones in force
  /// then. Lowercase and underscored — no spaces or apostrophes — so it is easy
  /// to work with on upload/save targets.
  static String shareFileName({required String os, required String appVersion, required String fwVersion}) {
    final d = DateTime.now().toUtc();
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${os}_${appVersion}_${fwVersion}_omi_offline_debug_$y$m$day.log';
  }

  /// Returns the debug log file(s), the active one first — normally just the one.
  static Future<List<File>> listLogFiles() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final files = <File>[];
      await for (final entity in Directory(dir.path).list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.isNotEmpty ? entity.uri.pathSegments.last : '';
        if (!name.startsWith('omi_debug_') || !name.endsWith('.log')) continue;
        files.add(entity);
      }
      // The active file must come first: `_ensureFile` appends to `files.first`
      // and the share path takes it as *the* log. It is sorted ahead of anything
      // else explicitly rather than relying on 'c' outranking a digit in ASCII.
      // The rest sort by name descending, which for the retired
      // `omi_debug_YYYYMMDD.log` scheme is newest-first.
      files.sort((a, b) {
        final an = a.uri.pathSegments.last;
        final bn = b.uri.pathSegments.last;
        if (an == _tempFileName) return -1;
        if (bn == _tempFileName) return 1;
        return bn.compareTo(an);
      });
      return files;
    } catch (_) {
      return const <File>[];
    }
  }

  static Future<void> logError(Object error,
      [StackTrace? stack, String? message, Map<String, Object?> extra = const {}]) async {
    final payload = <String, Object?>{
      'ts': _timestamp(),
      'level': 'ERROR',
      'message': message ?? error.toString(),
      if (stack != null) 'stack': stack.toString(),
      if (extra.isNotEmpty) 'extra': extra,
    };
    await _append(jsonEncode(payload));
  }

  static Future<void> logWarning(String message, [Map<String, Object?> extra = const {}]) async {
    final payload = <String, Object?>{
      'ts': _timestamp(),
      'level': 'WARN',
      'message': message,
      if (extra.isNotEmpty) 'extra': extra,
    };
    await _append(jsonEncode(payload));
  }

  static Future<void> logInfo(String message, [Map<String, Object?> extra = const {}]) async {
    final payload = <String, Object?>{
      'ts': _timestamp(),
      'level': 'INFO',
      'message': message,
      if (extra.isNotEmpty) 'extra': extra,
    };
    await _append(jsonEncode(payload));
  }

  /// Logs a structured diagnostic event (e.g., device/transcription connection changes)
  static Future<void> logEvent(String type, Map<String, Object?> fields) async {
    final payload = <String, Object?>{
      'timestamp': _timestamp(),
      'level': 'EVENT',
      'type': type,
      ...fields,
    };
    await _append(jsonEncode(payload));
  }

  /// Stamps the app's own version on every launch, so any behaviour change in
  /// the log can be attributed to (or cleared of) an app update.
  ///
  /// Emitted unconditionally rather than only when the version moved: the log is
  /// a sliding window that can be cleared or start mid-life, so a line that only
  /// appeared on change would leave stretches with no version at all. The
  /// `app_version_changed` flag is what marks the transition, and it is only set
  /// when a previous version was actually recorded — a first run has nothing to
  /// have changed from.
  ///
  /// [lastKnownFirmware] is the paired device's last-read DIS revision, passed
  /// in because at launch nothing is connected yet. It is the caller's cached
  /// value, and the connect a moment later confirms it via [logDeviceVersion].
  static Future<void> logAppStart({String? lastKnownFirmware}) async {
    String appVersion = 'unknown';
    String buildNumber = 'unknown';
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = info.version;
      buildNumber = info.buildNumber;
    } catch (_) {}

    final prefs = SharedPreferencesUtil();
    final previous = prefs.lastLoggedAppVersion;
    final changed = previous.isNotEmpty && previous != appVersion;

    await logEvent('app_start', {
      'app_version': appVersion,
      'build_number': buildNumber,
      'os': Platform.operatingSystem,
      'os_version': Platform.operatingSystemVersion,
      'last_known_firmware': (lastKnownFirmware?.isNotEmpty ?? false) ? lastKnownFirmware : 'unknown',
      if (changed) 'app_version_changed': true,
      if (changed) 'previous_app_version': previous,
    });

    if (previous != appVersion) prefs.lastLoggedAppVersion = appVersion;
  }

  /// Stamps the device's firmware identity on every connect, and reports whether
  /// the Omi rebooted since the last connect.
  ///
  /// The two facts are logged together because neither implies the other:
  ///
  ///  - A DFU always ends in a reboot (mcumgr resets to swap the image; the
  ///    post-DFU bond wipe depends on that next boot), but it does **not** always
  ///    change the revision string — a same-version reflash sends only the net
  ///    core, and a dev/production swap can share a version. So a reboot with an
  ///    unchanged version still deserves a second look.
  ///  - Equally, a reboot is usually not a flash at all: a crash, a battery
  ///    brownout, a Reboot/Shutdown command. The reset cause from `0x0061`
  ///    separates those.
  ///
  /// [uptimeMs] is the device's LIVE uptime (`0x0062`), not the latched
  /// prior-boot value from `0x0061`. Pass null when the read was skipped (a sync
  /// holds the storage lock): reboot detection is then simply not evaluated, and
  /// the stored uptime is left alone so the next connect still compares against
  /// a real reading rather than a hole.
  static Future<void> logDeviceVersion({
    required String firmwareRevision,
    String? hardwareRevision,
    String? modelNumber,
    int? uptimeMs,
    String? resetCause,
  }) async {
    final prefs = SharedPreferencesUtil();
    final previousFw = prefs.lastLoggedFirmwareRevision;
    final fwChanged = previousFw.isNotEmpty && previousFw != firmwareRevision;

    final previousUptimeMs = prefs.lastSeenDeviceUptimeMs;
    // Strictly lower, not merely different: uptime climbs within one boot, and
    // several connects during the same boot must not each read as a reboot.
    final rebooted = uptimeMs != null && previousUptimeMs > 0 && uptimeMs < previousUptimeMs;

    await logEvent('device_version', {
      'firmware_revision': firmwareRevision,
      if (hardwareRevision != null) 'hardware_revision': hardwareRevision,
      if (modelNumber != null) 'model_number': modelNumber,
      if (uptimeMs != null) 'uptime_ms': uptimeMs,
      if (resetCause != null) 'reset_cause': resetCause,
      if (fwChanged) 'firmware_changed': true,
      if (fwChanged) 'previous_firmware': previousFw,
      if (rebooted) 'rebooted': true,
      if (rebooted) 'previous_uptime_ms': previousUptimeMs,
    });

    if (previousFw != firmwareRevision) prefs.lastLoggedFirmwareRevision = firmwareRevision;
    if (uptimeMs != null) prefs.lastSeenDeviceUptimeMs = uptimeMs;
  }
}
