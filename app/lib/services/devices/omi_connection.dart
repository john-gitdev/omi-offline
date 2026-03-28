import 'dart:async';
import 'dart:typed_data';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/mutex.dart';

class OmiDeviceConnection extends DeviceConnection {
  // Deduplicates concurrent listFiles calls
  Completer<List<StorageFile>>? _listFilesCompleter;

  // Protects against stale packets from previous calls
  int _listFilesGeneration = 0;
  StreamSubscription? _listFilesSub;
  Timer? _timeoutTimer;

  /// Serializes storage operations (listFiles, deleteFile, rotateFile) that
  /// share the same BLE characteristic stream. Without this, concurrent
  /// callers could misroute packets between operations.
  final Mutex _storageMutex = Mutex();

  OmiDeviceConnection(super.device, super.transport);

  @override
  Future<void> connect({void Function(String deviceId, DeviceConnectionState state)? onConnectionStateChanged}) async {
    await super.connect(onConnectionStateChanged: onConnectionStateChanged);
    await performSyncTime();
  }

  Future<void> stop() async {
    _listFilesGeneration++; // 🛑 Invalidate ALL in-flight handlers
    final sub = _listFilesSub;
    _listFilesSub = null;
    await sub?.cancel();
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  Future<bool> performSyncTime() async {
    try {
      final epochSeconds = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      final byteData = ByteData(4)..setUint32(0, epochSeconds, Endian.little);

      await transport.writeCharacteristic(timeSyncServiceUuid, timeSyncWriteCharacteristicUuid, byteData.buffer.asUint8List());
      Logger.debug('OmiDeviceConnection: Time synced to device: $epochSeconds');
      return true;
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error syncing time: $e');
      return false;
    }
  }

  @override
  Future<int> performRetrieveBatteryLevel() async {
    try {
      Logger.debug('OmiDeviceConnection: Attempting to read battery level from $batteryServiceUuid:$batteryLevelCharacteristicUuid');
      final data = await transport.readCharacteristic(batteryServiceUuid, batteryLevelCharacteristicUuid);
      Logger.debug('OmiDeviceConnection: Battery level read returned: $data');
      if (data.isNotEmpty) return data[0];
      return -1;
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error reading battery level: $e');
      return -1;
    }
  }

  @override
  Future<bool> performRetrieveChargingState() async {
    return false; // Standard BAS doesn't provide charging state
  }

  @override
  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener({
    void Function(int)? onBatteryLevelChange,
    void Function(bool)? onChargingStateChange,
  }) async {
    try {
      Logger.debug('OmiDeviceConnection: Setting up battery level listener...');
      final stream = await transport.getCharacteristicStream(batteryServiceUuid, batteryLevelCharacteristicUuid);
      Logger.debug('OmiDeviceConnection: Battery level listener stream created');

      final subscription = stream.listen((value) {
        if (value.isNotEmpty && onBatteryLevelChange != null) {
          onBatteryLevelChange(value[0]);
        }
      });

      return subscription;
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error setting up battery listener: $e');
      return null;
    }
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
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error reading button state: $e');
      return <int>[];
    }
  }

  @override
  Future<BleAudioCodec> performGetAudioCodec() async {
    try {
      final codecValue = await transport.readCharacteristic(featuresServiceUuid, audioCodecCharacteristicUuid);

      var codecId = 1;
      if (codecValue.isNotEmpty) {
        codecId = codecValue[0];
      }

      switch (codecId) {
        case 1:
          return BleAudioCodec.pcm8;
        case 20:
          return BleAudioCodec.opus;
        case 21:
          return BleAudioCodec.opusFS320;
        default:
          return BleAudioCodec.pcm8;
      }
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error reading audio codec: $e');
      return BleAudioCodec.pcm8;
    }
  }

  @override
  Future<StreamSubscription<List<int>>?> performGetBleButtonListener({
    required void Function(List<int>) onButtonReceived,
  }) async {
    try {
      final stream = await transport.getCharacteristicStream(buttonServiceUuid, buttonTriggerCharacteristicUuid);

      final subscription = stream.listen((value) {
        if (value.isNotEmpty) onButtonReceived(value);
      });

      return subscription ;
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error setting up button listener: $e');
      return null;
    }
  }

  @override
  Future<List<int>> performGetStorageList() async {
    try {
      final storageValue =
          await transport.readCharacteristic(storageDataStreamServiceUuid, storageReadControlCharacteristicUuid);
      Logger.debug('OmiDeviceConnection: Raw storage characteristic value: $storageValue');

      List<int> storageLengths = [];
      for (int i = 0; i < (storageValue.length ~/ 4); i++) {
        int baseIndex = i * 4;
        int result = ((storageValue[baseIndex] |
                    (storageValue[baseIndex + 1] << 8) |
                    (storageValue[baseIndex + 2] << 16) |
                    (storageValue[baseIndex + 3] << 24)) &
                0xFFFFFFFF)
            .toSigned(32);
        storageLengths.add(result);
      }
      return storageLengths;
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error reading storage list: $e');
      return <int>[];
    }
  }

  @override
  Future<bool> performWriteToStorage(int numFile, int command, int offset) async {
    try {
      // Offset in little-endian to match the rest of the BLE protocol.
      var offsetBytes = [
        offset & 0xFF,
        (offset >> 8) & 0xFF,
        (offset >> 16) & 0xFF,
        (offset >> 24) & 0xFF,
      ];

      await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid,
          [command & 0xFF, numFile & 0xFF, offsetBytes[0], offsetBytes[1], offsetBytes[2], offsetBytes[3]]);
      return true;
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error writing to storage: $e');
      return false;
    }
  }

  @override
  Future<int> performGetFeatures() async {
    try {
      final data = await transport.readCharacteristic(featuresServiceUuid, featuresCharacteristicUuid);
      if (data.length >= 4) {
        return ByteData.sublistView(Uint8List.fromList(data)).getUint32(0, Endian.little);
      }
      return 0;
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error getting features: $e');
      return 0;
    }
  }

  @override
  Future<void> performSetLedDimRatio(int ratio) async {
    try {
      await transport.writeCharacteristic(settingsServiceUuid, settingsDimRatioCharacteristicUuid, [ratio]);
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error setting LED dim ratio: $e');
    }
  }

  @override
  Future<int?> performGetLedDimRatio() async {
    try {
      final data = await transport.readCharacteristic(settingsServiceUuid, settingsDimRatioCharacteristicUuid);
      if (data.isNotEmpty) return data[0];
      return null;
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error getting LED dim ratio: $e');
      return null;
    }
  }

  @override
  Future<void> performSetMicGain(int gain) async {
    try {
      await transport.writeCharacteristic(settingsServiceUuid, settingsMicGainCharacteristicUuid, [gain]);
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error setting mic gain: $e');
    }
  }

  @override
  Future<int?> performGetMicGain() async {
    try {
      final data = await transport.readCharacteristic(settingsServiceUuid, settingsMicGainCharacteristicUuid);
      if (data.isNotEmpty) return data[0];
      return null;
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error getting mic gain: $e');
      return null;
    }
  }

  @override
  Future<BtDevice> performGetDeviceInfo(DeviceConnection? connection) async {
    try {
      String? modelNumber;
      try {
        final data = await transport.readCharacteristic(disServiceUuid, disModelNumberCharacteristicUuid);
        if (data.isNotEmpty) modelNumber = String.fromCharCodes(data);
      } catch (_) {}

      String? firmwareRevision;
      try {
        final data = await transport.readCharacteristic(disServiceUuid, disFirmwareRevisionCharacteristicUuid);
        if (data.isNotEmpty) firmwareRevision = String.fromCharCodes(data);
      } catch (_) {}

      String? hardwareRevision;
      try {
        final data = await transport.readCharacteristic(disServiceUuid, disHardwareRevisionCharacteristicUuid);
        if (data.isNotEmpty) hardwareRevision = String.fromCharCodes(data);
      } catch (_) {}

      String? manufacturerName;
      try {
        final data = await transport.readCharacteristic(disServiceUuid, disManufacturerNameCharacteristicUuid);
        if (data.isNotEmpty) manufacturerName = String.fromCharCodes(data);
      } catch (_) {}

      String? serialNumber;
      try {
        final data = await transport.readCharacteristic(disServiceUuid, disSerialNumberCharacteristicUuid);
        if (data.isNotEmpty) serialNumber = String.fromCharCodes(data);
      } catch (_) {}

      return device.copyWith(
        modelNumber: modelNumber,
        firmwareRevision: firmwareRevision,
        hardwareRevision: hardwareRevision,
        manufacturerName: manufacturerName,
        serialNumber: serialNumber,
      );
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error getting device info: $e');
      return device;
    }
  }

  /// Send CMD_LIST_FILES (0x10) and parse the response:
  ///   [count:1][ts:4LE][size:4LE] × count
  /// Uses a dedicated one-shot listener so it doesn't interfere with the
  /// ongoing sync data stream.
  @override
  Future<List<StorageFile>> performListFiles() async {
    await _storageMutex.acquire();
    try {
      return await _performListFilesLocked();
    } finally {
      _storageMutex.release();
    }
  }

  Future<List<StorageFile>> _performListFilesLocked() async {
    // 1. Clean previous run & increment generation
    await stop();

    // 2. Capture and increment THIS call's generation
    final int gen = ++_listFilesGeneration;
    final currentCompleter = Completer<List<StorageFile>>();
    _listFilesCompleter = currentCompleter;

    final buffer = <int>[];
    int retryCount = 0;
    const int maxRetries = 3;

    bool isStale() => gen != _listFilesGeneration;

    void fail(String reason) {
      if (!currentCompleter.isCompleted) {
        currentCompleter.completeError(TimeoutException(reason));
      }
      if (_listFilesCompleter == currentCompleter) _listFilesCompleter = null;
      unawaited(stop());
    }

    void completeSuccess(List<StorageFile> files) {
      if (!currentCompleter.isCompleted) {
        currentCompleter.complete(files);
      }
      if (_listFilesCompleter == currentCompleter) _listFilesCompleter = null;
      unawaited(stop());
    }

    late void Function() startOrResetTimeout;

    startOrResetTimeout = () {
      _timeoutTimer?.cancel();
      _timeoutTimer = Timer(const Duration(seconds: 35), () => fail("Timeout waiting for file list response"));
    };

    try {
      final stream = await transport.getCharacteristicStream(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid);
      await Future.microtask(() {}); // Ensure listener wiring completes

      _listFilesSub = stream.listen(
        (packet) {
          // 🛑 Ignore ALL stale packets from previous generations
          if (isStale()) return;

          startOrResetTimeout(); // Reset timeout FIRST
          buffer.addAll(packet);
          Logger.debug('performListFiles: RX packet len=${packet.length}');

          if (buffer.isEmpty) return;

          final count = buffer[0];
          if (count == 0xFF) {
            // 0xFF means the firmware SD worker is temporarily busy (e.g. boot GC
            // or LFS allocator scan).  Retry a few times with a short delay before
            // giving up so the caller gets a real file list once the worker is free.
            final errorCode = buffer.length > 1 ? buffer[1] : 0;
            if (retryCount < maxRetries) {
              retryCount++;
              buffer.clear();
              Logger.debug('performListFiles: SD busy (0xFF), error code = -$errorCode, retry $retryCount/$maxRetries in 5s');
              Future.delayed(const Duration(seconds: 5), () async {
                if (isStale() || currentCompleter.isCompleted) return;
                try {
                  await transport.writeCharacteristic(
                      storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x10]);
                  startOrResetTimeout();
                } catch (e) {
                  fail('Retry write failed: $e');
                }
              });
              return;
            }
            fail("Device returned error 0xFF (code -$errorCode)");
            return;
          }
          if (count > 200) {
            fail("Invalid file count: $count");
            return;
          }

          final expectedLen = 1 + count * 8;
          Logger.debug('performListFiles: Buffer len=${buffer.length} / expected=$expectedLen');

          if (buffer.length >= expectedLen) {
            final data = buffer.sublist(0, expectedLen);

            final files = <StorageFile>[];
            for (int i = 0; i < count; i++) {
              final base = 1 + i * 8;
              final ts = data[base] | (data[base + 1] << 8) | (data[base + 2] << 16) | (data[base + 3] << 24);
              final sz = data[base + 4] | (data[base + 5] << 8) | (data[base + 6] << 16) | (data[base + 7] << 24);
              files.add(StorageFile(index: i, timestamp: ts, size: sz));
            }

            completeSuccess(files);
          }
        },
        onError: (e) {
          if (isStale()) return;
          fail("Stream error: $e");
        },
        onDone: () {
          if (isStale()) return;
          if (!currentCompleter.isCompleted) {
            fail("Stream closed before full response received");
          }
        },
      );

      await transport.writeCharacteristic(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x10]);
      startOrResetTimeout();

      return await currentCompleter.future;
    } catch (e) {
      Logger.debug('OmiDeviceConnection: performListFiles error: $e');
      if (!currentCompleter.isCompleted) {
        currentCompleter.complete([]); // Resolve with empty list on error to satisfy callers
      }
      _listFilesCompleter = null;
      return [];
    }
  }

  /// Send CMD_DELETE_FILE (0x12, fileIndex) and wait for PACKET_ACK (0x03, result).
  @override
  Future<bool> performDeleteFile(int fileIndex) async {
    await _storageMutex.acquire();
    try {
      final completer = Completer<bool>();
      StreamSubscription? sub;

      final stream =
          await transport.getCharacteristicStream(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid);
      sub = stream.listen((data) {
        if (completer.isCompleted) return;
        // Expect [PACKET_ACK=0x03][result:1]
        if (data.length >= 2 && data[0] == 0x03) {
          sub?.cancel();
          completer.complete(data[1] == 0);
        } else if (data.length == 1 && data[0] == 0x03) {
          sub?.cancel();
          completer.complete(true); // ACK with no result byte = success
        }
      }, onError: (e) {
        if (!completer.isCompleted) completer.completeError(e);
        sub?.cancel();
      });

      await transport.writeCharacteristic(
          storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x12, fileIndex & 0xFF]);

      try {
        final success = await completer.future.timeout(const Duration(seconds: 5));
        Logger.debug('performDeleteFile($fileIndex): success=$success');
        return success;
      } finally {
        await sub.cancel();
      }
    } catch (e) {
      Logger.debug('OmiDeviceConnection: performDeleteFile error: $e');
      return false;
    } finally {
      _storageMutex.release();
    }
  }

  @override
  Future<bool> performStopStorageSync() async {
    try {
      await transport.writeCharacteristic(
          storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x03]);
      Logger.debug('OmiDeviceConnection: CMD_STOP sent');
      return true;
    } catch (e) {
      Logger.debug('OmiDeviceConnection: performStopStorageSync error: $e');
      return false;
    }
  }

  /// Send CMD_ROTATE_FILE (0x13) and wait for PACKET_ACK (0x03, result).
  /// Firmware sends the ACK only after the old file is sealed and new file is open.
  @override
  Future<bool> performRotateFile() async {
    await _storageMutex.acquire();
    try {
      final completer = Completer<bool>();
      StreamSubscription? sub;

      final stream =
          await transport.getCharacteristicStream(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid);
      sub = stream.listen((data) {
        if (completer.isCompleted) return;
        if (data.length >= 2 && data[0] == 0x03) {
          // PACKET_ACK: result == 0 means success
          sub?.cancel();
          completer.complete(data[1] == 0x00);
        }
      });

      await transport.writeCharacteristic(
          storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid, [0x13]);

      try {
        final success = await completer.future.timeout(const Duration(seconds: 15));
        Logger.debug('OmiDeviceConnection: performRotateFile success=$success');
        return success;
      } finally {
        await sub.cancel();
      }
    } catch (e) {
      Logger.debug('OmiDeviceConnection: performRotateFile error: $e');
      return false;
    } finally {
      _storageMutex.release();
    }
  }

  @override
  Future<bool> performSyncDeviceTime() async {
    try {
      int epoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await transport.writeCharacteristic(timeSyncServiceUuid, timeSyncWriteCharacteristicUuid, [
        epoch & 0xFF,
        (epoch >> 8) & 0xFF,
        (epoch >> 16) & 0xFF,
        (epoch >> 24) & 0xFF,
      ]);
      Logger.debug('OmiDeviceConnection: Successfully synced device time to epoch: $epoch');
      return true;
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Failed to sync device time: $e');
      return false;
    }
  }
}
