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

    test('returns already on latest when current is greater than or equal to latest', () async {
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

    test('returns update available when compatible with app', () async {
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

    test('returns incompatible app when app version is too low', () async {
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
      expect(result.$2, false);
      expect(result.$3, '1.1.0');
    });
  });

  group('DeviceUtils.getDeviceImagePath', () {
    test('resolves based on deviceType correctly', () {
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: DeviceType.limitless),
          Assets.images.omiWithoutRope.path); // fallback as removed
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: DeviceType.bee),
          Assets.images.beeDevice.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: DeviceType.openglass),
          Assets.images.omiGlass.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: DeviceType.frame),
          Assets.images.omiWithoutRope.path); // fallback as removed
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: DeviceType.appleWatch),
          Assets.images.appleWatch.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: DeviceType.plaud),
          Assets.images.plaudNotePin.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: DeviceType.fieldy),
          Assets.images.fieldy.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: DeviceType.friendPendant),
          Assets.images.friendPendant.path);
    });

    test('resolves DeviceType.omi based on modelNumber', () {
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: DeviceType.omi, modelNumber: 'GLASS'),
          Assets.images.omiGlass.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: DeviceType.omi, modelNumber: 'NEO'),
          Assets.images.neoOne.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: DeviceType.omi, modelNumber: 'UNKNOWN'),
          Assets.images.omiWithoutRope.path); // default fallback
    });

    test('resolves DeviceType.omi based on deviceName if modelNumber is null', () {
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: DeviceType.omi, deviceName: 'GLASS'),
          Assets.images.omiGlass.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: DeviceType.omi, deviceName: 'NEO'),
          Assets.images.neoOne.path);
    });

    test('falls back to modelNumber when deviceType is null', () {
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: null, modelNumber: 'PLAUD'),
          Assets.images.plaudNotePin.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: null, modelNumber: 'FRIEND PENDANT'),
          Assets.images.friendPendant.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: null, modelNumber: 'GLASS'),
          Assets.images.omiGlass.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: null, modelNumber: 'BEE'),
          Assets.images.beeDevice.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: null, modelNumber: 'WATCH'),
          Assets.images.appleWatch.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: null, modelNumber: 'FIELDY'),
          Assets.images.fieldy.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: null, modelNumber: 'NEO'),
          Assets.images.neoOne.path);
    });

    test('falls back to deviceName when deviceType and modelNumber are null', () {
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: null, modelNumber: null, deviceName: 'PLAUD'),
          Assets.images.plaudNotePin.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: null, modelNumber: null, deviceName: 'GLASS'),
          Assets.images.omiGlass.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: null, modelNumber: null, deviceName: 'FRIEND_123'),
          Assets.images.friendPendant.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: null, modelNumber: null, deviceName: 'BEE'),
          Assets.images.beeDevice.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: null, modelNumber: null, deviceName: 'WATCH'),
          Assets.images.appleWatch.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: null, modelNumber: null, deviceName: 'FIELDY'),
          Assets.images.fieldy.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: null, modelNumber: null, deviceName: 'NEO'),
          Assets.images.neoOne.path);
      expect(
          DeviceUtils.getDeviceImagePath(deviceType: null, modelNumber: null, deviceName: 'UNKNOWN_DEVICE'),
          Assets.images.omiWithoutRope.path); // default
    });
  });

  group('DeviceUtils.getDeviceImageFromBtDevice', () {
    test('uses BtDevice properties correctly', () {
      final device = BtDevice(
        id: 'test_id',
        name: 'GLASS',
        type: DeviceType.omi,
        rssi: -50,
      );
      expect(DeviceUtils.getDeviceImageFromBtDevice(device), Assets.images.omiGlass.path);
    });
  });

  group('DeviceUtils.getDeviceImagePathWithState', () {
    test('returns turned off image for omi when disconnected', () {
      expect(
          DeviceUtils.getDeviceImagePathWithState(
            deviceType: DeviceType.omi,
            isConnected: false,
          ),
          Assets.images.omiWithoutRopeTurnedOff.path);
    });

    test('returns friendPendant for friendPendant when disconnected', () {
      expect(
          DeviceUtils.getDeviceImagePathWithState(
            deviceType: DeviceType.friendPendant,
            isConnected: false,
          ),
          Assets.images.friendPendant.path);
    });

    test('delegates to getDeviceImagePath when connected', () {
      expect(
          DeviceUtils.getDeviceImagePathWithState(
            deviceType: DeviceType.omi,
            deviceName: 'GLASS',
            isConnected: true,
          ),
          Assets.images.omiGlass.path);
    });
  });

  group('DeviceUtils.getDeviceImagePathByModel', () {
    test('delegates to getDeviceImagePath with deviceName', () {
      expect(DeviceUtils.getDeviceImagePathByModel('GLASS'), Assets.images.omiGlass.path);
    });
  });
}
