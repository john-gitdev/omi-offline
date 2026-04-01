import 'dart:async';
import 'dart:typed_data';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/mutex.dart';

class OmiDeviceConnection extends DeviceConnection {
  static const String batteryServiceUuid = '0000180f-0000-1000-8000-00805f9b34fb';
  static const String batteryLevelCharacteristicUuid = '00002a19-0000-1000-8000-00805f9b34fb';

  // 4-byte battery detail: [state:1][mv:2LE][pct:1]
  static const String batteryDetailServiceUuid = '19b10050-e8f2-537e-4f6c-d104768a1214';
  static const String batteryDetailCharacteristicUuid = '19b10051-e8f2-537e-4f6c-d104768a1214';

  static const String buttonServiceUuid = '19b10040-e8f2-537e-4f6c-d104768a1214';
  static const String buttonTriggerCharacteristicUuid = '19b10041-e8f2-537e-4f6c-d104768a1214';

  static const String featuresServiceUuid = '19b10020-e8f2-537e-4f6c-d104768a1214';
  static const String featuresCharacteristicUuid = '19b10021-e8f2-537e-4f6c-d104768a1214';
  static const String audioCodecCharacteristicUuid = '19b10002-e8f2-537e-4f6c-d104768a1214';

  static const String storageDataStreamServiceUuid = '30295780-4301-eabd-2904-2849adfeae43';
  static const String storageDataStreamCharacteristicUuid = '30295781-4301-eabd-2904-2849adfeae43';
  static const String storageReadControlCharacteristicUuid = '30295782-4301-eabd-2904-2849adfeae43';

  static const String timeSyncServiceUuid = '19b10030-e8f2-537e-4f6c-d104768a1214';
  static const String timeSyncWriteCharacteristicUuid = '19b10031-e8f2-537e-4f6c-d104768a1214';

  static const String disServiceUuid = '0000180a-0000-1000-8000-00805f9b34fb';
  static const String disModelNumberCharacteristicUuid = '00002a24-0000-1000-8000-00805f9b34fb';
  static const String disFirmwareRevisionCharacteristicUuid = '00002a26-0000-1000-8000-00805f9b34fb';
  static const String disHardwareRevisionCharacteristicUuid = '00002a27-0000-1000-8000-00805f9b34fb';
  static const String disManufacturerNameCharacteristicUuid = '00002a29-0000-1000-8000-00805f9b34fb';
  static const String disSerialNumberCharacteristicUuid = '00002a25-0000-1000-8000-00805f9b34fb';

  static const String settingsServiceUuid = '19b10010-e8f2-537e-4f6c-d104768a1214';
  static const String settingsDimRatioCharacteristicUuid = '19b10011-e8f2-537e-4f6c-d104768a1214';
  static const String settingsMicGainCharacteristicUuid = '19b10012-e8f2-537e-4f6c-d104768a1214';

  // Deduplicates concurrent listFiles calls
  Completer<List<StorageFile>>? _listFilesCompleter;

  // Protects against stale packets from previous calls
  int _listFilesGeneration = 0;
  StreamSubscription? _listFilesSub;
  Timer? _timeoutTimer;
  // Retries CMD_LIST_FILES until the firmware responds
  Timer? _cccdRetryTimer;

  // Cached audio codec to avoid redundant BLE reads
  BleAudioCodec? _cachedAudioCodec;

  final Mutex _storageMutex = Mutex();

  static const _cccdSettleDelay = Duration(milliseconds: 2000);

  OmiDeviceConnection(super.device, super.transport);

  @override
  Future<void> acquireStorageLock() => _storageMutex.acquire();

  @override
  void releaseStorageLock() => _storageMutex.release();

  @override
  Future<void> connect({
    void Function(String deviceId, DeviceConnectionState state)? onConnectionStateChanged,
    bool requiresBond = false,
  }) async {
    await super.connect(onConnectionStateChanged: onConnectionStateChanged, requiresBond: requiresBond);
    await performSyncDeviceTime();
  }

  Future<void> stop() async {
    _listFilesGeneration++;
    final sub = _listFilesSub;
    _listFilesSub = null;
    await sub?.cancel();
    await performStopStorageSync();
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _cccdRetryTimer?.cancel();
    _cccdRetryTimer = null;
    _cachedAudioCodec = null;
  }

  @override
  Future<StorageFileStats?> getStorageFileStats() async {
    try {
      final data = await transport.readCharacteristic(storageDataStreamServiceUuid, storageReadControlCharacteristicUuid);
      if (data.length >= 8) {
        final byteData = ByteData.sublistView(Uint8List.fromList(data));
        return StorageFileStats(
          totalUsedBytes: byteData.getUint32(0, Endian.little),
          fileCount: byteData.getUint32(4, Endian.little),
        );
      }
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error getting storage stats: $e');
    }
    return null;
  }

  @override
  Future<Stream<List<int>>> getBleStorageBytesStream() async {
    return await transport.getCharacteristicStream(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid);
  }

  @override
  Future<int> performRetrieveBatteryLevel() async {
    try {
      final detail = await transport.readCharacteristic(batteryDetailServiceUuid, batteryDetailCharacteristicUuid);
      if (detail.length >= 3) return detail[2];
    } catch (_) {}
    try {
      final data = await transport.readCharacteristic(batteryServiceUuid, batteryLevelCharacteristicUuid);
      if (data.isNotEmpty) return data[0];
    } catch (_) {}
    return -1;
  }

  @override
  Future<bool> performRetrieveChargingState() async {
    try {
      final data = await transport.readCharacteristic(batteryDetailServiceUuid, batteryDetailCharacteristicUuid);
      if (data.length >= 4) return data[3] == 1;
    } catch (_) {}
    return false;
  }

  @override
  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener({
    void Function(int)? onBatteryLevelChange,
    void Function(bool)? onChargingStateChange,
  }) async {
    try {
      final stream = await transport.getCharacteristicStream(batteryDetailServiceUuid, batteryDetailCharacteristicUuid);
      return stream.listen((value) {
        if (value.length >= 3 && onBatteryLevelChange != null) onBatteryLevelChange(value[2]);
        if (value.length >= 4 && onChargingStateChange != null) onChargingStateChange(value[3] == 1);
      });
    } catch (_) {}
    return null;
  }

  @override
  Future<void> disconnect() async {
    await stop();
    await super.disconnect();
  }

  @override
  Future<List<int>> performGetButtonState() async {
    try {
      return await transport.readCharacteristic(buttonServiceUuid, buttonTriggerCharacteristicUuid);
    } catch (_) {
      return [];
    }
  }

  @override
  Future<BleAudioCodec> performGetAudioCodec() async {
    if (_cachedAudioCodec != null) return _cachedAudioCodec!;
    try {
      final data = await transport.readCharacteristic(featuresServiceUuid, audioCodecCharacteristicUuid);
      if (data.isNotEmpty) {
        if (data[0] == 20) return _cachedAudioCodec = BleAudioCodec.opus;
        if (data[0] == 21) return _cachedAudioCodec = BleAudioCodec.opusFS320;
      }
    } catch (_) {}
    return _cachedAudioCodec = BleAudioCodec.pcm8;
  }

  @override
  Future<StreamSubscription<List<int>>?> performGetBleButtonListener({
    required void Function(List<int>) onButtonReceived,
  }) async {
    try {
      final stream = await transport.getCharacteristicStream(buttonServiceUuid, buttonTriggerCharacteristicUuid);
      return stream.listen((value) { if (value.isNotEmpty) onButtonReceived(value); });
    } catch (_) { return null; }
  }

  @override
  Future<List<int>> performGetStorageList() async {
    try {
      final data = await transport.readCharacteristic(storageDataStreamServiceUuid, storageReadControlCharacteristicUuid);
      List<int> result = [];
      for (int i = 0; i < (data.length ~/ 4); i++) {
        result.add(ByteData.sublistView(Uint8List.fromList(data)).getUint32(i * 4, Endian.little));
      }
      return result;
    } catch (_) { return []; }
  }

  @override
  Future<bool> performWriteToStorage(int numFile, int command, int offset) async {
    try {
      final data = ByteData(6)
        ..setUint8(0, command & 0xFF)
        ..setUint8(1, numFile & 0xFF)
        ..setUint32(2, offset, Endian.little);
      await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, data.buffer.asUint8List());
      return true;
    } catch (_) { return false; }
  }

  @override
  Future<int> performGetFeatures() async {
    try {
      final data = await transport.readCharacteristic(featuresServiceUuid, featuresCharacteristicUuid);
      if (data.length >= 4) return ByteData.sublistView(Uint8List.fromList(data)).getUint32(0, Endian.little);
    } catch (_) {}
    return 0;
  }

  @override
  Future<void> performSetLedDimRatio(int ratio) async {
    try { await transport.writeCharacteristic(settingsServiceUuid, settingsDimRatioCharacteristicUuid, [ratio]); } catch (_) {}
  }

  @override
  Future<int?> performGetLedDimRatio() async {
    try {
      final data = await transport.readCharacteristic(settingsServiceUuid, settingsDimRatioCharacteristicUuid);
      if (data.isNotEmpty) return data[0];
    } catch (_) {}
    return null;
  }

  @override
  Future<void> performSetMicGain(int gain) async {
    try { await transport.writeCharacteristic(settingsServiceUuid, settingsMicGainCharacteristicUuid, [gain]); } catch (_) {}
  }

  @override
  Future<int?> performGetMicGain() async {
    try {
      final data = await transport.readCharacteristic(settingsServiceUuid, settingsMicGainCharacteristicUuid);
      if (data.isNotEmpty) return data[0];
    } catch (_) {}
    return null;
  }

  @override
  Future<BtDevice> performGetDeviceInfo(DeviceConnection? connection) async {
    try {
      String? model, fw, hw, manuf, sn;
      try { model = String.fromCharCodes(await transport.readCharacteristic(disServiceUuid, disModelNumberCharacteristicUuid)); } catch (_) {}
      try { fw = String.fromCharCodes(await transport.readCharacteristic(disServiceUuid, disFirmwareRevisionCharacteristicUuid)); } catch (_) {}
      try { hw = String.fromCharCodes(await transport.readCharacteristic(disServiceUuid, disHardwareRevisionCharacteristicUuid)); } catch (_) {}
      try { manuf = String.fromCharCodes(await transport.readCharacteristic(disServiceUuid, disManufacturerNameCharacteristicUuid)); } catch (_) {}
      try { sn = String.fromCharCodes(await transport.readCharacteristic(disServiceUuid, disSerialNumberCharacteristicUuid)); } catch (_) {}
      return device.copyWith(modelNumber: model, firmwareRevision: fw, hardwareRevision: hw, manufacturerName: manuf, serialNumber: sn);
    } catch (_) { return device; }
  }

  @override
  Future<List<StorageFile>> performListFiles() async {
    await _storageMutex.acquire();
    try { return await _performListFilesLocked(); } finally { _storageMutex.release(); }
  }

  Future<List<StorageFile>> _performListFilesLocked() async {
    await _listFilesSub?.cancel();
    _listFilesSub = null;
    await stop();
    final int gen = ++_listFilesGeneration;
    final currentCompleter = Completer<List<StorageFile>>();
    _listFilesCompleter = currentCompleter;
    final buffer = <int>[];
    bool isStale() => gen != _listFilesGeneration;

    void fail(String reason) {
      if (!currentCompleter.isCompleted) currentCompleter.completeError(TimeoutException(reason));
      unawaited(stop());
    }

    void success(List<StorageFile> files) {
      _cccdRetryTimer?.cancel(); _timeoutTimer?.cancel();
      _listFilesGeneration++;
      final sub = _listFilesSub; _listFilesSub = null; unawaited(sub?.cancel());
      if (!currentCompleter.isCompleted) currentCompleter.complete(files);
    }

    try {
      final stream = await transport.getCharacteristicStream(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid);
      int? expectedTotalBytes;

      _listFilesSub = stream.listen((packet) {
        if (isStale() || packet.isEmpty) return;

        // PACKET_ACK (0x03) with result 0 means success but potentially empty data
        if (packet[0] == 0x03) {
          if (buffer.isEmpty) success([]); // ACK received before any data = empty list
          return;
        }

        if (packet[0] == 0x02) return; // Ignore EOT for list files (usually not sent)

        // For every packet, we expect the PACKET_DATA (0x01) header
        if (packet[0] != 0x01) {
          fail("Unexpected packet type: 0x${packet[0].toRadixString(16)}");
          return;
        }

        // Add the payload (skipping 0x01 header) to our accumulation buffer
        buffer.addAll(packet.sublist(1));

        // Once we have the first 4 bytes of data, we know the total count
        if (expectedTotalBytes == null && buffer.length >= 4) {
          final count = ByteData.sublistView(Uint8List.fromList(buffer)).getUint32(0, Endian.little);
          if (count == 0) {
            success([]);
            return;
          }
          if (count > 2000) {
            fail("Invalid file count: $count");
            return;
          }
          expectedTotalBytes = 4 + (count * 8);
          Logger.debug('OmiDeviceConnection: Expecting $count files ($expectedTotalBytes bytes total)');
        }

        // Keep accumulating until we reach the expected size
        if (expectedTotalBytes != null && buffer.length >= expectedTotalBytes!) {
          final count = ByteData.sublistView(Uint8List.fromList(buffer)).getUint32(0, Endian.little);
          final files = <StorageFile>[];
          final bd = ByteData.sublistView(Uint8List.fromList(buffer.sublist(0, expectedTotalBytes!)));
          for (int i = 0; i < count; i++) {
            files.add(StorageFile(
              index: i,
              timestamp: bd.getUint32(4 + i * 8, Endian.little),
              size: bd.getUint32(8 + i * 8, Endian.little),
            ));
          }
          Logger.debug('OmiDeviceConnection: Successfully parsed all $count files');
          success(files);
        }
      });

      await Future.delayed(_cccdSettleDelay);
      await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x10]);
      _timeoutTimer = Timer(const Duration(seconds: 120), () => fail("Timeout"));
      _cccdRetryTimer = Timer(const Duration(seconds: 10), () async {
        if (isStale() || currentCompleter.isCompleted) return;
        try { await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x10]); } catch (_) {}
      });
      return await currentCompleter.future;
    } catch (e) { return []; }
  }

  @override
  Future<bool> performDeleteFile(StorageFile file) async {
    await _storageMutex.acquire();
    try {
      final completer = Completer<bool>();
      final stream = await transport.getCharacteristicStream(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid);
      final sub = stream.listen((data) {
        if (completer.isCompleted) return;
        if (data.isNotEmpty && data[0] == 0x03) completer.complete(data.length < 2 || data[1] == 0);
      });
      await Future.delayed(_cccdSettleDelay);
      await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x12, file.index & 0xFF]);
      final res = await completer.future.timeout(const Duration(seconds: 35));
      await sub.cancel();
      return res;
    } catch (_) { return false; } finally { _storageMutex.release(); }
  }

  @override
  Future<bool> performStopStorageSync() async {
    try {
      await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x03]);
      return true;
    } catch (_) { return false; }
  }

  @override
  Future<bool> performRotateFile() async {
    await _storageMutex.acquire();
    try {
      final completer = Completer<bool>();
      final stream = await transport.getCharacteristicStream(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid);
      final sub = stream.listen((data) {
        if (!completer.isCompleted && data.length >= 2 && data[0] == 0x03) completer.complete(data[1] == 0);
      });
      await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x13]);
      final res = await completer.future.timeout(const Duration(seconds: 15));
      await sub.cancel();
      return res;
    } catch (_) { return false; } finally { _storageMutex.release(); }
  }

  @override
  Future<bool> performSyncDeviceTime() async {
    for (int i = 0; i < 3; i++) {
      try {
        int epoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final data = ByteData(4)..setUint32(0, epoch, Endian.little);
        await transport.writeCharacteristic(timeSyncServiceUuid, timeSyncWriteCharacteristicUuid, data.buffer.asUint8List());
        return true;
      } catch (_) { await Future.delayed(Duration(milliseconds: 100 * (i + 1))); }
    }
    return false;
  }

  @override
  Future<Stream<List<int>>> performReadFile(StorageFile file, {int offset = 0}) async {
    // This is handled by the WAL sync logic which sets up its own listener.
    return const Stream.empty();
  }
}
