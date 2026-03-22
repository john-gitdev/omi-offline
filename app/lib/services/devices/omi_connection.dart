import 'dart:async';
import 'dart:typed_data';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/utils/logger.dart';

class OmiDeviceConnection extends DeviceConnection {
  OmiDeviceConnection(super.device, super.transport);

  @override
  Future<void> connect({void Function(String deviceId, DeviceConnectionState state)? onConnectionStateChanged}) async {
    await super.connect(onConnectionStateChanged: onConnectionStateChanged);
    await performSyncTime();
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
    // Try richer detail characteristic first (4-byte: mv_lo, mv_hi, pct, charging)
    try {
      final detail = await transport.readCharacteristic(batteryDetailServiceUuid, batteryDetailCharacteristicUuid);
      if (detail.length >= 4) return detail[2];
    } catch (_) {}
    // Fall back to standard BAS
    try {
      final data = await transport.readCharacteristic(batteryServiceUuid, batteryLevelCharacteristicUuid);
      if (data.isNotEmpty) return data[0];
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error reading battery level: $e');
    }
    return -1;
  }

  @override
  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener({
    void Function(int)? onBatteryLevelChange,
    void Function(bool)? onChargingStateChange,
  }) async {
    // Prefer the detail characteristic — 4-byte payload: [mv_lo, mv_hi, percentage, charging]
    try {
      final stream = transport.getCharacteristicStream(batteryDetailServiceUuid, batteryDetailCharacteristicUuid);
      final subscription = stream.listen((value) {
        if (value.length >= 4) {
          if (onBatteryLevelChange != null) onBatteryLevelChange(value[2]); // byte 2 = percentage
          if (onChargingStateChange != null) onChargingStateChange(value[3] != 0); // byte 3 = charging
        }
      });
      return subscription;
    } catch (_) {}
    // Fall back to standard BAS
    try {
      final stream = transport.getCharacteristicStream(batteryServiceUuid, batteryLevelCharacteristicUuid);
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
  Future<List<int>> performGetButtonState() async {
    try {
      return await transport.readCharacteristic(buttonServiceUuid, buttonTriggerCharacteristicUuid);
    } catch (e) {
      Logger.debug('OmiDeviceConnection: Error reading button state: $e');
      return <int>[];
    }
  }

  @override
  Future<StreamSubscription<List<int>>?> performGetBleButtonListener({
    required void Function(List<int>) onButtonReceived,
  }) async {
    try {
      final stream = transport.getCharacteristicStream(buttonServiceUuid, buttonTriggerCharacteristicUuid);

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
  Future<BleAudioCodec> performGetAudioCodec() async {
    try {
      final codecValue = await transport.readCharacteristic(omiServiceUuid, audioCodecCharacteristicUuid);

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
}
