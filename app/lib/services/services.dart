import 'dart:async';

import 'package:omi/services/connectivity_service.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/wals.dart';

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
    await ConnectivityService().init();
  }

  Future<void> start() async {
    _device.start();
    _wal.start();
  }

  Future<void> deinit() async {
    ConnectivityService().dispose();
    await _wal.stop();
    _device.stop();
  }
}
