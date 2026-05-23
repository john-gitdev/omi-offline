import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/bridges/ble_bridge.dart';

void main() {
  group('BleBridge', () {
    late BleBridge bleBridge;

    setUp(() {
      bleBridge = BleBridge.instance;
    });

    test('should be a singleton', () {
      expect(BleBridge.instance, same(bleBridge));
    });

    test('onPeripheralDiscovered should emit to onDeviceFound stream', () async {
      final peripheral = BlePeripheral(uuid: 'test-uuid', name: 'Test Device', rssi: -50, serviceUuids: []);

      expectLater(bleBridge.onDeviceFound, emits(peripheral));

      bleBridge.onPeripheralDiscovered(peripheral);
    });

    test('onPeripheralConnected should emit to onDeviceConnected stream', () async {
      const peripheralUuid = 'test-uuid';

      expectLater(bleBridge.onDeviceConnected, emits(peripheralUuid));

      bleBridge.onPeripheralConnected(peripheralUuid);
    });

    test('onPeripheralDisconnected should trigger callbacks and emit to disconnected stream', () async {
      const peripheralUuid = 'TEST-UUID';
      bool disconnected = false;
      String? callbackError;

      bleBridge.registerPeripheral(
        peripheralUuid: peripheralUuid,
        onConnectionState: (connected, error) {
          disconnected = !connected;
          callbackError = error;
        },
      );

      expectLater(bleBridge.onDeviceDisconnected, emits(peripheralUuid));

      bleBridge.onPeripheralDisconnected(peripheralUuid, 'connection lost');

      expect(disconnected, isTrue);
      expect(callbackError, 'connection lost');

      bleBridge.unregisterPeripheral(peripheralUuid);
    });

    test('should route peripheral specific callbacks based on upper-cased UUID', () {
      const peripheralUuid = 'test-uuid';

      bool connected = false;
      bool servicesDiscovered = false;
      bool deviceReady = false;
      bool characteristicUpdated = false;

      bleBridge.registerPeripheral(
        peripheralUuid: peripheralUuid,
        onConnectionState: (c, _) => connected = c,
        onServicesDiscovered: (_) => servicesDiscovered = true,
        onDeviceReady: (_) => deviceReady = true,
        onCharacteristicValue: (_, __, ___) => characteristicUpdated = true,
      );

      // Verify routing via pigeon callbacks
      bleBridge.onPeripheralConnected(peripheralUuid); // BleBridge internally upper-cases
      expect(connected, isTrue);

      bleBridge.onServicesDiscovered(peripheralUuid, []);
      expect(servicesDiscovered, isTrue);

      bleBridge.onDeviceReady(peripheralUuid, []);
      expect(deviceReady, isTrue);

      bleBridge.onCharacteristicValueUpdated(peripheralUuid, 'service', 'char', Uint8List(0));
      expect(characteristicUpdated, isTrue);

      bleBridge.unregisterPeripheral(peripheralUuid);
    });
  });
}
