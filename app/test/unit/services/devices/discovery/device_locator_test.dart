import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/devices/discovery/device_locator.dart';

void main() {
  group('DeviceLocator', () {
    group('factories', () {
      test('bluetooth factory creates correct instance', () {
        const deviceId = 'test-device-id';
        final locator = DeviceLocator.bluetooth(deviceId: deviceId);

        expect(locator.kind, DeviceLocatorKind.bluetooth);
        expect(locator.deviceId, deviceId);
      });

      test('watch factory creates correct instance', () {
        final locator = DeviceLocator.watch();

        expect(locator.kind, DeviceLocatorKind.watch);
        expect(locator.deviceId, isNull);
      });
    });

    group('serialization', () {
      test('toJson serializes bluetooth locator correctly', () {
        const deviceId = 'test-device-id';
        final locator = DeviceLocator.bluetooth(deviceId: deviceId);

        final json = locator.toJson();

        expect(json['kind'], DeviceLocatorKind.bluetooth.index);
        expect(json['deviceId'], deviceId);
      });

      test('toJson serializes watch locator correctly', () {
        final locator = DeviceLocator.watch();

        final json = locator.toJson();

        expect(json['kind'], DeviceLocatorKind.watch.index);
        expect(json['deviceId'], isNull);
      });

      test('fromJson deserializes bluetooth locator correctly', () {
        const deviceId = 'test-device-id';
        final json = {
          'kind': DeviceLocatorKind.bluetooth.index,
          'deviceId': deviceId,
        };

        final locator = DeviceLocator.fromJson(json);

        expect(locator.kind, DeviceLocatorKind.bluetooth);
        expect(locator.deviceId, deviceId);
      });

      test('fromJson deserializes watch locator correctly', () {
        final json = {
          'kind': DeviceLocatorKind.watch.index,
          'deviceId': null,
        };

        final locator = DeviceLocator.fromJson(json);

        expect(locator.kind, DeviceLocatorKind.watch);
        expect(locator.deviceId, isNull);
      });

      test('fromJson handles missing deviceId key for watch', () {
        final json = {
          'kind': DeviceLocatorKind.watch.index,
          // deviceId is missing
        };

        final locator = DeviceLocator.fromJson(json);

        expect(locator.kind, DeviceLocatorKind.watch);
        expect(locator.deviceId, isNull);
      });
    });
  });
}
