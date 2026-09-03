import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'package:omi/services/devices/transports/device_transport.dart';

class MockDeviceTransport implements DeviceTransport {
  @override
  Stream<DeviceTransportState> get connectionStateStream => const Stream.empty();

  @override
  Future<void> connect({bool requiresBond = false}) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> softDisconnect() async {}

  @override
  Future<bool> requestBond() async {
    return true;
  }

  @override
  String get deviceId => 'test_id';

  @override
  bool get requiresBond => false;

  @override
  Future<void> dispose() async {}

  @override
  Future<Stream<List<int>>> getCharacteristicStream(String serviceUuid, String characteristicUuid) async {
    return const Stream.empty();
  }

  @override
  Future<void> unsubscribeCharacteristic(String serviceUuid, String characteristicUuid) async {}

  @override
  Future<bool> isConnected() async {
    return true;
  }

  @override
  Future<bool> ping() async {
    return true;
  }

  @override
  Future<List<int>> readCharacteristic(String serviceUuid, String characteristicUuid) async {
    return [];
  }

  @override
  Future<void> writeCharacteristic(String serviceUuid, String characteristicUuid, List<int> data) async {}
}

class MockDeviceConnection extends DeviceConnection {
  final Future<BtDevice> Function(DeviceConnection?)? onPerformGetDeviceInfo;

  MockDeviceConnection(BtDevice device, {this.onPerformGetDeviceInfo}) : super(device, MockDeviceTransport());

  @override
  bool get isStorageBusy => false;

  @override
  Future<void> acquireStorageLock([String owner = 'unknown']) async {}

  @override
  Future<Stream<List<int>>> getBleStorageBytesStream() async {
    return const Stream.empty();
  }

  @override
  Future<StorageFileStats?> performGetStorageFileStats() async {
    return null;
  }

  @override
  Future<bool> performClearStorage() async {
    return false;
  }

  @override
  Future<bool> performDeleteFile(StorageFile file, {int? timestamp}) async {
    return false;
  }

  @override
  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener(
      {void Function(int p1)? onBatteryLevelChange, void Function(bool p1)? onChargingStateChange}) async {
    return null;
  }

  @override
  Future<({bool muted, DateTime? since})?> performGetMuteState() async {
    return (muted: false, since: null);
  }

  @override
  Future<bool> performSetMute(bool muted) async => true;

  @override
  Future<StreamSubscription<List<int>>?> performGetMuteListener(
      {required void Function(bool muted, DateTime? since) onMuteChange}) async {
    return null;
  }

  @override
  Future<BtDevice> performGetDeviceInfo(DeviceConnection? connection) async {
    if (onPerformGetDeviceInfo != null) {
      return onPerformGetDeviceInfo!(connection);
    }
    return device;
  }

  @override
  Future<int> performGetFeatures() async {
    return 0;
  }

  @override
  Future<int?> performGetLedDimRatio() async {
    return null;
  }

  @override
  Future<int?> performGetMicGain() async {
    return null;
  }

  @override
  Future<List<int>> performGetStorageList() async {
    return [];
  }

  @override
  Future<StorageListing?> performListFiles() async {
    return (files: <StorageFile>[], complete: true);
  }

  @override
  Future<Stream<List<int>>> performReadFile(StorageFile file, {int offset = 0}) async {
    return const Stream.empty();
  }

  @override
  Future<int> performRetrieveBatteryLevel() async {
    return -1;
  }

  @override
  Future<bool> performRetrieveChargingState() async {
    return false;
  }

  @override
  Future<bool> performRotateFile() async {
    return false;
  }

  @override
  Future<void> performSetLedDimRatio(int ratio) async {}

  @override
  Future<void> performSetConnectedLed(bool enabled) async {}

  @override
  Future<bool?> performGetConnectedLed() async => null;

  @override
  Future<void> performSetLedBootEnabled(bool enabled) async {}

  @override
  Future<bool?> performGetLedBootEnabled() async => null;

  @override
  Future<void> performSetMicGain(int gain) async {}

  @override
  Future<void> performSetButtonConfig(List<int> config) async {}

  @override
  Future<List<int>?> performGetButtonConfig() async {
    return null;
  }

  @override
  Future<void> performSetHapticConfig(List<int> config) async {}

  @override
  Future<List<int>?> performGetHapticConfig() async {
    return null;
  }

  @override
  Future<int?> performGetVadThreshold() async {
    return null;
  }

  @override
  Future<void> performSetVadThreshold(int threshold) async {}

  @override
  Future<int?> performGetPriorityRecordCap() async {
    return null;
  }

  @override
  Future<void> performSetPriorityRecordCap(int minutes) async {}

  @override
  Future<bool> performStopStorageSync() async {
    return false;
  }

  @override
  Future<bool> performSyncDeviceTime() async {
    return false;
  }

  @override
  Future<bool> performWriteToStorage(int numFile, int command, int offset, {int? timestamp}) async {
    return false;
  }

  @override
  void releaseStorageLock() {}
}

void main() {
  group('BtDevice', () {
    test('getDeviceInfo handles null connection', () async {
      final device = BtDevice(id: '1', name: 'Test', type: DeviceType.omi, rssi: 0);
      final result = await device.getDeviceInfo(null);
      expect(result, equals(device));
    });

    test('getDeviceInfo handles successful device info retrieval', () async {
      final device = BtDevice(id: '1', name: 'Test', type: DeviceType.omi, rssi: 0);
      final updatedDevice = device.copyWith(hardwareRevision: 'v2');

      final mockConnection = MockDeviceConnection(
        device,
        onPerformGetDeviceInfo: (conn) async => updatedDevice,
      );

      final result = await device.getDeviceInfo(mockConnection);
      expect(result, equals(updatedDevice));
    });

    test('getDeviceInfo handles exceptions from connection gracefully', () async {
      final device = BtDevice(id: '1', name: 'Test', type: DeviceType.omi, rssi: 0);

      final mockConnection = MockDeviceConnection(
        device,
        onPerformGetDeviceInfo: (conn) async {
          throw Exception('Simulated connection failure');
        },
      );

      final result = await device.getDeviceInfo(mockConnection);
      expect(result, equals(device));
    });
  });
}
