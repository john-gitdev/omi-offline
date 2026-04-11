import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/wals.dart';
import 'package:omi/utils/wal_file_manager.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockPathProvider extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  String? tempPath;
  @override
  Future<String?> getTemporaryPath() async => tempPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => tempPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late MockPathProvider mockPathProvider;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('wal_file_manager_test');
    mockPathProvider = MockPathProvider()..tempPath = tempDir.path;
    PathProviderPlatform.instance = mockPathProvider;
    await WalFileManager.init();
    await WalFileManager.clearAll(); // ensure clean state
  });

  tearDown(() async {
    await WalFileManager.clearAll();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('WalFileManager.loadWals', () {
    test('returns empty list when file does not exist', () async {
      final wals = await WalFileManager.loadWals();
      expect(wals, isEmpty);
    });

    test('returns empty list when file is empty', () async {
      final file = File('${tempDir.path}/wals.json');
      await file.writeAsString('');
      final wals = await WalFileManager.loadWals();
      expect(wals, isEmpty);
    });

    test('returns parsed list of WALs when file contains valid data', () async {
      final file = File('${tempDir.path}/wals.json');
      final validData = {
        'version': 1,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'wals': [
          {
            'codec': 'opus',
            'channel': 1,
            'device': 'test_device',
            'fileNum': 1,
            'storageOffset': 0,
            'storageTotalBytes': 100,
            'timerStart': 1000,
            'storage': 'sdcard',
            'status': 'syncing'
          }
        ]
      };
      await file.writeAsString(jsonEncode(validData));

      final wals = await WalFileManager.loadWals();
      expect(wals, hasLength(1));
      expect(wals.first.codec, BleAudioCodec.opus);
      expect(wals.first.device, 'test_device');
      expect(wals.first.fileNum, 1);
    });

    test('throws FormatException when file contains invalid JSON data', () async {
      final file = File('${tempDir.path}/wals.json');
      await file.writeAsString('invalid json');

      expect(() async => await WalFileManager.loadWals(), throwsA(isA<FormatException>()));
    });

    test('returns empty list when wals key is missing or not a list', () async {
      final file = File('${tempDir.path}/wals.json');
      final invalidData = {
        'version': 1,
        'wals': 'not a list'
      };
      await file.writeAsString(jsonEncode(invalidData));

      final wals = await WalFileManager.loadWals();
      expect(wals, isEmpty);
    });
  });
}
