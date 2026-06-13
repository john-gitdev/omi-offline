import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/omi_connection.dart';
import 'package:omi/services/devices/transports/device_transport.dart';

class MockDeviceTransport implements DeviceTransport {
  @override
  Future<void>? get gattConnectFuture => null;

  bool throwOnModel = false;
  bool throwOnFw = false;
  bool throwOnHw = false;
  bool throwOnManuf = false;
  bool throwOnSn = false;
  bool throwOnButtonConfig = false;

  List<int>? mockButtonConfig;
  List<int>? lastWrittenButtonConfig;

  bool throwAllInner = false;
  bool throwOuter = false;

  @override
  String get deviceId => 'test_device_id';

  @override
  Future<void> connect({bool requiresBond = false}) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<bool> isConnected() async => true;

  @override
  Future<bool> ping() async => true;

  @override
  Future<bool> requestBond() async => true;

  @override
  Future<Stream<List<int>>> getCharacteristicStream(String serviceUuid, String characteristicUuid) async {
    return const Stream.empty();
  }

  @override
  Future<List<int>> readCharacteristic(String serviceUuid, String characteristicUuid) async {
    if (throwOuter) {
      throw Exception('Outer failure'); // will not be caught by inner if not in the inner try blocks, but since all readCharacteristics are inside inner try blocks, this will just be caught by inner try blocks
    }

    if (throwAllInner) {
      throw Exception('Inner failure');
    }

    if (characteristicUuid == OmiDeviceConnection.disModelNumberCharacteristicUuid) {
      if (throwOnModel) throw Exception('Model exception');
      return 'MockModel'.codeUnits;
    }
    if (characteristicUuid == OmiDeviceConnection.disFirmwareRevisionCharacteristicUuid) {
      if (throwOnFw) throw Exception('FW exception');
      return '1.0.0'.codeUnits;
    }
    if (characteristicUuid == OmiDeviceConnection.disHardwareRevisionCharacteristicUuid) {
      if (throwOnHw) throw Exception('HW exception');
      return '2.0'.codeUnits;
    }
    if (characteristicUuid == OmiDeviceConnection.disManufacturerNameCharacteristicUuid) {
      if (throwOnManuf) throw Exception('Manuf exception');
      return 'OmiCorp'.codeUnits;
    }
    if (characteristicUuid == OmiDeviceConnection.disSerialNumberCharacteristicUuid) {
      if (throwOnSn) throw Exception('SN exception');
      return 'SN12345'.codeUnits;
    }
    if (characteristicUuid == OmiDeviceConnection.buttonConfigCharacteristicUuid) {
      if (throwOnButtonConfig) throw Exception('Button config exception');
      return mockButtonConfig ?? [0, 0, 2, 1, 3, 0];
    }

    return [];
  }

  @override
  Future<void> writeCharacteristic(String serviceUuid, String characteristicUuid, List<int> data) async {
    if (characteristicUuid == OmiDeviceConnection.buttonConfigCharacteristicUuid) {
      if (throwOnButtonConfig) throw Exception('Button config exception');
      lastWrittenButtonConfig = List.from(data);
    }
  }

  @override
  Stream<DeviceTransportState> get connectionStateStream => const Stream.empty();

  @override
  Future<void> dispose() async {}
}

void main() {
  group('OmiDeviceConnection.performGetDeviceInfo Tests', () {
    late BtDevice baseDevice;
    late MockDeviceTransport transport;
    late OmiDeviceConnection connection;

    setUp(() {
      baseDevice = BtDevice(id: 'test_id', name: 'Test Device', type: DeviceType.omi, rssi: 0);
      transport = MockDeviceTransport();
      connection = OmiDeviceConnection(baseDevice, transport);
    });

    test('Happy path: correctly fetches all device info characteristics', () async {
      final device = await connection.performGetDeviceInfo(null);

      expect(device.modelNumber, 'MockModel');
      expect(device.firmwareRevision, '1.0.0');
      expect(device.hardwareRevision, '2.0');
      expect(device.manufacturerName, 'OmiCorp');
      expect(device.serialNumber, 'SN12345');
    });

    test('Partial failure: handles exception on single characteristic (model number) and fetches the rest', () async {
      transport.throwOnModel = true;

      final device = await connection.performGetDeviceInfo(null);

      expect(device.modelNumber, isNull);
      expect(device.firmwareRevision, '1.0.0');
      expect(device.hardwareRevision, '2.0');
      expect(device.manufacturerName, 'OmiCorp');
      expect(device.serialNumber, 'SN12345');
    });

    test('Partial failure: handles exception on hardware revision', () async {
      transport.throwOnHw = true;

      final device = await connection.performGetDeviceInfo(null);

      expect(device.modelNumber, 'MockModel');
      expect(device.firmwareRevision, '1.0.0');
      expect(device.hardwareRevision, isNull);
      expect(device.manufacturerName, 'OmiCorp');
      expect(device.serialNumber, 'SN12345');
    });

    test('Total failure: handles exceptions on all characteristics safely via inner catch blocks', () async {
      transport.throwAllInner = true;

      final device = await connection.performGetDeviceInfo(null);

      expect(device.modelNumber, isNull);
      expect(device.firmwareRevision, isNull);
      expect(device.hardwareRevision, isNull);
      expect(device.manufacturerName, isNull);
      expect(device.serialNumber, isNull);

      // The core device identity should remain unaffected
      expect(device.id, 'test_id');
      expect(device.name, 'Test Device');
    });
  });

  group('OmiDeviceConnection Button Config Tests', () {
    late BtDevice baseDevice;
    late MockDeviceTransport transport;
    late OmiDeviceConnection connection;

    setUp(() {
      baseDevice = BtDevice(id: 'test_id', name: 'Test Device', type: DeviceType.omi, rssi: 0);
      transport = MockDeviceTransport();
      connection = OmiDeviceConnection(baseDevice, transport);
    });

    test('getButtonConfig happy path', () async {
      transport.mockButtonConfig = [0, 1, 2, 3, 0, 1];
      final config = await connection.performGetButtonConfig();
      expect(config, [0, 1, 2, 3, 0, 1]);
    });

    test('getButtonConfig invalid length returns null safely', () async {
      transport.mockButtonConfig = [0, 1, 2]; // Too short
      final config = await connection.performGetButtonConfig();
      expect(config, isNull);
    });

    test('getButtonConfig exception returns null safely', () async {
      transport.throwOnButtonConfig = true;
      final config = await connection.performGetButtonConfig();
      expect(config, isNull);
    });

    test('setButtonConfig happy path', () async {
      await connection.performSetButtonConfig([3, 2, 1, 0, 1, 2]);
      expect(transport.lastWrittenButtonConfig, [3, 2, 1, 0, 1, 2]);
    });

    test('setButtonConfig handles exception safely', () async {
      transport.throwOnButtonConfig = true;
      // Should not throw
      await connection.performSetButtonConfig([0, 0, 0, 0, 0, 0]);
    });
  });
}
