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
}
