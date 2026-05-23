import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/wals/wal.dart';

void main() {
  group('Wal', () {
    test('mapNameToCodec maps strings correctly', () {
      expect(Wal.mapNameToCodec('pcm8'), BleAudioCodec.pcm8);
      expect(Wal.mapNameToCodec('pcm16'), BleAudioCodec.pcm16);
      expect(Wal.mapNameToCodec('mulaw8'), BleAudioCodec.mulaw8);
      expect(Wal.mapNameToCodec('mulaw16'), BleAudioCodec.mulaw16);
      expect(Wal.mapNameToCodec('opus'), BleAudioCodec.opus);
      expect(Wal.mapNameToCodec('opusfs320'), BleAudioCodec.opusFS320);
      expect(Wal.mapNameToCodec('unknown_codec'), BleAudioCodec.unknown);
      expect(Wal.mapNameToCodec('OPUS'), BleAudioCodec.opus); // Case insensitivity
    });

    test('toJson and fromJson serialize and deserialize correctly', () {
      final wal = Wal(
        codec: BleAudioCodec.opusFS320,
        channel: 1,
        device: 'OMI_123',
        fileNum: 5,
        walOffset: 1024,
        storageTotalBytes: 4096,
        timerStart: 1620000000,
        sessionId: 99,
        storage: WalStorage.sdcard,
        status: WalStatus.synced,
        filePath: '/data/user/0/com.omi/app_flutter/1620000000_99.bin',
        seconds: 120,
        sampleRate: 16000,
        deviceModel: 'Omi_V1',
        estimatedSegments: 2,
      );

      final json = wal.toJson();
      expect(json['codec'], 'opusFS320');
      expect(json['channel'], 1);
      expect(json['device'], 'OMI_123');
      expect(json['fileNum'], 5);
      expect(json['storageOffset'], 1024);
      expect(json['storageTotalBytes'], 4096);
      expect(json['timerStart'], 1620000000);
      expect(json['sessionId'], 99);
      expect(json['storage'], 'sdcard');
      expect(json['status'], 'synced');
      expect(json['filePath'], '/data/user/0/com.omi/app_flutter/1620000000_99.bin');
      expect(json['seconds'], 120);
      expect(json['sampleRate'], 16000);
      expect(json['deviceModel'], 'Omi_V1');
      expect(json['estimatedSegments'], 2);

      final deserialized = Wal.fromJson(json);
      expect(deserialized.codec, BleAudioCodec.opusFS320);
      expect(deserialized.channel, 1);
      expect(deserialized.device, 'OMI_123');
      expect(deserialized.fileNum, 5);
      expect(deserialized.walOffset, 1024);
      expect(deserialized.storageTotalBytes, 4096);
      expect(deserialized.timerStart, 1620000000);
      expect(deserialized.sessionId, 99);
      expect(deserialized.storage, WalStorage.sdcard);
      expect(deserialized.status, WalStatus.synced);
      expect(deserialized.filePath, '/data/user/0/com.omi/app_flutter/1620000000_99.bin');
      expect(deserialized.seconds, 120);
      expect(deserialized.sampleRate, 16000);
      expect(deserialized.deviceModel, 'Omi_V1');
      expect(deserialized.estimatedSegments, 2);
    });

    test('fromJson handles missing fields with defaults', () {
      final json = <String, dynamic>{};
      final wal = Wal.fromJson(json);

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

    test('fromJsonList maps a list of JSON objects', () {
      final jsonList = [
        {'codec': 'opus', 'device': 'DevA'},
        {'codec': 'pcm16', 'device': 'DevB'},
      ];
      final wals = Wal.fromJsonList(jsonList);

      expect(wals.length, 2);
      expect(wals[0].codec, BleAudioCodec.opus);
      expect(wals[0].device, 'DevA');
      expect(wals[1].codec, BleAudioCodec.pcm16);
      expect(wals[1].device, 'DevB');
    });

    test('id getter uses timerStart when > 0, otherwise falls back to fileNum', () {
      final walWithTimer = Wal(
        codec: BleAudioCodec.opus,
        channel: 1,
        device: 'DEV1',
        fileNum: 10,
        walOffset: 0,
        storageTotalBytes: 0,
        timerStart: 1620000000,
        storage: WalStorage.local,
      );
      expect(walWithTimer.id, 'DEV1-1620000000');

      final walWithZeroTimer = Wal(
        codec: BleAudioCodec.opus,
        channel: 1,
        device: 'DEV1',
        fileNum: 10,
        walOffset: 0,
        storageTotalBytes: 0,
        timerStart: 0,
        storage: WalStorage.local,
      );
      expect(walWithZeroTimer.id, 'DEV1-10');
    });

    test('getFileName and getSegmentFileNameByTimestamp format correctly', () {
      final walWithoutSession = Wal(
        codec: BleAudioCodec.opus,
        channel: 1,
        device: 'DEV1',
        fileNum: 1,
        walOffset: 0,
        storageTotalBytes: 0,
        timerStart: 12345,
        storage: WalStorage.local,
      );
      expect(walWithoutSession.getFileName(), '12345_0.bin');
      expect(walWithoutSession.getSegmentFileNameByTimestamp(12345), '12345_0.bin');

      final walWithSession = Wal(
        codec: BleAudioCodec.opus,
        channel: 1,
        device: 'DEV1',
        fileNum: 1,
        walOffset: 0,
        storageTotalBytes: 0,
        timerStart: 12345,
        sessionId: 678,
        storage: WalStorage.local,
      );
      expect(walWithSession.getFileName(), '12345_678.bin');
      expect(walWithSession.getSegmentFileNameByTimestamp(12345, sessionId: 678), '12345_678.bin');
    });

    test('getFilePath returns filePath', () {
      final wal = Wal(
        codec: BleAudioCodec.opus,
        channel: 1,
        device: 'DEV',
        fileNum: 1,
        walOffset: 0,
        storageTotalBytes: 0,
        timerStart: 1,
        storage: WalStorage.local,
        filePath: '/tmp/test.bin',
      );
      expect(wal.getFilePath(), '/tmp/test.bin');
    });

    test('getFrameSize delegates to codec', () {
      final wal = Wal(
        codec: BleAudioCodec.opusFS320,
        channel: 1,
        device: 'DEV',
        fileNum: 1,
        walOffset: 0,
        storageTotalBytes: 0,
        timerStart: 1,
        storage: WalStorage.local,
      );
      expect(wal.getFrameSize(), BleAudioCodec.opusFS320.getFrameSize());
    });

    test('copyWith updates specified fields and retains others', () {
      final original = Wal(
        codec: BleAudioCodec.pcm8,
        channel: 1,
        device: 'OLD_DEV',
        fileNum: 1,
        walOffset: 0,
        storageTotalBytes: 100,
        timerStart: 1000,
        storage: WalStorage.local,
        status: WalStatus.miss,
      );

      final updated = original.copyWith(
        codec: BleAudioCodec.opus,
        device: 'NEW_DEV',
        status: WalStatus.synced,
        isSyncing: true,
      );

      expect(updated.codec, BleAudioCodec.opus);
      expect(updated.device, 'NEW_DEV');
      expect(updated.status, WalStatus.synced);
      expect(updated.isSyncing, true);

      // Unchanged fields
      expect(updated.channel, 1);
      expect(updated.fileNum, 1);
      expect(updated.timerStart, 1000);
      expect(updated.storage, WalStorage.local);
    });
  });
}
