import 'dart:async';

import 'package:omi/backend/preferences.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/omi_api_client.dart';
import 'package:omi/services/wals.dart';
import 'package:omi/utils/logger.dart';

class ServiceManager {
  late IDeviceService _device;
  late IWalService _wal;

  static ServiceManager? _instance;

  static ServiceManager _create() {
    ServiceManager sm = ServiceManager();
    sm._device = DeviceService();
    sm._wal = WalService();

    return sm;
  }

  static ServiceManager instance() {
    if (_instance == null) {
      throw Exception("Service manager is not initiated");
    }

    return _instance!;
  }

  IDeviceService get device => _device;

  IWalService get wal => _wal;

  static Future<void> init() async {
    if (_instance != null) {
      throw Exception("Service manager is initiated");
    }
    _instance = ServiceManager._create();
  }

  Future<void> start() async {
    _device.start();
    _wal.start();
    if (SharedPreferencesUtil().omiEnabled) {
      OmiApiClient.refreshTokenIfNeeded().catchError((e) {
        Logger.error('ServiceManager: Omi token refresh on startup failed: $e');
      });
    }
  }

  Future<void> deinit() async {
    await _wal.stop();
    _device.stop();
  }
}
