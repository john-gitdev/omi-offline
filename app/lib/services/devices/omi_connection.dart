import 'dart:async';
import 'dart:typed_data';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/device_crash_log.dart';
import 'package:omi/services/devices/device_drop_stats.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'package:omi/utils/byte_utils.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/mutex.dart';

class OmiDeviceConnection extends DeviceConnection {
  static const String batteryServiceUuid = '0000180f-0000-1000-8000-00805f9b34fb';
  static const String batteryLevelCharacteristicUuid = '00002a19-0000-1000-8000-00805f9b34fb';

  // 1-byte battery detail: [charging:1]
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
  static const String settingsVadThresholdCharacteristicUuid = '19b10013-e8f2-537e-4f6c-d104768a1214';

  // 8-byte diagnostics: [uint32 reset_cause LE] [uint32 uptime_seconds LE]
  static const String diagnosticsServiceUuid = '19b10060-e8f2-537e-4f6c-d104768a1214';
  static const String diagnosticsCharacteristicUuid = '19b10061-e8f2-537e-4f6c-d104768a1214';
  // 20-byte drop counters: [blockDrops u32][lastDropUptimeMs u32]
  //                        [sdStreamDrops u32][sdBootDrops u32][nowUptimeMs u32]
  static const String diagnosticsDropsCharacteristicUuid = '19b10062-e8f2-537e-4f6c-d104768a1214';

  // Protects against stale packets from previous calls
  int _listFilesGeneration = 0;

  StreamSubscription? _listFilesSub;
  Timer? _timeoutTimer;
  // Retries CMD_LIST_FILES until the firmware responds
  Timer? _cccdRetryTimer;

  StreamSubscription<List<int>>? _chargingSubscription;

  // Cached audio codec to avoid redundant BLE reads
  BleAudioCodec? _cachedAudioCodec;

  final Mutex _storageMutex = Mutex();
  String? _lockOwner;

  @override
  bool get isStorageBusy => _storageMutex.isLocked;

  // 2s for the initial listFiles subscription (CCCD descriptor write is slow on first subscribe).
  static const _cccdSettleDelay = Duration(milliseconds: 2000);
  // 500ms for subsequent commands (delete, rotate) — enough for CCCD writes on slow BLE
  // stacks without the 2s penalty of the full listFiles settle delay.
  static const _cccdCommandDelay = Duration(milliseconds: 500);

  OmiDeviceConnection(super.device, super.transport);

  @override
  Future<void> acquireStorageLock([String owner = 'unknown']) async {
    try {
      // tryAcquire cleans up its waiter on timeout; `.acquire().timeout()` did
      // not, which left the mutex held by a phantom owner.
      final acquired = await _storageMutex.tryAcquire(timeout: const Duration(seconds: 10));
      if (!acquired) {
        throw TimeoutException('Storage lock not acquired within 10s');
      }
      _lockOwner = owner;

      try {
        // TODO: Implement actual BLE wake command
        // await writeToConfig(...);

        await _waitForStorageReady();
      } catch (e) {
        _lockOwner = null;
        _storageMutex.release();
        rethrow;
      }
    } catch (e) {
      Logger.error('Failed to acquire SD lock for [$owner]. Current owner: $_lockOwner. Error: $e');
      rethrow;
    }
  }

  Future<void> _waitForStorageReady() async {
    const maxAttempts = 3;

    // Best-effort wake nudge. The underlying reads swallow their errors (they
    // return null/[] rather than throwing), so readiness is inferred from the
    // return value, not exceptions. A null stats result is *not* treated as a
    // hard failure: older firmware lacks the stats characteristic and always
    // returns null, and hard-failing here would block storage sync on those
    // devices. The real readiness gate is the subsequent storage command, which
    // carries its own retries/timeouts. We only loop to give a momentarily-busy
    // SD a few hundred ms to start responding; worst case is bounded (~600ms).
    for (int i = 0; i < maxAttempts; i++) {
      final stats = await performGetStorageFileStats();
      // Cache audio codec while awake (idempotent — cached after first read).
      await performGetAudioCodec();
      if (stats != null) return; // SD confirmed responsive
      if (i < maxAttempts - 1) {
        await Future.delayed(Duration(milliseconds: 100 * (i + 1)));
      }
    }
  }

  Future<void> _sleepStorage() async {
    try {
      // TODO: Replace with actual BLE sleep command
      // await writeToConfig(...).timeout(const Duration(seconds: 2));
    } catch (_) {
      // Ignore failures
    }
  }

  @override
  void releaseStorageLock() {
    unawaited(_sleepStorage());

    _lockOwner = null;
    _storageMutex.release();
  }

  @override
  Future<void> connect({
    void Function(String deviceId, DeviceConnectionState state, {bool isManual})? onConnectionStateChanged,
    bool requiresBond = false,
  }) async {
    await super.connect(onConnectionStateChanged: onConnectionStateChanged, requiresBond: requiresBond);
    await performSyncDeviceTime();
  }

  @override
  Future<DeviceCrashLog?> performGetDiagnostics() async {
    try {
      final data = await transport.readCharacteristic(diagnosticsServiceUuid, diagnosticsCharacteristicUuid);
      if (data.length < 8) return null;

      final log = DeviceCrashLog(
        deviceId: device.id,
        connectedAt: DateTime.now(),
        resetCause: data.getUint32LittleEndian(0),
        uptimeSeconds: data.getUint32LittleEndian(4),
      );

      if (log.isCrash) {
        Logger.warning('Device diagnostics: CRASH — ${log.causeLabel} (uptime: ${log.uptimeStr})');
      } else {
        Logger.debug('Device diagnostics: ${log.causeLabel} (uptime: ${log.uptimeStr})');
      }
      return log;
    } catch (e) {
      Logger.debug('Device diagnostics not available (older firmware): $e');
      return null;
    }
  }

  @override
  Future<DeviceDropStats?> performGetDropStats() async {
    try {
      final data = await transport.readCharacteristic(diagnosticsServiceUuid, diagnosticsDropsCharacteristicUuid);
      if (data.length < 20) return null;
      return DeviceDropStats(
        blockDrops: data.getUint32LittleEndian(0),
        lastBlockDropUptimeMs: data.getUint32LittleEndian(4),
        streamFrameDrops: data.getUint32LittleEndian(8),
        bootFrameDrops: data.getUint32LittleEndian(12),
        currentUptimeMs: data.getUint32LittleEndian(16),
        // Appended fields (28-byte firmware); 0 / false on older 20-byte builds.
        failedConnCount: data.length >= 28 ? data.getUint32LittleEndian(20) : 0,
        lastFailedConnDuringSlowAdv: data.length >= 28 && data.getUint32LittleEndian(24) == 1,
        // codec_drops appended at offset 28 (32-byte firmware); 0 on older builds.
        codecFrameDrops: data.length >= 32 ? data.getUint32LittleEndian(28) : 0,
        readAt: DateTime.now(),
      );
    } catch (e) {
      Logger.debug('Drop stats char not available (older firmware): $e');
      return null;
    }
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
  Future<StorageFileStats?> performGetStorageFileStats() async {
    try {
      final data =
          await transport.readCharacteristic(storageDataStreamServiceUuid, storageReadControlCharacteristicUuid);
      if (data.length >= 8) {
        return StorageFileStats(
          totalUsedBytes: data.getUint32LittleEndian(0),
          fileCount: data.getUint32LittleEndian(4),
          freeBytes: data.length >= 12 ? data.getUint32LittleEndian(8) : 0,
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
      final data = await transport.readCharacteristic(batteryServiceUuid, batteryLevelCharacteristicUuid);
      if (data.isNotEmpty) return data[0];
    } catch (_) {}
    return -1;
  }

  @override
  Future<bool> performRetrieveChargingState() async {
    try {
      final data = await transport.readCharacteristic(batteryDetailServiceUuid, batteryDetailCharacteristicUuid);
      if (data.isNotEmpty) return data[0] == 1;
    } catch (_) {}
    return false;
  }

  @override
  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener({
    void Function(int)? onBatteryLevelChange,
    void Function(bool)? onChargingStateChange,
  }) async {
    // BAS level stream
    StreamSubscription<List<int>>? levelSub;
    try {
      final levelStream = await transport.getCharacteristicStream(batteryServiceUuid, batteryLevelCharacteristicUuid);
      levelSub = levelStream.listen((v) {
        if (v.isNotEmpty && onBatteryLevelChange != null) onBatteryLevelChange(v[0]);
      });
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error subscribing to battery level: $e');
    }

    // Charging stream from custom service
    try {
      final chargingStream =
          await transport.getCharacteristicStream(batteryDetailServiceUuid, batteryDetailCharacteristicUuid);
      await _chargingSubscription?.cancel();
      _chargingSubscription = chargingStream.listen((v) {
        if (v.isNotEmpty && onChargingStateChange != null) onChargingStateChange(v[0] == 1);
      });
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error subscribing to charging state: $e');
    }

    return levelSub;
  }

  @override
  Future<void> disconnect({bool isManual = true}) async {
    await _chargingSubscription?.cancel();
    _chargingSubscription = null;
    await stop();
    await super.disconnect(isManual: isManual);
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
      return stream.listen((value) {
        if (value.isNotEmpty) onButtonReceived(value);
      });
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<int>> performGetStorageList() async {
    try {
      final data =
          await transport.readCharacteristic(storageDataStreamServiceUuid, storageReadControlCharacteristicUuid);
      List<int> result = [];
      for (int i = 0; i < (data.length ~/ 4); i++) {
        result.add(data.getUint32LittleEndian(i * 4));
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  @override
  Future<bool> performWriteToStorage(int numFile, int command, int offset, {int? timestamp}) async {
    try {
      final List<int> cmd = [
        command & 0xFF,
        numFile & 0xFF,
        offset & 0xFF,
        (offset >> 8) & 0xFF,
        (offset >> 16) & 0xFF,
        (offset >> 24) & 0xFF,
      ];
      if (command == 0x11 && timestamp != null) {
        // Extended CMD_READ_FILE: [0x11][index][offset:4LE][timestamp:4LE]
        cmd.addAll([
          timestamp & 0xFF,
          (timestamp >> 8) & 0xFF,
          (timestamp >> 16) & 0xFF,
          (timestamp >> 24) & 0xFF,
        ]);
      }
      await transport.writeCharacteristic(
          storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, Uint8List.fromList(cmd));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<int> performGetFeatures() async {
    try {
      final data = await transport.readCharacteristic(featuresServiceUuid, featuresCharacteristicUuid);
      if (data.length >= 4) return data.getUint32LittleEndian(0);
    } catch (_) {}
    return 0;
  }

  @override
  Future<void> performSetLedDimRatio(int ratio) async {
    try {
      await transport.writeCharacteristic(settingsServiceUuid, settingsDimRatioCharacteristicUuid, [ratio]);
    } catch (_) {}
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
    try {
      await transport.writeCharacteristic(settingsServiceUuid, settingsMicGainCharacteristicUuid, [gain]);
    } catch (_) {}
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
  Future<void> performSetVadThreshold(int threshold) async {
    try {
      // 16-bit threshold LE
      final data = [threshold & 0xFF, (threshold >> 8) & 0xFF];
      await transport.writeCharacteristic(settingsServiceUuid, settingsVadThresholdCharacteristicUuid, data);
    } catch (_) {}
  }

  @override
  Future<int?> performGetVadThreshold() async {
    try {
      final data = await transport.readCharacteristic(settingsServiceUuid, settingsVadThresholdCharacteristicUuid);
      if (data.length >= 2) {
        return data[0] + (data[1] << 8);
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<BtDevice> performGetDeviceInfo(DeviceConnection? connection) async {
    try {
      String? model, fw, hw, manuf, sn;
      try {
        model =
            String.fromCharCodes(await transport.readCharacteristic(disServiceUuid, disModelNumberCharacteristicUuid));
      } catch (_) {}
      try {
        fw = String.fromCharCodes(
            await transport.readCharacteristic(disServiceUuid, disFirmwareRevisionCharacteristicUuid));
      } catch (_) {}
      try {
        hw = String.fromCharCodes(
            await transport.readCharacteristic(disServiceUuid, disHardwareRevisionCharacteristicUuid));
      } catch (_) {}
      try {
        manuf = String.fromCharCodes(
            await transport.readCharacteristic(disServiceUuid, disManufacturerNameCharacteristicUuid));
      } catch (_) {}
      try {
        sn =
            String.fromCharCodes(await transport.readCharacteristic(disServiceUuid, disSerialNumberCharacteristicUuid));
      } catch (_) {}
      return device.copyWith(
          modelNumber: model, firmwareRevision: fw, hardwareRevision: hw, manufacturerName: manuf, serialNumber: sn);
    } catch (_) {
      return device;
    }
  }

  @override
  Future<List<StorageFile>> performListFiles() async {
    return await _performListFilesLocked();
  }

  Future<List<StorageFile>> _performListFilesLocked() async {
    await _listFilesSub?.cancel();
    _listFilesSub = null;
    final int gen = ++_listFilesGeneration;
    final currentCompleter = Completer<List<StorageFile>>();
    final buffer = <int>[];
    bool isStale() => gen != _listFilesGeneration;

    void fail(String reason) {
      if (!currentCompleter.isCompleted) currentCompleter.completeError(TimeoutException(reason));
      unawaited(stop());
    }

    void success(List<StorageFile> files) {
      _cccdRetryTimer?.cancel();
      _timeoutTimer?.cancel();
      _listFilesGeneration++;
      final sub = _listFilesSub;
      _listFilesSub = null;
      unawaited(sub?.cancel());
      if (!currentCompleter.isCompleted) currentCompleter.complete(files);
    }

    try {
      final stream =
          await transport.getCharacteristicStream(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid);
      int? expectedTotalBytes;

      _listFilesSub = stream.listen((blePacket) {
        if (isStale() || blePacket.isEmpty) return;

        // PACKET_ACK (0x03) is just an acknowledgement that the command was received.
        // The actual data follows in PACKET_DATA (0x01) packets.
        if (blePacket[0] == 0x03) {
          if (blePacket.length >= 2 && blePacket[1] == 9) {
            Logger.warning('OmiDeviceConnection: CMD_LIST_FILES returned STORAGE_NOT_READY');
            fail('STORAGE_NOT_READY');
          } else {
            Logger.debug('OmiDeviceConnection: CMD_LIST_FILES ACK received');
          }
          return;
        }

        // PACKET_EOT (0x02) marks the end of the file list transfer.
        if (blePacket[0] == 0x02) {
          Logger.debug('OmiDeviceConnection: CMD_LIST_FILES EOT received');
          if (expectedTotalBytes == null || buffer.length < expectedTotalBytes!) {
            // If we got EOT but haven't received all expected bytes (or any bytes),
            // complete with what we have if it's a valid list.
            if (buffer.length >= 4) {
              // We have at least the count, so we can try parsing.
              _parseAndSuccess(buffer, success);
            } else {
              success([]); // Empty list or malformed
            }
          }
          return;
        }

        // For every packet, we expect the PACKET_DATA (0x01) header
        if (blePacket[0] != 0x01) {
          fail("Unexpected packet type: 0x${blePacket[0].toRadixString(16)}");
          return;
        }

        // Add the payload (skipping 0x01 header) to our accumulation buffer
        buffer.addAll(blePacket.sublist(1));

        // Once we have the first 4 bytes of data, we know the total count
        if (expectedTotalBytes == null && buffer.length >= 4) {
          final count = buffer.getUint32LittleEndian(0);
          if (count == 0) {
            // Firmware sends [0x01][0,0,0,0] followed by [0x02] for empty list.
            expectedTotalBytes = 4;
          } else if (count > 2000) {
            fail("Invalid file count: $count");
            return;
          } else {
            // Entry format: [index:4][timestamp:4][size:4][sessionId:4] = 16 bytes
            expectedTotalBytes = 4 + (count * 16);
            Logger.debug('OmiDeviceConnection: Expecting $count files ($expectedTotalBytes bytes total)');
          }
        }

        // Keep accumulating until we reach the expected size
        if (expectedTotalBytes != null && buffer.length >= expectedTotalBytes!) {
          _parseAndSuccess(buffer, success);
        }
      });

      await Future.delayed(_cccdSettleDelay);
      await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x10]);
      _timeoutTimer = Timer(const Duration(seconds: 120), () => fail("Timeout"));
      _cccdRetryTimer = Timer(const Duration(seconds: 10), () async {
        if (isStale() || currentCompleter.isCompleted) return;
        try {
          await transport
              .writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x10]);
        } catch (_) {}
      });
      return await currentCompleter.future;
    } catch (e) {
      return [];
    }
  }

  @override
  Future<bool> performDeleteFile(StorageFile file, {int? timestamp}) async {
    try {
      final completer = Completer<bool>();
      final stream =
          await transport.getCharacteristicStream(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid);
      final sub = stream.listen((data) {
        if (completer.isCompleted) return;
        if (data.isNotEmpty && data[0] == 0x03) completer.complete(data.length < 2 || data[1] == 0);
      });
      await Future.delayed(_cccdCommandDelay);

      final List<int> cmd = [0x12, file.index & 0xFF];
      if (timestamp != null) {
        cmd.addAll([
          timestamp & 0xFF,
          (timestamp >> 8) & 0xFF,
          (timestamp >> 16) & 0xFF,
          (timestamp >> 24) & 0xFF,
        ]);
      }

      await transport.writeCharacteristic(
          storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, Uint8List.fromList(cmd));
      try {
        return await completer.future.timeout(const Duration(seconds: 35));
      } finally {
        await sub.cancel();
      }
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> performSendKeepAlive() async {
    try {
      await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x32]);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> performStopStorageSync() async {
    try {
      final completer = Completer<bool>();
      final stream =
          await transport.getCharacteristicStream(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid);
      final sub = stream.listen((data) {
        if (!completer.isCompleted && data.isNotEmpty && data[0] == 0x03) {
          completer.complete(data.length < 2 || data[1] == 0);
        }
      });

      await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x03]);
      try {
        return await completer.future.timeout(const Duration(seconds: 5));
      } finally {
        await sub.cancel();
      }
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> performRotateFile() async {
    try {
      final completer = Completer<bool>();
      final stream =
          await transport.getCharacteristicStream(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid);
      final sub = stream.listen((data) {
        if (!completer.isCompleted && data.length >= 2 && data[0] == 0x03) completer.complete(data[1] == 0);
      });
      await Future.delayed(_cccdCommandDelay);
      await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x13]);
      try {
        return await completer.future.timeout(const Duration(seconds: 25));
      } finally {
        await sub.cancel();
      }
    } catch (e, stack) {
      Logger.error('performRotateFile error: $e\n$stack');
      return false;
    }
  }

  @override
  Future<bool> performClearStorage() async {
    try {
      final completer = Completer<bool>();
      final stream =
          await transport.getCharacteristicStream(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid);
      final sub = stream.listen((data) {
        if (!completer.isCompleted && data.isNotEmpty && data[0] == 0x03) {
          completer.complete(data.length < 2 || data[1] == 0);
        }
      });
      await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x14]);
      try {
        return await completer.future.timeout(const Duration(seconds: 65));
      } finally {
        await sub.cancel();
      }
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> performSyncDeviceTime() async {
    for (int i = 0; i < 3; i++) {
      try {
        int epoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final data = ByteData(4)..setUint32(0, epoch, Endian.little);
        await transport.writeCharacteristic(
            timeSyncServiceUuid, timeSyncWriteCharacteristicUuid, data.buffer.asUint8List());
        return true;
      } catch (_) {
        await Future.delayed(Duration(milliseconds: 100 * (i + 1)));
      }
    }
    return false;
  }

  void _parseAndSuccess(List<int> buffer, void Function(List<StorageFile>) success) {
    final count = buffer.getUint32LittleEndian(0);
    final files = <StorageFile>[];
    final totalExpected = 4 + (count * 16);

    // Guard against partial data if called from EOT branch
    final actualBuffer = buffer.length > totalExpected ? buffer.sublist(0, totalExpected) : buffer;

    for (int i = 0; i < count && (4 + (i + 1) * 16) <= actualBuffer.length; i++) {
      files.add(StorageFile(
        index: actualBuffer.getUint32LittleEndian(4 + i * 16),
        timestamp: actualBuffer.getUint32LittleEndian(8 + i * 16),
        size: actualBuffer.getUint32LittleEndian(12 + i * 16),
        sessionId: actualBuffer.getUint32LittleEndian(16 + i * 16),
      ));
    }

    for (int i = 0; i < files.length; i++) {
      Logger.debug(
          'OmiDeviceConnection: file[$i] index=${files[i].index} ts=${files[i].timestamp} size=${files[i].size} sid=${files[i].sessionId}');
    }
    Logger.debug('OmiDeviceConnection: Successfully parsed ${files.length} files (count field said $count)');
    success(files);
  }
}
