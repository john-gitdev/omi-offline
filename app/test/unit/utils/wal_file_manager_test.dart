import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

    // Reset WalFileManager state by clearing before each test
    // To ensure _walFile is re-initialized with the new tempDir path
    await WalFileManager.init();
    await WalFileManager.clearAll();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('WalFileManager', () {
    test('loadWals returns empty list when file does not exist', () async {
      final wals = await WalFileManager.loadWals();
      expect(wals, isEmpty);
    });

    test('loadWals returns empty list when file is empty', () async {
      final file = File('${tempDir.path}/wals.json');
      await file.writeAsString('');

      final wals = await WalFileManager.loadWals();
      expect(wals, isEmpty);
    });

    test('loadWals returns empty list when file format is invalid', () async {
      final file = File('${tempDir.path}/wals.json');
      await file.writeAsString('{"invalid": "format"}');

      final wals = await WalFileManager.loadWals();
      expect(wals, isEmpty);
    });

    test('saveWals successfully saves and loadWals reads valid data', () async {
      final wal1 = Wal(
        device: 'device_1',
        fileNum: 1,
        walOffset: 100,
        storageTotalBytes: 1000,
        timerStart: 1234567890,
        storage: WalStorage.sdcard,
        status: WalStatus.synced,
      );

      final wal2 = Wal(
        device: 'device_2',
        fileNum: 2,
        walOffset: 0,
        storageTotalBytes: 500,
        timerStart: 1234567891,
        storage: WalStorage.local,
      );

      final success = await WalFileManager.saveWals([wal1, wal2]);
      expect(success, isTrue);

      final file = File('${tempDir.path}/wals.json');
      expect(file.existsSync(), isTrue);

      final wals = await WalFileManager.loadWals();
      expect(wals.length, 2);

      // Verify some properties
      expect(wals[0].id, 'device_1-1234567890');
      expect(wals[0].walOffset, 100);
      expect(wals[0].storage, WalStorage.sdcard);
      expect(wals[0].status, WalStatus.synced);

      expect(wals[1].id, 'device_2-1234567891');
      expect(wals[1].storage, WalStorage.local);
    });

    test('saveWals creates a backup of the previous file', () async {
      final wal1 = Wal(
        device: 'device_1',
        fileNum: 1,
        walOffset: 100,
        storageTotalBytes: 1000,
        timerStart: 1234567890,
        storage: WalStorage.sdcard,
      );

      // First save
      await WalFileManager.saveWals([wal1]);

      final file = File('${tempDir.path}/wals.json');
      final backupFile = File('${tempDir.path}/wals_backup.json');

      expect(file.existsSync(), isTrue);
      expect(backupFile.existsSync(), isFalse); // No backup on first save

      final wal2 = Wal(
        device: 'device_2',
        fileNum: 2,
        walOffset: 0,
        storageTotalBytes: 500,
        timerStart: 1234567891,
        storage: WalStorage.local,
      );

      // Second save should create a backup of the first save
      await WalFileManager.saveWals([wal1, wal2]);

      expect(file.existsSync(), isTrue);
      expect(backupFile.existsSync(), isTrue);

      // Backup file should contain only the first wal
      final backupContent = await backupFile.readAsString();
      final backupData = jsonDecode(backupContent);
      expect(backupData['wals'], hasLength(1));
      expect(backupData['wals'][0]['device'], 'device_1');
    });

    test('clearAll deletes both main and backup files', () async {
      final wal1 = Wal(
        device: 'device_1',
        fileNum: 1,
        walOffset: 100,
        storageTotalBytes: 1000,
        timerStart: 1234567890,
        storage: WalStorage.sdcard,
      );

      // Save twice to create a backup file
      await WalFileManager.saveWals([wal1]);
      await WalFileManager.saveWals([wal1]);

      final file = File('${tempDir.path}/wals.json');
      final backupFile = File('${tempDir.path}/wals_backup.json');

      expect(file.existsSync(), isTrue);
      expect(backupFile.existsSync(), isTrue);

      await WalFileManager.clearAll();

      expect(file.existsSync(), isFalse);
      expect(backupFile.existsSync(), isFalse);
    });

    test('saveWals merges WALs from different devices when deviceId is provided', () async {
      final wal1 = Wal(
        device: 'device_1',
        fileNum: 1,
        walOffset: 100,
        storageTotalBytes: 1000,
        timerStart: 1234567890,
        storage: WalStorage.sdcard,
      );

      final wal2 = Wal(
        device: 'device_2',
        fileNum: 2,
        walOffset: 0,
        storageTotalBytes: 500,
        timerStart: 1234567891,
        storage: WalStorage.local,
      );

      // Save wal1 without deviceId
      await WalFileManager.saveWals([wal1]);

      // Save wal2 with deviceId='device_2'
      await WalFileManager.saveWals([wal2], deviceId: 'device_2');

      final wals = await WalFileManager.loadWals();
      expect(wals.length, 2);

      // Should have both device_1 and device_2 WALs
      expect(wals.any((w) => w.device == 'device_1'), isTrue);
      expect(wals.any((w) => w.device == 'device_2'), isTrue);
    });

    test('saveWals overwrites previous WALs for the same deviceId', () async {
      final wal1 = Wal(
        device: 'device_1',
        fileNum: 1,
        walOffset: 100,
        storageTotalBytes: 1000,
        timerStart: 1234567890,
        storage: WalStorage.sdcard,
      );

      final wal1Updated = Wal(
        device: 'device_1',
        fileNum: 1,
        walOffset: 500, // Updated offset
        storageTotalBytes: 1000,
        timerStart: 1234567890,
        storage: WalStorage.sdcard,
      );

      final wal2 = Wal(
        device: 'device_2',
        fileNum: 2,
        walOffset: 0,
        storageTotalBytes: 500,
        timerStart: 1234567891,
        storage: WalStorage.local,
      );

      // Save initial wals
      await WalFileManager.saveWals([wal1, wal2]);

      // Save updated wal1 with deviceId='device_1'
      await WalFileManager.saveWals([wal1Updated], deviceId: 'device_1');

      final wals = await WalFileManager.loadWals();
      expect(wals.length, 2);

      final device1Wals = wals.where((w) => w.device == 'device_1').toList();
      expect(device1Wals.length, 1);
      expect(device1Wals.first.walOffset, 500); // Verify it's the updated one

      expect(wals.any((w) => w.device == 'device_2'), isTrue); // device_2 should still be there
    });

    test('saveWals handles exceptions during merge gracefully', () async {
      // First, write invalid JSON to the file to cause an exception in loadWals
      final file = File('${tempDir.path}/wals.json');
      await file.writeAsString('{ invalid_json ]');

      final wal1 = Wal(
        device: 'device_1',
        fileNum: 1,
        walOffset: 100,
        storageTotalBytes: 1000,
        timerStart: 1234567890,
        storage: WalStorage.sdcard,
      );

      // Save wal1 with deviceId='device_1'.
      // The internal loadWals() will fail, but it should be caught and wal1 should still be saved.
      final success = await WalFileManager.saveWals([wal1], deviceId: 'device_1');
      expect(success, isTrue);

      final wals = await WalFileManager.loadWals();
      expect(wals.length, 1);
      expect(wals.first.device, 'device_1');
    });
  });
}
