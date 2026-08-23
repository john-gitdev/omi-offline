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

  /// Unreachable today — nothing calls it — and kept deliberately, which is the
  /// stated-reason branch of the dead-code rule in CLAUDE.md rather than an
  /// oversight. It is the app's only teardown path, and `_device.stop()` is
  /// substantive: it stops every discoverer, which is what prevents the scan leak
  /// and battery drain its own comment describes. The day anything tears services
  /// down — sign-out, a service restart, a test harness — this is what it calls.
  ///
  /// Note the asymmetry with [start], which no longer starts the WAL sync: that
  /// half went because it was inert AND redundant (setDevice owns WAL init). This
  /// half is neither — it is real cleanup that is simply not wired up yet.
  Future<void> deinit() async {
    await _wal.stop();
    _device.stop();
  }
}
