import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/wals/wal.dart';

void main() {
  group('Wal', () {
    test('id handles non-zero timerStart correctly', () {
      final wal = Wal(
        device: 'device_id',
        fileNum: 5,
        walOffset: 0,
        storageTotalBytes: 100,
        timerStart: 1234567890,
        storage: WalStorage.local,
      );
      expect(wal.id, 'device_id-1234567890');
    });

    test('id falls back to fileNum when timerStart is 0', () {
      final wal = Wal(
        device: 'device_id',
        fileNum: 5,
        walOffset: 0,
        storageTotalBytes: 100,
        timerStart: 0,
        storage: WalStorage.local,
      );
      expect(wal.id, 'device_id-5');
    });

    test('getSegmentFileNameByTimestamp returns correct format without sessionId', () {
      final wal = Wal(
        device: 'device_id',
        fileNum: 1,
        walOffset: 0,
        storageTotalBytes: 100,
        timerStart: 1234567890,
        storage: WalStorage.local,
      );
      expect(wal.getSegmentFileNameByTimestamp(1234567890), '1234567890_0.bin');
    });

    test('getSegmentFileNameByTimestamp returns correct format with sessionId', () {
      final wal = Wal(
        device: 'device_id',
        fileNum: 1,
        walOffset: 0,
        storageTotalBytes: 100,
        timerStart: 1234567890,
        storage: WalStorage.local,
      );
      expect(wal.getSegmentFileNameByTimestamp(1234567890, sessionId: 42), '1234567890_42.bin');
    });

    test('getFileName uses timerStart and sessionId', () {
      final wal = Wal(
        device: 'device_id',
        fileNum: 1,
        walOffset: 0,
        storageTotalBytes: 100,
        timerStart: 1234567890,
        sessionId: 42,
        storage: WalStorage.local,
      );
      expect(wal.getFileName(), '1234567890_42.bin');

      final walNoSession = Wal(
        device: 'device_id',
        fileNum: 1,
        walOffset: 0,
        storageTotalBytes: 100,
        timerStart: 1234567890,
        storage: WalStorage.local,
      );
      expect(walNoSession.getFileName(), '1234567890_0.bin');
    });

    test('toJson serializes correctly', () {
      final wal = Wal(
        device: 'device_123',
        fileNum: 10,
        walOffset: 512,
        storageTotalBytes: 1024,
        timerStart: 12345,
        sessionId: 99,
        storage: WalStorage.sdcard,
        status: WalStatus.synced,
      );

      final json = wal.toJson();

      expect(json, {
        'device': 'device_123',
        'fileNum': 10,
        'storageOffset': 512,
        'storageTotalBytes': 1024,
        'timerStart': 12345,
        'sessionId': 99,
        'storage': 'sdcard',
        'status': 'synced',
        'syncFailCount': 0,
      });
    });

    test('fromJson parses full data correctly', () {
      final json = {
        'device': 'device_123',
        'fileNum': 10,
        'storageOffset': 512,
        'storageTotalBytes': 1024,
        'timerStart': 12345,
        'sessionId': 99,
        'storage': 'sdcard',
        'status': 'synced',
        'syncFailCount': 3,
      };

      final wal = Wal.fromJson(json);

      expect(wal.device, 'device_123');
      expect(wal.fileNum, 10);
      expect(wal.walOffset, 512);
      expect(wal.storageTotalBytes, 1024);
      expect(wal.timerStart, 12345);
      expect(wal.sessionId, 99);
      expect(wal.storage, WalStorage.sdcard);
      expect(wal.status, WalStatus.synced);
      expect(wal.syncFailCount, 3);
    });

    test('fromJson handles missing fields with defaults', () {
      final json = <String, dynamic>{};

      final wal = Wal.fromJson(json);

      expect(wal.device, '');
      expect(wal.fileNum, 0);
      expect(wal.walOffset, 0);
      expect(wal.storageTotalBytes, 0);
      expect(wal.timerStart, 0);
      expect(wal.sessionId, isNull);
      expect(wal.storage, WalStorage.local);
      expect(wal.status, WalStatus.miss);
      expect(wal.syncFailCount, 0);
    });

    test('fromJsonList maps a list of JSON to Wals', () {
      final jsonList = [
        {'device': 'a', 'fileNum': 1},
        {'device': 'b', 'fileNum': 2},
      ];

      final wals = Wal.fromJsonList(jsonList);

      expect(wals.length, 2);
      expect(wals[0].device, 'a');
      expect(wals[0].fileNum, 1);
      expect(wals[1].device, 'b');
      expect(wals[1].fileNum, 2);
    });
  });
}
