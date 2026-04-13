import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:omi/utils/device.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/gen/assets.gen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceUtils.shouldUpdateFirmware', () {
    test('returns Not Available when latestFirmwareDetails is empty', () async {
      final result = await DeviceUtils.shouldUpdateFirmware(
        currentFirmware: '1.0.0',
        latestFirmwareDetails: {},
      );
      expect(result.$1, 'Latest Version Not Available');
      expect(result.$2, false);
      expect(result.$3, '');
    });

    test('returns Not Available when version is null', () async {
      final result = await DeviceUtils.shouldUpdateFirmware(
        currentFirmware: '1.0.0',
        latestFirmwareDetails: {'version': null},
      );
      expect(result.$1, 'Latest Version Not Available');
      expect(result.$2, false);
      expect(result.$3, '');
    });

    test('returns Not Available when draft is true', () async {
      final result = await DeviceUtils.shouldUpdateFirmware(
        currentFirmware: '1.0.0',
        latestFirmwareDetails: {'version': '1.1.0', 'draft': true},
      );
      expect(result.$1, 'Latest Version Not Available');
      expect(result.$2, false);
      expect(result.$3, '');
    });

    test('returns 0 when current is less than min_version', () async {
      final result = await DeviceUtils.shouldUpdateFirmware(
        currentFirmware: '0.9.0',
        latestFirmwareDetails: {
          'version': '1.1.0',
          'draft': false,
          'min_version': '1.0.0',
        },
      );
      expect(result.$1, '0');
      expect(result.$2, false);
      expect(result.$3, '1.1.0');
    });

    test('returns already on latest when current >= latest', () async {
      final result = await DeviceUtils.shouldUpdateFirmware(
        currentFirmware: '1.2.0',
        latestFirmwareDetails: {
          'version': '1.1.0',
          'draft': false,
          'min_version': '1.0.0',
        },
      );
      expect(result.$1, 'You are already on the latest version');
      expect(result.$2, false);
      expect(result.$3, '1.1.0');
    });

    test('returns update available when app version is compatible', () async {
      PackageInfo.setMockInitialValues(
        appName: 'TestApp',
        packageName: 'com.test',
        version: '2.0.0',
        buildNumber: '10',
        buildSignature: '',
        installerStore: '',
      );

      final result = await DeviceUtils.shouldUpdateFirmware(
        currentFirmware: '1.0.0',
        latestFirmwareDetails: {
          'version': '1.1.0',
          'draft': false,
          'min_version': '1.0.0',
          'min_app_version': '1.5.0',
          'min_app_version_code': '5',
        },
      );
      expect(result.$1, 'A new version is available! Update your Omi now.');
      expect(result.$2, true);
      expect(result.$3, '1.1.0');
    });

    test('returns incompatible message with App Store when app version is too low on iOS', () async {
      DeviceUtils.debugDefaultTargetPlatformIsAndroidOverride = false;
      PackageInfo.setMockInitialValues(
        appName: 'TestApp',
        packageName: 'com.test',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
        installerStore: '',
      );

      final result = await DeviceUtils.shouldUpdateFirmware(
        currentFirmware: '1.0.0',
        latestFirmwareDetails: {
          'version': '1.1.0',
          'draft': false,
          'min_version': '1.0.0',
          'min_app_version': '2.0.0',
          'min_app_version_code': '10',
        },
      );
      expect(result.$1, contains('not compatible with this version of App'));
      expect(result.$1, contains('App Store'));
      expect(result.$2, false);
      expect(result.$3, '1.1.0');
    });

    test('returns incompatible message with Play Store when app version is too low on Android', () async {
      DeviceUtils.debugDefaultTargetPlatformIsAndroidOverride = true;
      PackageInfo.setMockInitialValues(
        appName: 'TestApp',
        packageName: 'com.test',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
        installerStore: '',
      );

      final result = await DeviceUtils.shouldUpdateFirmware(
        currentFirmware: '1.0.0',
        latestFirmwareDetails: {
          'version': '1.1.0',
          'draft': false,
          'min_version': '1.0.0',
          'min_app_version': '2.0.0',
          'min_app_version_code': '10',
        },
      );
      expect(result.$1, contains('not compatible with this version of App'));
      expect(result.$1, contains('Play Store'));
      expect(result.$2, false);
      expect(result.$3, '1.1.0');
    });

    test('returns Not Available when draft is missing and handled correctly', () async {
      final result = await DeviceUtils.shouldUpdateFirmware(
        currentFirmware: '0.9.0',
        latestFirmwareDetails: {
          'version': '1.1.0',
          'min_version': '1.0.0',
        }, // 'draft' is missing
      );

      // Since current (0.9.0) < min (1.0.0), it should return '0'
      expect(result.$1, '0');
      expect(result.$2, false);
      expect(result.$3, '1.1.0');
    });

    tearDown(() {
      DeviceUtils.debugDefaultTargetPlatformIsAndroidOverride = null;
    });
  });

  group('DeviceUtils.getDeviceImagePath', () {
    test('always returns omiWithoutRope (CV1 only)', () {
      // CV1-only mode: all inputs resolve to the same image.
      expect(DeviceUtils.getDeviceImagePath(), Assets.images.omiWithoutRope.path);
      expect(DeviceUtils.getDeviceImagePath(deviceType: DeviceType.omi), Assets.images.omiWithoutRope.path);
      expect(DeviceUtils.getDeviceImagePath(modelNumber: 'GLASS'), Assets.images.omiWithoutRope.path);
      expect(DeviceUtils.getDeviceImagePath(deviceName: 'NEO'), Assets.images.omiWithoutRope.path);
    });
  });

  group('DeviceUtils.getDeviceImageFromBtDevice', () {
    test('returns omiWithoutRope for any BtDevice', () {
      final device = BtDevice(id: 'test_id', name: 'GLASS', type: DeviceType.omi, rssi: -50);
      expect(DeviceUtils.getDeviceImageFromBtDevice(device), Assets.images.omiWithoutRope.path);
    });
  });

  group('DeviceUtils.getDeviceImagePathWithState', () {
    test('returns omiWithoutRopeTurnedOff when disconnected', () {
      expect(
        DeviceUtils.getDeviceImagePathWithState(deviceType: DeviceType.omi, isConnected: false),
        Assets.images.omiWithoutRopeTurnedOff.path,
      );
    });

    test('returns omiWithoutRope when connected', () {
      expect(
        DeviceUtils.getDeviceImagePathWithState(deviceType: DeviceType.omi, isConnected: true),
        Assets.images.omiWithoutRope.path,
      );
    });
  });

  group('DeviceUtils.getDeviceImagePathByModel', () {
    test('returns omiWithoutRope for any model string', () {
      expect(DeviceUtils.getDeviceImagePathByModel('GLASS'), Assets.images.omiWithoutRope.path);
      expect(DeviceUtils.getDeviceImagePathByModel(null), Assets.images.omiWithoutRope.path);
    });
  });
}
