import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/omi_connection.dart';
import 'package:omi/services/devices/transports/device_transport.dart';

class MockDeviceTransport implements DeviceTransport {
  bool throwOnModel = false;
  bool throwOnFw = false;
  bool throwOnHw = false;
  bool throwOnManuf = false;
  bool throwOnSn = false;
  bool throwOnButtonConfig = false;

  List<int>? mockButtonConfig;
  List<int>? lastWrittenButtonConfig;

  // Generic stub for read-and-parse paths (diagnostics, drop stats, storage
  // stats, battery): map a characteristic UUID to the raw bytes the firmware
  // would return, or list it in [throwReads] to simulate an unsupported char.
  final Map<String, List<int>> reads = {};
  final Set<String> throwReads = {};

  bool throwAllInner = false;
  bool throwOuter = false;

  @override
  String get deviceId => 'test_device_id';

  @override
  Future<void> connect({bool requiresBond = false}) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> softDisconnect() async {}

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
    if (throwReads.contains(characteristicUuid)) {
      throw Exception('char unsupported');
    }
    if (reads.containsKey(characteristicUuid)) {
      return reads[characteristicUuid]!;
    }
    if (throwOuter) {
      throw Exception(
          'Outer failure'); // will not be caught by inner if not in the inner try blocks, but since all readCharacteristics are inside inner try blocks, this will just be caught by inner try blocks
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

  // Little-endian u32 byte builder used to assemble fake diagnostics payloads.
  List<int> le32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
  List<int> concat(List<List<int>> parts) => [for (final p in parts) ...p];

  group('OmiDeviceConnection diagnostics / drop-stats parsing', () {
    late MockDeviceTransport transport;
    late OmiDeviceConnection connection;

    setUp(() {
      transport = MockDeviceTransport();
      connection = OmiDeviceConnection(
        BtDevice(id: 'test_id', name: 'Test Device', type: DeviceType.omi, rssi: 0),
        transport,
      );
    });

    test('performGetDiagnostics parses reset cause + uptime (8-byte payload)', () async {
      transport.reads[OmiDeviceConnection.diagnosticsCharacteristicUuid] = concat([le32(0x110), le32(4242)]);
      final log = await connection.performGetDiagnostics();
      expect(log, isNotNull);
      expect(log!.resetCause, 0x110);
      expect(log.uptimeSeconds, 4242);
      expect(log.isCrash, isTrue);
      expect(log.deviceId, 'test_id');
    });

    test('performGetDiagnostics returns null on a short (<8 byte) payload', () async {
      transport.reads[OmiDeviceConnection.diagnosticsCharacteristicUuid] = le32(0x10); // only 4 bytes
      expect(await connection.performGetDiagnostics(), isNull);
    });

    test('performGetDiagnostics returns null when the char is unsupported', () async {
      transport.throwReads.add(OmiDeviceConnection.diagnosticsCharacteristicUuid);
      expect(await connection.performGetDiagnostics(), isNull);
    });

    test('performGetDropStats parses the legacy 20-byte payload, appended fields default to 0', () async {
      transport.reads[OmiDeviceConnection.diagnosticsDropsCharacteristicUuid] = concat([
        le32(3), // blockDrops
        le32(5000), // lastBlockDropUptimeMs
        le32(7), // streamFrameDrops
        le32(2), // bootFrameDrops
        le32(9000), // currentUptimeMs
      ]);
      final s = await connection.performGetDropStats();
      expect(s, isNotNull);
      expect(s!.blockDrops, 3);
      expect(s.streamFrameDrops, 7);
      expect(s.bootFrameDrops, 2);
      expect(s.msSinceLastBlockDrop, 4000);
      // Not present in a 20-byte payload.
      expect(s.failedConnCount, 0);
      expect(s.lastFailedConnDuringSlowAdv, isFalse);
      expect(s.codecFrameDrops, 0);
      expect(s.msgqPeakDepth, 0);
      expect(s.writeFairActivations, 0);
    });

    test('performGetDropStats parses appended fields from a full 40-byte payload', () async {
      transport.reads[OmiDeviceConnection.diagnosticsDropsCharacteristicUuid] = concat([
        le32(0), // blockDrops
        le32(0), // lastBlockDropUptimeMs
        le32(0), // streamFrameDrops
        le32(0), // bootFrameDrops
        le32(12345), // currentUptimeMs
        le32(4), // failedConnCount (offset 20)
        le32(1), // lastFailedConnDuringSlowAdv == 1 (offset 24)
        le32(6), // codecFrameDrops (offset 28)
        le32(57), // msgqPeakDepth (offset 32)
        le32(8), // writeFairActivations (offset 36)
      ]);
      final s = await connection.performGetDropStats();
      expect(s, isNotNull);
      expect(s!.failedConnCount, 4);
      expect(s.lastFailedConnDuringSlowAdv, isTrue);
      expect(s.codecFrameDrops, 6);
      expect(s.msgqPeakDepth, 57);
      expect(s.writeFairActivations, 8);
      expect(s.msSinceLastBlockDrop, isNull, reason: 'no block drop recorded');
    });

    test('performGetDropStats returns null on a short (<20 byte) payload', () async {
      transport.reads[OmiDeviceConnection.diagnosticsDropsCharacteristicUuid] = concat([le32(1), le32(2)]);
      expect(await connection.performGetDropStats(), isNull);
    });

    test('performGetStorageFileStats parses used/count, freeBytes defaults to 0 on 8-byte payload', () async {
      transport.reads[OmiDeviceConnection.storageReadControlCharacteristicUuid] = concat([le32(1048576), le32(12)]);
      final stats = await connection.performGetStorageFileStats();
      expect(stats, isNotNull);
      expect(stats!.totalUsedBytes, 1048576);
      expect(stats.fileCount, 12);
      expect(stats.freeBytes, 0);
    });

    test('performGetStorageFileStats reads freeBytes when the 12-byte payload is present', () async {
      transport.reads[OmiDeviceConnection.storageReadControlCharacteristicUuid] =
          concat([le32(1048576), le32(12), le32(2097152)]);
      final stats = await connection.performGetStorageFileStats();
      expect(stats!.freeBytes, 2097152);
    });

    test('performGetStorageFileStats returns null on a short payload', () async {
      transport.reads[OmiDeviceConnection.storageReadControlCharacteristicUuid] = le32(5); // 4 bytes
      expect(await connection.performGetStorageFileStats(), isNull);
    });

    test('performRetrieveBatteryLevel returns the first byte, or -1 on empty/error', () async {
      transport.reads[OmiDeviceConnection.batteryLevelCharacteristicUuid] = [83];
      expect(await connection.performRetrieveBatteryLevel(), 83);

      transport.reads[OmiDeviceConnection.batteryLevelCharacteristicUuid] = <int>[];
      expect(await connection.performRetrieveBatteryLevel(), -1);

      transport.reads.remove(OmiDeviceConnection.batteryLevelCharacteristicUuid);
      transport.throwReads.add(OmiDeviceConnection.batteryLevelCharacteristicUuid);
      expect(await connection.performRetrieveBatteryLevel(), -1);
    });

    test('performRetrieveChargingState is true only when the first byte is 1', () async {
      transport.reads[OmiDeviceConnection.batteryDetailCharacteristicUuid] = [1];
      expect(await connection.performRetrieveChargingState(), isTrue);

      transport.reads[OmiDeviceConnection.batteryDetailCharacteristicUuid] = [0];
      expect(await connection.performRetrieveChargingState(), isFalse);

      transport.reads.remove(OmiDeviceConnection.batteryDetailCharacteristicUuid);
      transport.throwReads.add(OmiDeviceConnection.batteryDetailCharacteristicUuid);
      expect(await connection.performRetrieveChargingState(), isFalse);
    });
  });
}
