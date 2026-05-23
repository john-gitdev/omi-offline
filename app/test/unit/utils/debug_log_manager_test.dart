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

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (MethodCall methodCall) async {
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
  });
}
