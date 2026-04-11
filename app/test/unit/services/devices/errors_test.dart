import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/devices/errors.dart';

void main() {
  group('Device Exceptions', () {
    test('DeviceConnectionException toString() returns correct format', () {
      final exception = DeviceConnectionException('Connection failed');
      expect(exception.toString(), 'DeviceConnectionException: Connection failed');
    });

    test('DeviceDiscoveryException toString() returns correct format', () {
      final exception = DeviceDiscoveryException('Device not found');
      expect(exception.toString(), 'DeviceDiscoveryException: Device not found');
    });
  });
}
