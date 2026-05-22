import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/bridges/ble_bridge.dart';

void main() {
  group('BleBridge Pigeon Interface Stream Tests', () {
    late BleBridge bleBridge;

    setUp(() {
      bleBridge = BleBridge.instance;
    });

    test('onPeripheralDiscovered emits to onDeviceFound stream', () async {
      final peripheral = BlePeripheral(
        uuid: 'test-uuid',
        name: 'test-name',
        rssi: -50,
        serviceUuids: ['test-service'],
      );

      expect(bleBridge.onDeviceFound, emits(peripheral));

      bleBridge.onPeripheralDiscovered(peripheral);
    });

    test('onPeripheralConnected emits to onDeviceConnected stream', () async {
      expect(bleBridge.onDeviceConnected, emits('test-uuid'));

      bleBridge.onPeripheralConnected('test-uuid');
    });

    test('onPeripheralDisconnected emits to onDeviceDisconnected stream', () async {
      expect(bleBridge.onDeviceDisconnected, emits('test-uuid'));

      bleBridge.onPeripheralDisconnected('test-uuid', 'error');
    });
  });
}
