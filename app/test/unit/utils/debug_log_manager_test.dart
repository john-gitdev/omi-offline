import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/utils/debug_log_manager.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockPathProvider extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  String? docsPath;
  String? tempPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
  @override
  Future<String?> getTemporaryPath() async => tempPath;
}

/// The UTC day stamp `shareFileName` appends.
String _utcStamp() {
  final d = DateTime.now().toUtc();
  return '${d.year.toString().padLeft(4, '0')}'
      '${d.month.toString().padLeft(2, '0')}'
      '${d.day.toString().padLeft(2, '0')}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;
  // Separate from docsDir: prepareShareFile writes its named copy under the
  // temp dir precisely so the export never lands among the live log files.
  late Directory tempDir;
  late MockPathProvider mockPathProvider;

  setUpAll(() {
    docsDir = Directory.systemTemp.createTempSync('debug_log_manager_test');
    tempDir = Directory.systemTemp.createTempSync('debug_log_manager_tmp');
  });

  tearDownAll(() {
    for (final d in [docsDir, tempDir]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  setUp(() async {
    mockPathProvider = MockPathProvider()
      ..docsPath = docsDir.path
      ..tempPath = tempDir.path;
    PathProviderPlatform.instance = mockPathProvider;

    SharedPreferences.setMockInitialValues({'devLogsToFileEnabled': true});

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (MethodCall methodCall) async {
      return null;
    });

    await SharedPreferencesUtil.init();

    // Clear logs from previous tests
    await DebugLogManager.clear();
  });

  tearDown(() async {
    // Clear logs
    await DebugLogManager.clear();
    // Delete files in both directories to start fresh
    for (var entity in [...docsDir.listSync(), ...tempDir.listSync()]) {
      entity.deleteSync(recursive: true);
    }
  });

  group('Core logging tests', () {
    test('getLogFile uses a fixed placeholder name, not a dated one', () async {
      final file = await DebugLogManager.getLogFile();
      expect(file, isNotNull);
      expect(file!.existsSync(), isTrue);

      final fileName = file.uri.pathSegments.last;
      // The date belongs to the share name, not the working file.
      expect(fileName, 'omi_debug_current.log');
      // The native wedge-diagnostics writer finds this file by prefix + suffix.
      expect(fileName.startsWith('omi_debug_'), isTrue);
      expect(fileName.endsWith('.log'), isTrue);
    });

    test('shareFileName stamps app/fw and the share date, with no OS segment', () async {
      final name = DebugLogManager.shareFileName(appVersion: '0.33.8', fwVersion: 'oo-3.0.2');

      expect(name, '0.33.8_oo-3.0.2_omi_offline_debug_${_utcStamp()}.log');
      // Android-only fork — the old leading `android_` distinguished nothing.
      expect(name.startsWith('android_'), isFalse);
    });

    test('prepareShareFile hands over a file whose own name is the share name', () async {
      // The name has to be the basename on disk, not XFile.name or the share
      // subject: share_plus returns a path-bearing XFile untouched, and its
      // Android side names the content URI from File(path).name. Targets that
      // read the display name (Files / "internal storage") saw the placeholder.
      await DebugLogManager.logInfo('shipped in the export');

      final exported = await DebugLogManager.prepareShareFile(appVersion: '0.33.8', fwVersion: 'oo-3.0.2');

      expect(exported, isNotNull);
      expect(exported!.uri.pathSegments.last, '0.33.8_oo-3.0.2_omi_offline_debug_${_utcStamp()}.log');
      expect(await exported.readAsString(), contains('shipped in the export'));
      // The live log keeps its fixed name — the background isolate and the
      // native wedge writer both find it by that.
      expect((await DebugLogManager.getLogFile())!.uri.pathSegments.last, 'omi_debug_current.log');
    });

    test('prepareShareFile clears earlier exports instead of accumulating copies', () async {
      await DebugLogManager.logInfo('entry');

      final stale = await DebugLogManager.prepareShareFile(appVersion: '0.33.7', fwVersion: 'oo-3.0.1');
      final fresh = await DebugLogManager.prepareShareFile(appVersion: '0.33.8', fwVersion: 'oo-3.0.2');

      expect(fresh!.existsSync(), isTrue);
      // Differing versions mean the names never collide, so without the sweep
      // every share would leave another copy of a 20 MB-capped log behind.
      expect(stale!.existsSync(), isFalse);
      expect(fresh.parent.listSync().length, 1);
    });

    test('prepareShareFile returns null when there is no log to share', () async {
      await DebugLogManager.setEnabled(false); // deletes every log file

      expect(await DebugLogManager.prepareShareFile(appVersion: '0.33.8', fwVersion: 'oo-3.0.2'), isNull);
    });

    test('appends logInfo correctly', () async {
      await DebugLogManager.logInfo('Test info log', {'key': 'value'});

      final file = await DebugLogManager.getLogFile();
      final content = await file!.readAsString();

      expect(content, isNotEmpty);
      final jsonLog = jsonDecode(content.trim().split('\n').last);
      expect(jsonLog['level'], 'INFO');
      expect(jsonLog['message'], 'Test info log');
      expect(jsonLog['extra']['key'], 'value');
      expect(jsonLog.containsKey('ts'), isTrue);
    });

    test('appends logWarning correctly', () async {
      await DebugLogManager.logWarning('Test warning log');

      final file = await DebugLogManager.getLogFile();
      final content = await file!.readAsString();

      final jsonLog = jsonDecode(content.trim().split('\n').last);
      expect(jsonLog['level'], 'WARN');
      expect(jsonLog['message'], 'Test warning log');
    });

    test('appends logError correctly', () async {
      await DebugLogManager.logError(Exception('Test error'), StackTrace.empty, 'Error msg', {'errKey': 123});

      final file = await DebugLogManager.getLogFile();
      final content = await file!.readAsString();

      final jsonLog = jsonDecode(content.trim().split('\n').last);
      expect(jsonLog['level'], 'ERROR');
      expect(jsonLog['message'], 'Error msg');
      expect(jsonLog['extra']['errKey'], 123);
      expect(jsonLog.containsKey('stack'), isTrue);
    });

    test('appends logEvent correctly', () async {
      await DebugLogManager.logEvent('CONNECTION', {'status': 'connected'});

      final file = await DebugLogManager.getLogFile();
      final content = await file!.readAsString();

      final jsonLog = jsonDecode(content.trim().split('\n').last);
      expect(jsonLog['level'], 'EVENT');
      expect(jsonLog['type'], 'CONNECTION');
      expect(jsonLog['status'], 'connected');
    });

    test('setEnabled(false) prevents logging', () async {
      await DebugLogManager.setEnabled(false);
      expect(DebugLogManager.isEnabled, false);

      await DebugLogManager.logInfo('Should not be logged');

      final file = await DebugLogManager.getLogFile();
      final content = await file!.readAsString();

      // Should be empty because clear() runs before each test
      expect(content.trim(), isEmpty);
    });
  });

  group('Concurrent append integrity', () {
    // Regression for the fault that destroyed 26% of the 2026-08-17 wedge log
    // (BLE_Research.md, Wedge 9). `Logger.debug`/`info`/`warning` are
    // synchronous `void` and call the async log methods **un-awaited**, so real
    // callers routinely have many appends in flight at once. Dart's
    // `FileMode.append` seeks to EOF at open rather than using O_APPEND, so
    // before the write lock every one of them opened at the same offset and
    // overwrote its neighbours.
    //
    // Fires un-awaited on purpose: awaiting each call serialises them at the
    // call site and the bug cannot reproduce. Reverting the mutex in _append
    // must fail this test.
    test('interleaved un-awaited appends never tear a line', () async {
      const count = 200;
      final pending = <Future<void>>[];
      for (var i = 0; i < count; i++) {
        // Deliberately uneven lengths. The corruption signature is a longer
        // record's tail surviving past a shorter one's end, so equal-length
        // lines would hide it.
        pending.add(DebugLogManager.logInfo('line $i ${'x' * (i % 40)}'));
      }
      await Future.wait(pending);

      final file = await DebugLogManager.getLogFile();
      final lines = (await file!.readAsString()).trim().split('\n');

      expect(lines.length, count, reason: 'every append must produce exactly one line');
      final seen = <int>{};
      for (final l in lines) {
        // jsonDecode throws on a spliced or truncated record — the exact
        // failure a torn append produces.
        final decoded = jsonDecode(l) as Map<String, dynamic>;
        expect(decoded['level'], 'INFO');
        final message = decoded['message'] as String;
        seen.add(int.parse(message.split(' ')[1]));
      }
      // Not just "nothing is malformed": an overwrite loses a record whole, and
      // that leaves the survivors individually valid.
      expect(seen.length, count, reason: 'no record may be lost to an overwrite');
    });

    test('appends interleaved with a concurrent clear() stay well-formed', () async {
      // clear() deliberately does not take the write lock (see _append). It must
      // still never leave a half-written line behind.
      final pending = <Future<void>>[];
      for (var i = 0; i < 60; i++) {
        pending.add(DebugLogManager.logInfo('pre-clear $i'));
      }
      final clearing = DebugLogManager.clear();
      for (var i = 0; i < 60; i++) {
        pending.add(DebugLogManager.logInfo('post-clear $i'));
      }
      await Future.wait([...pending, clearing]);

      final file = await DebugLogManager.getLogFile();
      final content = await file!.readAsString();
      for (final l in content.trim().split('\n')) {
        if (l.isEmpty) continue;
        expect(() => jsonDecode(l), returnsNormally, reason: 'torn line survived a concurrent clear: $l');
      }
    });
  });

  group('Advanced logging tests', () {
    test('clear() empties the log file', () async {
      await DebugLogManager.logInfo('This should be cleared');

      var file = await DebugLogManager.getLogFile();
      var content = await file!.readAsString();
      expect(content, isNotEmpty);

      await DebugLogManager.clear();

      content = await file.readAsString();
      expect(content, isEmpty);
    });

    test('setEnabled(false) deletes the log file', () async {
      await DebugLogManager.logInfo('some log');
      final path = (await DebugLogManager.getLogFile())!.path;
      expect(File(path).existsSync(), isTrue);

      await DebugLogManager.setEnabled(false);
      expect(File(path).existsSync(), isFalse);
    });

    test('setEnabled(true) cleans up old log files and opens a fresh one', () async {
      // Strays from a previous scheme that the toggle-on should clean up.
      await File('${docsDir.path}/omi_debug_20230101.log').writeAsString('old\n');
      await File('${docsDir.path}/omi_debug_20230102.log').writeAsString('old\n');

      await DebugLogManager.setEnabled(true);

      final files = await DebugLogManager.listLogFiles();
      expect(files.length, 1); // strays gone, single fresh file
      expect(await files.first.readAsString(), isEmpty);
    });

    test('listLogFiles() correctly lists valid log files', () async {
      // Setup multiple files in docsDir
      final file1 = File('${docsDir.path}/omi_debug_20230101.log');
      final file2 = File('${docsDir.path}/omi_debug_20230102.log');
      final invalidFile = File('${docsDir.path}/other_file.txt');

      await file1.create();
      await file2.create();
      await invalidFile.create();

      final logFiles = await DebugLogManager.listLogFiles();

      // Should find the currently active log file + the two we just created
      expect(logFiles.length, 3);

      final fileNames = logFiles.map((f) => f.uri.pathSegments.last).toList();
      expect(fileNames.contains('omi_debug_20230101.log'), isTrue);
      expect(fileNames.contains('omi_debug_20230102.log'), isTrue);
      expect(fileNames.contains('other_file.txt'), isFalse);

      // The active file sorts FIRST, ahead of any stray from the retired dated
      // scheme. Both _ensureFile (which appends to files.first) and the share
      // action (which hands over files.first) depend on this, so a stray left by
      // an older build must not capture either.
      expect(fileNames.first, 'omi_debug_current.log');
    });

    test('a cold resolve with a stray alongside the active file picks the active one', () async {
      // The ordering in listLogFiles only decides anything on a COLD resolve
      // with both files present — once _ensureFile has cached a handle, appends
      // never consult it again. Drop the cached handle the way disabling does,
      // then re-enable the pref directly so _startFreshFile's wipe doesn't
      // remove the very files under test.
      await DebugLogManager.setEnabled(false);
      SharedPreferencesUtil().devLogsToFileEnabled = true;
      await File('${docsDir.path}/omi_debug_20230102.log').writeAsString('old\n');
      await File('${docsDir.path}/omi_debug_current.log').create();

      await DebugLogManager.logInfo('cold resolve');

      expect(await File('${docsDir.path}/omi_debug_current.log').readAsString(), contains('cold resolve'));
      expect(await File('${docsDir.path}/omi_debug_20230102.log').readAsString(), 'old\n');
    });

    test('the firmware stamped at connect is the one reported on the next launch', () async {
      PackageInfo.setMockInitialValues(
        appName: 'omi',
        packageName: 'com.omi.offline',
        version: '0.33.8',
        buildNumber: '338',
        buildSignature: '',
      );

      // A connect records the firmware...
      await DebugLogManager.logDeviceVersion(firmwareRevision: 'oo-3.0.2', uptimeMs: 1000);
      // ...and main() reads it back from the same flat pref on the next launch,
      // which is the whole reason that pref is what main() reads rather than the
      // jsonDecoded btDevice blob.
      await DebugLogManager.logAppStart(
        lastKnownFirmware: SharedPreferencesUtil().lastLoggedFirmwareRevision,
      );

      final line = (await DebugLogManager.getRecentLogs()).first;
      expect(line['type'], 'app_start');
      expect(line['last_known_firmware'], 'oo-3.0.2');
    });

    test('logAppStart stamps the app version and flags a change', () async {
      PackageInfo.setMockInitialValues(
        appName: 'omi',
        packageName: 'com.omi.offline',
        version: '0.33.8',
        buildNumber: '338',
        buildSignature: '',
      );

      // First ever run: the version is recorded, but nothing "changed" — there
      // was no previous version to change from.
      await DebugLogManager.logAppStart(lastKnownFirmware: 'oo-3.0.2');
      var line = (await DebugLogManager.getRecentLogs()).first;
      expect(line['type'], 'app_start');
      expect(line['app_version'], '0.33.8');
      expect(line['build_number'], '338');
      expect(line['last_known_firmware'], 'oo-3.0.2');
      expect(line.containsKey('app_version_changed'), isFalse);

      // Same version again: stamped every launch, still no change.
      await DebugLogManager.logAppStart();
      line = (await DebugLogManager.getRecentLogs()).first;
      expect(line['app_version'], '0.33.8');
      expect(line['last_known_firmware'], 'unknown');
      expect(line.containsKey('app_version_changed'), isFalse);

      PackageInfo.setMockInitialValues(
        appName: 'omi',
        packageName: 'com.omi.offline',
        version: '0.33.9',
        buildNumber: '339',
        buildSignature: '',
      );
      await DebugLogManager.logAppStart();
      line = (await DebugLogManager.getRecentLogs()).first;
      expect(line['app_version'], '0.33.9');
      expect(line['app_version_changed'], isTrue);
      expect(line['previous_app_version'], '0.33.8');
    });

    test('logDeviceVersion flags a firmware change once', () async {
      await DebugLogManager.logDeviceVersion(firmwareRevision: 'oo-3.0.1', uptimeMs: 1000);
      var line = (await DebugLogManager.getRecentLogs()).first;
      expect(line['type'], 'device_version');
      expect(line['firmware_revision'], 'oo-3.0.1');
      expect(line.containsKey('firmware_changed'), isFalse); // nothing to change from

      await DebugLogManager.logDeviceVersion(firmwareRevision: 'oo-3.0.2', uptimeMs: 2000);
      line = (await DebugLogManager.getRecentLogs()).first;
      expect(line['firmware_changed'], isTrue);
      expect(line['previous_firmware'], 'oo-3.0.1');

      // Flagged on the transition only, not on every connect thereafter.
      await DebugLogManager.logDeviceVersion(firmwareRevision: 'oo-3.0.2', uptimeMs: 3000);
      line = (await DebugLogManager.getRecentLogs()).first;
      expect(line.containsKey('firmware_changed'), isFalse);
    });

    test('logDeviceVersion detects a reboot from uptime going backwards', () async {
      await DebugLogManager.logDeviceVersion(firmwareRevision: 'oo-3.0.2', uptimeMs: 60000);
      // Later in the same boot — uptime climbed, so no reboot.
      await DebugLogManager.logDeviceVersion(firmwareRevision: 'oo-3.0.2', uptimeMs: 90000);
      var line = (await DebugLogManager.getRecentLogs()).first;
      expect(line.containsKey('rebooted'), isFalse);

      // Uptime lower than last seen: the device restarted in between. Version
      // unchanged — the case a same-version reflash produces.
      await DebugLogManager.logDeviceVersion(
        firmwareRevision: 'oo-3.0.2',
        uptimeMs: 5000,
        resetCause: 'software reset',
      );
      line = (await DebugLogManager.getRecentLogs()).first;
      expect(line['rebooted'], isTrue);
      expect(line['previous_uptime_ms'], 90000);
      expect(line['reset_cause'], 'software reset');
      expect(line.containsKey('firmware_changed'), isFalse);
    });

    test('logDeviceVersion without an uptime reading neither claims nor loses a reboot', () async {
      await DebugLogManager.logDeviceVersion(firmwareRevision: 'oo-3.0.2', uptimeMs: 90000);

      // A sync held the storage lock, so getDropStats() returned null. The
      // version is still stamped, and the stored uptime must survive untouched.
      await DebugLogManager.logDeviceVersion(firmwareRevision: 'oo-3.0.2');
      var line = (await DebugLogManager.getRecentLogs()).first;
      expect(line['firmware_revision'], 'oo-3.0.2');
      expect(line.containsKey('rebooted'), isFalse);
      expect(line.containsKey('uptime_ms'), isFalse);

      // The next real reading still compares against 90000, not against a hole.
      await DebugLogManager.logDeviceVersion(firmwareRevision: 'oo-3.0.2', uptimeMs: 5000);
      line = (await DebugLogManager.getRecentLogs()).first;
      expect(line['rebooted'], isTrue);
      expect(line['previous_uptime_ms'], 90000);
    });

    test('getRecentLogs safely skips malformed JSON', () async {
      final file = await DebugLogManager.getLogFile();
      await file!.writeAsString('{"level":"INFO","message":"valid log"}\n', mode: FileMode.append);
      await file.writeAsString('this is not valid json\n', mode: FileMode.append);
      await file.writeAsString('{"level":"WARN","message":"another valid log"}\n', mode: FileMode.append);

      final logs = await DebugLogManager.getRecentLogs();
      expect(logs.length, 2);
      expect(logs[0]['message'], 'another valid log');
      expect(logs[1]['message'], 'valid log');
    });

    test('getRecentLogs survives malformed UTF-8 bytes (the blank-window bug)', () async {
      // A torn concurrent append can leave invalid UTF-8 in the file. Strict
      // decoding (readAsLines' default) throws FormatException on the whole read,
      // which the catch turns into [] — blanking the in-app window. Lenient decode
      // must keep the surrounding valid lines instead.
      final file = await DebugLogManager.getLogFile();
      await file!.writeAsString('{"level":"INFO","message":"before"}\n', mode: FileMode.append);
      await file.writeAsBytes([0xFF, 0xFE, 0x0A], mode: FileMode.append); // lone invalid bytes + newline
      await file.writeAsString('{"level":"WARN","message":"after"}\n', mode: FileMode.append);

      final messages = (await DebugLogManager.getRecentLogs()).map((l) => l['message']).toList();
      expect(messages, containsAll(['before', 'after'])); // pre-fix strict decode returned []
    });

    test('getRecentLogs tail-reads a file larger than the read window', () async {
      final file = await DebugLogManager.getLogFile();
      // Exceed the 256 KB tail window so the read starts mid-file (start > 0)
      // and the partial first line is dropped. ~100 B/line * 6000 ≈ 600 KB.
      final buf = StringBuffer();
      for (int i = 0; i < 6000; i++) {
        buf.writeln(jsonEncode({'level': 'INFO', 'message': 'line $i', 'pad': 'x' * 60}));
      }
      await file!.writeAsString(buf.toString(), mode: FileMode.append);

      final logs = await DebugLogManager.getRecentLogs(limit: 5);
      // Newest-first; the newest line is the last written, and every returned
      // line is fully-formed (no truncated first line leaked through).
      expect(logs.length, 5);
      expect(logs.first['message'], 'line 5999');
      for (final l in logs) {
        expect(l['message'], startsWith('line '));
      }
    });
  });
}
