import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:omi/utils/logger.dart';

class EnvironmentDetector {
  static const _channel = MethodChannel('com.omi/environment');

  @visibleForTesting
  static bool? platformIsIOSForTesting;

  static Future<bool> isTestFlight() async {
    final bool isIOS = platformIsIOSForTesting ?? Platform.isIOS;
    if (!isIOS) return false;
    try {
      final bool result = await _channel.invokeMethod('isTestFlight');
      return result;
    } catch (e) {
      Logger.error('EnvironmentDetector: Failed to check TestFlight: $e');
      return false;
    }
  }
}
