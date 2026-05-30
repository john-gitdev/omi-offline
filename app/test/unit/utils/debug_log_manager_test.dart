import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/utils/debug_log_manager.dart';
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
    test('getLogFile returns a valid file with correct naming', () async {
      final file = await DebugLogManager.getLogFile();
      expect(file, isNotNull);
      expect(file!.existsSync(), isTrue);

      final fileName = file.uri.pathSegments.last;
      expect(fileName.startsWith('omi_debug_'), isTrue);
      expect(fileName.endsWith('.log'), isTrue);
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
