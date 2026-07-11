import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/wals/wal.dart';

void main() {
  group('Wal', () {
    test('mapNameToCodec handles all valid codec names', () {
      expect(Wal.mapNameToCodec('pcm8'), BleAudioCodec.pcm8);
      expect(Wal.mapNameToCodec('pcm16'), BleAudioCodec.pcm16);
      expect(Wal.mapNameToCodec('mulaw8'), BleAudioCodec.mulaw8);
      expect(Wal.mapNameToCodec('mulaw16'), BleAudioCodec.mulaw16);
      expect(Wal.mapNameToCodec('opus'), BleAudioCodec.opus);
      expect(Wal.mapNameToCodec('opusfs320'), BleAudioCodec.opusFS320);
      expect(Wal.mapNameToCodec('Opus'), BleAudioCodec.opus); // Case-insensitive
    });

    test('mapNameToCodec defaults to unknown for invalid names', () {
      expect(Wal.mapNameToCodec('invalid_codec'), BleAudioCodec.unknown);
      expect(Wal.mapNameToCodec(''), BleAudioCodec.unknown);
    });

    test('id handles non-zero timerStart correctly', () {
      final wal = Wal(
        codec: BleAudioCodec.opus,
        channel: 1,
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
        codec: BleAudioCodec.opus,
        channel: 1,
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
        codec: BleAudioCodec.opus,
        channel: 1,
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
        codec: BleAudioCodec.opus,
        channel: 1,
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
        codec: BleAudioCodec.opus,
        channel: 1,
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
        codec: BleAudioCodec.opus,
        channel: 1,
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
        codec: BleAudioCodec.opus,
        channel: 2,
        device: 'device_123',
        fileNum: 10,
        walOffset: 512,
        storageTotalBytes: 1024,
        timerStart: 12345,
        sessionId: 99,
        storage: WalStorage.sdcard,
        status: WalStatus.synced,
        filePath: '/path/to/file',
        seconds: 60,
        sampleRate: 16000,
        deviceModel: 'model_x',
        estimatedSegments: 5,
      );

      final json = wal.toJson();

      expect(json, {
        'codec': 'opus',
        'channel': 2,
        'device': 'device_123',
        'fileNum': 10,
        'storageOffset': 512,
        'storageTotalBytes': 1024,
        'timerStart': 12345,
        'sessionId': 99,
        'storage': 'sdcard',
        'status': 'synced',
        'syncFailCount': 0,
        'filePath': '/path/to/file',
        'seconds': 60,
        'sampleRate': 16000,
        'deviceModel': 'model_x',
        'estimatedSegments': 5,
      });
    });

    test('fromJson parses full data correctly', () {
      final json = {
        'codec': 'opus',
        'channel': 2,
        'device': 'device_123',
        'fileNum': 10,
        'storageOffset': 512,
        'storageTotalBytes': 1024,
        'timerStart': 12345,
        'sessionId': 99,
        'storage': 'sdcard',
        'status': 'synced',
        'filePath': '/path/to/file',
        'seconds': 60,
        'sampleRate': 16000,
        'deviceModel': 'model_x',
        'estimatedSegments': 5,
      };

      final wal = Wal.fromJson(json);

      expect(wal.codec, BleAudioCodec.opus);
      expect(wal.channel, 2);
      expect(wal.device, 'device_123');
      expect(wal.fileNum, 10);
      expect(wal.walOffset, 512);
      expect(wal.storageTotalBytes, 1024);
      expect(wal.timerStart, 12345);
      expect(wal.sessionId, 99);
      expect(wal.storage, WalStorage.sdcard);
      expect(wal.status, WalStatus.synced);
      expect(wal.filePath, '/path/to/file');
      expect(wal.seconds, 60);
      expect(wal.sampleRate, 16000);
      expect(wal.deviceModel, 'model_x');
      expect(wal.estimatedSegments, 5);
    });

    test('fromJson handles missing fields with defaults', () {
      final json = <String, dynamic>{};

      final wal = Wal.fromJson(json);

      // fromJson coalesces missing 'codec' to the literal 'pcm8' before calling mapNameToCodec.
      expect(wal.codec, BleAudioCodec.pcm8);
      expect(wal.channel, 1);
      expect(wal.device, '');
      expect(wal.fileNum, 0);
      expect(wal.walOffset, 0);
      expect(wal.storageTotalBytes, 0);
      expect(wal.timerStart, 0);
      expect(wal.sessionId, isNull);
      expect(wal.storage, WalStorage.local);
      expect(wal.status, WalStatus.miss);
      expect(wal.filePath, isNull);
      expect(wal.seconds, isNull);
      expect(wal.sampleRate, isNull);
      expect(wal.deviceModel, isNull);
      expect(wal.estimatedSegments, 0);
    });

    test('fromJsonList maps a list of JSON to Wals', () {
      final jsonList = [
        {'codec': 'pcm8', 'channel': 1},
        {'codec': 'opus', 'channel': 2},
      ];

      final wals = Wal.fromJsonList(jsonList);

      expect(wals.length, 2);
      expect(wals[0].codec, BleAudioCodec.pcm8);
      expect(wals[0].channel, 1);
      expect(wals[1].codec, BleAudioCodec.opus);
      expect(wals[1].channel, 2);
    });

    test('copyWith updates specified fields and retains others', () {
      final original = Wal(
        codec: BleAudioCodec.opus,
        channel: 1,
        device: 'device1',
        fileNum: 1,
        walOffset: 10,
        storageTotalBytes: 100,
        timerStart: 123,
        sessionId: 1,
        storage: WalStorage.local,
        status: WalStatus.syncing,
        isSyncing: true,
        syncMethod: SyncMethod.ble,
        filePath: 'path',
        data: [1, 2, 3],
        seconds: 10,
        sampleRate: 8000,
        deviceModel: 'model1',
        estimatedSegments: 2,
      );

      final updated = original.copyWith(
        codec: BleAudioCodec.pcm16,
        channel: 2,
        walOffset: 20,
        status: WalStatus.synced,
        filePath: 'new_path',
        estimatedSegments: 3,
      );

      // Changed fields
      expect(updated.codec, BleAudioCodec.pcm16);
      expect(updated.channel, 2);
      expect(updated.walOffset, 20);
      expect(updated.status, WalStatus.synced);
      expect(updated.filePath, 'new_path');
      expect(updated.estimatedSegments, 3);

      // Unchanged fields
      expect(updated.device, 'device1');
      expect(updated.fileNum, 1);
      expect(updated.storageTotalBytes, 100);
      expect(updated.timerStart, 123);
      expect(updated.sessionId, 1);
      expect(updated.storage, WalStorage.local);
      expect(updated.isSyncing, true);
      expect(updated.syncMethod, SyncMethod.ble);
      expect(updated.data, [1, 2, 3]);
      expect(updated.seconds, 10);
      expect(updated.sampleRate, 8000);
      expect(updated.deviceModel, 'model1');
    });
  });
}
