import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:version/version.dart';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/gen/assets.gen.dart';

class DeviceUtils {
  static Future<(String, bool, String)> shouldUpdateFirmware({
    required String currentFirmware,
    required Map latestFirmwareDetails,
  }) async {
    Version currentVersion = Version.parse(currentFirmware);
    if (latestFirmwareDetails.isEmpty) {
      return ('Latest Version Not Available', false, '');
    }
    if (latestFirmwareDetails.isEmpty || latestFirmwareDetails['version'] == null) {
      return ('Latest Version Not Available', false, '');
    }
    if (latestFirmwareDetails['version'] == null || latestFirmwareDetails['draft']) {
      return ('Latest Version Not Available', false, '');
    }

    String latestVersionStr = latestFirmwareDetails['version'];
    Version latestVersion = Version.parse(latestVersionStr);
    Version minVersion = Version.parse(latestFirmwareDetails['min_version']);

    if (currentVersion < minVersion) {
      return ('0', false, latestVersionStr);
    } else {
      if (latestVersion > currentVersion) {
        PackageInfo packageInfo = await PackageInfo.fromPlatform();
        if (Version.parse(packageInfo.version) <= Version.parse(latestFirmwareDetails['min_app_version']) &&
            int.parse(packageInfo.buildNumber) < int.parse(latestFirmwareDetails['min_app_version_code'])) {
          return (
            'The latest version of firmware is not compatible with this version of App (${packageInfo.version}+${packageInfo.buildNumber}). Please update the app from ${Platform.isAndroid ? 'Play Store' : 'App Store'}',
            false,
            latestVersionStr
          );
        } else {
          return ('A new version is available! Update your Omi now.', true, latestVersionStr);
        }
      } else {
        return ('You are already on the latest version', false, latestVersionStr);
      }
    }
  }

  /// Get device image path for Omi CV1
  static String getDeviceImagePath({
    DeviceType? deviceType,
    String? modelNumber,
    String? deviceName,
  }) {
    // Strictly focus on Omi CV1
    return Assets.images.omiWithoutRope.path;
  }

  /// Convenience method when you have a BtDevice object
  static String getDeviceImageFromBtDevice(BtDevice device) {
    return getDeviceImagePath(
      deviceType: device.type,
      modelNumber: device.modelNumber,
      deviceName: device.name,
    );
  }

  /// Get device image with connection state
  static String getDeviceImagePathWithState({
    DeviceType? deviceType,
    String? modelNumber,
    String? deviceName,
    required bool isConnected,
  }) {
    if (!isConnected) {
      return Assets.images.omiWithoutRopeTurnedOff.path;
    }
    return getDeviceImagePath();
  }
}
