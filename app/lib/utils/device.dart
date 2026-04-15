import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/gen/assets.gen.dart';

class DeviceUtils {
  @visibleForTesting
  static bool? debugDefaultTargetPlatformIsAndroidOverride;

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

  /// Legacy method - kept for backwards compatibility
  @Deprecated('Use getDeviceImagePath with deviceType parameter')
  static String getDeviceImagePathByModel(String? deviceModel) {
    return getDeviceImagePath(deviceName: deviceModel);
  }

  static Future<(String, bool, String)> shouldUpdateFirmware({
    required String currentFirmware,
    required Map latestFirmwareDetails,
  }) async {
    if (latestFirmwareDetails.isEmpty || currentFirmware.isEmpty) {
      return ('Latest Version Not Available', false, '');
    }

    try {
      final latestVersion = latestFirmwareDetails['version']?.toString();
      if (latestVersion == null) {
        return ('Latest Version Not Available', false, '');
      }

      final bool isDraft = latestFirmwareDetails['draft'] ?? false;
      if (isDraft) {
        return ('Latest Version Not Available', false, '');
      }

      final minVersion = latestFirmwareDetails['min_version'];
      if (minVersion != null) {
        final current = currentFirmware.replaceAll('v', '').split('-');
        final currentParts = current[0].split('.');
        final minParts = minVersion.replaceAll('v', '').split('-');
        final minVersionParts = minParts[0].split('.');

        bool isLessThanMin = false;
        for (int i = 0; i < currentParts.length; i++) {
          final currentPart = int.tryParse(currentParts[i]) ?? 0;
          final minPart = int.tryParse(minVersionParts[i]) ?? 0;
          if (currentPart < minPart) {
            isLessThanMin = true;
            break;
          } else if (currentPart > minPart) {
            break;
          }
        }

        if (isLessThanMin) {
          return ('0', false, latestVersion);
        }
      }

      final current = currentFirmware.replaceAll('v', '').split('-');
      final currentParts = current[0].split('.');
      final latest = latestVersion.replaceAll('v', '').split('-');
      final latestParts = latest[0].split('.');

      bool isLatestGreaterThanCurrent = false;
      for (int i = 0; i < currentParts.length; i++) {
        final currentPart = int.tryParse(currentParts[i]) ?? 0;
        final latestPart = int.tryParse(latestParts[i]) ?? 0;

        if (latestPart > currentPart) {
          isLatestGreaterThanCurrent = true;
          break;
        } else if (latestPart < currentPart) {
          break;
        }
      }

      if (!isLatestGreaterThanCurrent) {
        return ('You are already on the latest version', false, latestVersion);
      }

      final minAppVersion = latestFirmwareDetails['min_app_version'];
      if (minAppVersion != null) {
        final minAppVersionCode = int.tryParse(latestFirmwareDetails['min_app_version_code']?.toString() ?? '0') ?? 0;
        final packageInfo = await PackageInfo.fromPlatform();
        final appVersionCode = int.tryParse(packageInfo.buildNumber) ?? 0;

        if (appVersionCode < minAppVersionCode) {
          final isAndroid = debugDefaultTargetPlatformIsAndroidOverride ?? Platform.isAndroid;
          final store = isAndroid ? 'Play Store' : 'App Store';
          return (
            'This firmware is not compatible with this version of App. Please update the app from $store first.',
            false,
            latestVersion
          );
        }
      }

      return ('A new version is available! Update your Omi now.', true, latestVersion);
    } catch (e) {
      return ('Error checking update', false, '');
    }
  }
}
