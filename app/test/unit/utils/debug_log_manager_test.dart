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
  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;
  late MockPathProvider mockPathProvider;

  setUpAll(() {
    docsDir = Directory.systemTemp.createTempSync('debug_log_manager_test');
  });

  tearDownAll(() {
    if (docsDir.existsSync()) {
      docsDir.deleteSync(recursive: true);
    }
  });

  setUp(() async {
    mockPathProvider = MockPathProvider()..docsPath = docsDir.path;
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
    // Delete files in directory to start fresh
    for (var entity in docsDir.listSync()) {
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

    test('shareFileName stamps os/app/fw and the share date', () async {
      final name = DebugLogManager.shareFileName(os: 'android', appVersion: '0.33.8', fwVersion: 'oo-3.0.2');

      final d = DateTime.now().toUtc();
      final stamp = '${d.year.toString().padLeft(4, '0')}'
          '${d.month.toString().padLeft(2, '0')}'
          '${d.day.toString().padLeft(2, '0')}';
      expect(name, 'android_0.33.8_oo-3.0.2_omi_offline_debug_$stamp.log');
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
