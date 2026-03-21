import 'dart:async';

import 'package:flutter/material.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/services.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/other/debouncer.dart';
import 'package:omi/utils/platform/platform_manager.dart';

class DeviceProvider extends ChangeNotifier implements IDeviceServiceSubsciption {
  bool isConnecting = false;
  bool isConnected = false;
  bool isDeviceStorageSupport = false;
  BtDevice? connectedDevice;
  BtDevice? pairedDevice;
  StreamSubscription<List<int>>? _bleBatteryLevelListener;
  StreamSubscription<List<int>>? _bleButtonListener;
  int batteryLevel = -1;
  int storageFullPercentage = -1;
  int _lastNotifiedBatteryLevel = -1;
  DateTime? _lastBatteryNotifyTime;
  bool _hasLowBatteryAlerted = false;
  Timer? _reconnectionTimer;
  DateTime? _reconnectAt;
  final int _connectionCheckSeconds = 15; // 10s periods, 5s for each scan

  Timer? _backgroundSyncTimer;
  static const int _backgroundSyncMinutes = 30;

  Timer? _healthCheckTimer;
  static const int _healthCheckSeconds = 30;
  int _consecutivePingFailures = 0;
  static const int _maxPingFailures = 2;

  Timer? _disconnectNotificationTimer;
  final Debouncer _disconnectDebouncer = Debouncer(delay: const Duration(milliseconds: 500));
  final Debouncer _connectDebouncer = Debouncer(delay: const Duration(milliseconds: 100));

  void Function(BtDevice device)? onDeviceConnected;

  DeviceProvider() {
    ServiceManager.instance().device.subscribe(this, this);
    if (SharedPreferencesUtil().btDevice.id.isNotEmpty) {
      Future.microtask(() => periodicConnect('app open', boundDeviceOnly: true));
    }
    _startBackgroundSyncTimer();
  }

  Future<void> setConnectedDevice(BtDevice? device) async {
    connectedDevice = device;
    pairedDevice = device;
    await getDeviceInfo();
    Logger.debug('setConnectedDevice: $device');
    notifyListeners();
  }

  Future getDeviceInfo() async {
    if (connectedDevice != null) {
      if (pairedDevice?.firmwareRevision != null && pairedDevice?.firmwareRevision != 'Unknown') {
        return;
      }
      final currentConnectedDevice = connectedDevice;
      if (currentConnectedDevice != null) {
        var connection = await ServiceManager.instance().device.ensureConnection(currentConnectedDevice.id);
        final info = await currentConnectedDevice.getDeviceInfo(connection);
        if (info != null) {
          pairedDevice = info;
          SharedPreferencesUtil().btDevice = info;
        }
      }
    } else {
      if (SharedPreferencesUtil().btDevice.id.isEmpty) {
        pairedDevice = BtDevice.empty();
      } else {
        pairedDevice = SharedPreferencesUtil().btDevice;
      }
    }
    notifyListeners();
  }

  Future _bleDisconnectDevice(BtDevice btDevice) async {
    var connection = await ServiceManager.instance().device.ensureConnection(btDevice.id);
    if (connection == null) {
      return Future.value(null);
    }
    return await connection.disconnect();
  }

  Future<int> _retrieveBatteryLevel(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return -1;
    }
    return connection.retrieveBatteryLevel();
  }

  Future<int> _retrieveStorageFullPercentage(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return -1;
    final files = await connection.getStorageList();
    if (files.isEmpty) return -1;
    const maxStorageBytes = 480 * 1024 * 1024; // 0x1E000000, matches firmware MAX_STORAGE_BYTES
    return ((files[0] / maxStorageBytes) * 100).round().clamp(0, 100);
  }

  Future<StreamSubscription<List<int>>?> _getBleBatteryLevelListener(
    String deviceId, {
    void Function(int)? onBatteryLevelChange,
  }) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return Future.value(null);
    }
    return connection.getBleBatteryLevelListener(onBatteryLevelChange: onBatteryLevelChange);
  }

  Future<StreamSubscription<List<int>>?> _getBleButtonListener(
    String deviceId, {
    void Function(List<int>)? onButtonReceived,
  }) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null || onButtonReceived == null) {
      return Future.value(null);
    }
    return connection.getBleButtonListener(onButtonReceived: onButtonReceived);
  }

  Future<List<int>> _getStorageList(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return [];
    }
    return connection.getStorageList();
  }

  Future updateBatteryLevel() async {
    // Always fetch a fresh reading — the batteryLevel == -1 guard was skipping updates
    // after reconnect and showing a stale value until the BLE notification fired.
    if (connectedDevice != null) {
      int currentLevel = await _retrieveBatteryLevel(connectedDevice!.id);
      if (currentLevel != -1) {
        batteryLevel = currentLevel;
        notifyListeners();
      }
    }
  }

  Future<BtDevice?> _getConnectedDevice() async {
    var deviceId = SharedPreferencesUtil().btDevice.id;
    if (deviceId.isEmpty) {
      return null;
    }
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    return connection?.device;
  }

  initiateBleBatteryListener() async {
    if (connectedDevice == null) {
      return;
    }
    _bleBatteryLevelListener?.cancel();
    _bleBatteryLevelListener = await _getBleBatteryLevelListener(
      connectedDevice?.id ?? '',
      onBatteryLevelChange: (int value) {
        batteryLevel = value;
        if (batteryLevel < 20 && !_hasLowBatteryAlerted) {
          _hasLowBatteryAlerted = true;
          Logger.debug('Low Battery Alert');
        } else if (batteryLevel > 20) {
          // Reset when battery recovers so the alert can fire again if it drops below 20
          _hasLowBatteryAlerted = false;
        }

        final delta = (_lastNotifiedBatteryLevel - value).abs();
        final batteryNotifyTime = _lastBatteryNotifyTime;
        final elapsed =
            batteryNotifyTime == null ? const Duration(minutes: 999) : DateTime.now().difference(batteryNotifyTime);
        final crossedLowBatteryThreshold =
            (value < 20 && _lastNotifiedBatteryLevel >= 20) || (value >= 20 && _lastNotifiedBatteryLevel < 20);
        final shouldNotify =
            _lastNotifiedBatteryLevel == -1 || delta >= 5 || elapsed.inMinutes >= 15 || crossedLowBatteryThreshold;
        if (shouldNotify) {
          _lastNotifiedBatteryLevel = value;
          _lastBatteryNotifyTime = DateTime.now();
          notifyListeners();
        }
      },
    );
    notifyListeners();
  }

  initiateBleButtonListener() async {
    if (connectedDevice == null) {
      return;
    }
    _bleButtonListener?.cancel();
    _bleButtonListener = await _getBleButtonListener(
      connectedDevice?.id ?? '',
      onButtonReceived: (List<int> value) {
        if (value.isEmpty) return;
        int event = value[0];
        if (event == 1) {
          Logger.debug('DeviceProvider: Single Tap detected');
        } else if (event == 2) {
          Logger.debug('DeviceProvider: Double Tap detected');
        } else if (event == 3) {
          Logger.debug('DeviceProvider: Long Tap detected');
        } else if (event == 4) {
          Logger.debug('DeviceProvider: Button Press detected');
        } else if (event == 5) {
          Logger.debug('DeviceProvider: Button Release detected');
        }
      },
    );
    notifyListeners();
  }

  @visibleForTesting
  bool updateBatteryLevelForTesting(int value, {DateTime? now}) {
    batteryLevel = value;
    final currentTime = now ?? DateTime.now();

    final delta = (_lastNotifiedBatteryLevel - value).abs();
    final batteryNotifyTime = _lastBatteryNotifyTime;
    final elapsed =
        batteryNotifyTime == null ? const Duration(minutes: 999) : currentTime.difference(batteryNotifyTime);
    final crossedLowBatteryThreshold =
        (value < 20 && _lastNotifiedBatteryLevel >= 20) || (value >= 20 && _lastNotifiedBatteryLevel < 20);
    final shouldNotify =
        _lastNotifiedBatteryLevel == -1 || delta >= 5 || elapsed.inMinutes >= 15 || crossedLowBatteryThreshold;
    if (shouldNotify) {
      _lastNotifiedBatteryLevel = value;
      _lastBatteryNotifyTime = currentTime;
      notifyListeners();
      return true;
    }
    return false;
  }

  @visibleForTesting
  void resetBatteryThrottlingForTesting() {
    _lastNotifiedBatteryLevel = -1;
    _lastBatteryNotifyTime = null;
  }

  Future periodicConnect(String printer, {bool boundDeviceOnly = false}) async {
    _reconnectionTimer?.cancel();
    scan(t) async {
      Logger.debug("Period connect seconds: $_connectionCheckSeconds, triggered timer at ${DateTime.now()}");

      final deviceService = ServiceManager.instance().device;
      // WiFi sync disabled.
      // if (deviceService is DeviceService && deviceService.isWifiSyncInProgress) {
      //   Logger.debug("Skipping BLE reconnect - WiFi sync in progress");
      //   return;
      // }
      final reconnectAt = _reconnectAt;
      if (reconnectAt != null && reconnectAt.isAfter(DateTime.now())) {
        return;
      }
      if (boundDeviceOnly && SharedPreferencesUtil().btDevice.id.isEmpty) {
        t.cancel();
        return;
      }
      Logger.debug("isConnected: $isConnected, isConnecting: $isConnecting, connectedDevice: $connectedDevice");
      if ((!isConnected && connectedDevice == null)) {
        if (isConnecting) {
          return;
        }
        await scanAndConnectToDevice();
      } else {
        t.cancel();
      }
    }

    _reconnectionTimer = Timer.periodic(Duration(seconds: _connectionCheckSeconds), scan);
    scan(_reconnectionTimer);
  }

  Future<BtDevice?> _scanConnectDevice() async {
    var device = await _getConnectedDevice();
    if (device != null) {
      return device;
    }

    final pairedDeviceId = SharedPreferencesUtil().btDevice.id;
    if (pairedDeviceId.isNotEmpty) {
      try {
        Logger.debug('Attempting direct reconnection to paired device: $pairedDeviceId');
        await ServiceManager.instance().device.ensureConnection(pairedDeviceId, force: true);

        await Future.delayed(const Duration(seconds: 2));
        device = await _getConnectedDevice();
        if (device != null) {
          Logger.debug('Direct reconnection successful');
          return device;
        }
      } catch (e) {
        Logger.debug('Direct reconnection failed: $e');
      }
    }

    await ServiceManager.instance().device.discover(desirableDeviceId: pairedDeviceId);

    await Future.delayed(const Duration(seconds: 2));
    if (connectedDevice != null) {
      return connectedDevice;
    }
    return null;
  }

  Future scanAndConnectToDevice() async {
    updateConnectingStatus(true);
    try {
      if (isConnected) {
        if (connectedDevice == null) {
          connectedDevice = await _getConnectedDevice();
          if (connectedDevice != null) {
            SharedPreferencesUtil().deviceName = connectedDevice!.name;
          }
        }

        setIsConnected(true);
        notifyListeners();
        return;
      }

      var device = await _scanConnectDevice();
      Logger.debug('inside scanAndConnectToDevice $device in device_provider');
      if (device != null) {
        var cDevice = await _getConnectedDevice();
        if (cDevice != null) {
          setConnectedDevice(cDevice);
          setisDeviceStorageSupport();
          SharedPreferencesUtil().deviceName = cDevice.name;
          setIsConnected(true);
        }
        Logger.debug('device is not null $cDevice');
      }

      notifyListeners();
    } finally {
      updateConnectingStatus(false);
    }
  }

  void updateConnectingStatus(bool value) {
    isConnecting = value;
    notifyListeners();
  }

  void setIsConnected(bool value) {
    isConnected = value;
    if (isConnected) {
      _reconnectionTimer?.cancel();
    }
    notifyListeners();
  }

  void _startHealthCheck() {
    _healthCheckTimer?.cancel();
    _consecutivePingFailures = 0;
    _healthCheckTimer = Timer.periodic(Duration(seconds: _healthCheckSeconds), (_) => _performHealthCheck());
  }

  void _stopHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
    _consecutivePingFailures = 0;
  }

  Future<void> _performHealthCheck() async {
    if (!isConnected || connectedDevice == null) {
      _stopHealthCheck();
      return;
    }

    final deviceService = ServiceManager.instance().device;
    if (deviceService is! DeviceService) return;

    final alive = await deviceService.ping();
    if (alive) {
      _consecutivePingFailures = 0;
      return;
    }

    _consecutivePingFailures++;
    Logger.debug('DeviceProvider: Health check ping failed ($_consecutivePingFailures/$_maxPingFailures)');

    if (_consecutivePingFailures >= _maxPingFailures) {
      Logger.debug('DeviceProvider: Device unreachable — forcing disconnect');
      _stopHealthCheck();
      await deviceService.disconnectDevice();
    }
  }

  void _startBackgroundSyncTimer() {
    _backgroundSyncTimer?.cancel();
    _backgroundSyncTimer = Timer.periodic(const Duration(minutes: _backgroundSyncMinutes), (_) async {
      if (!isConnected) {
        if (!isConnecting) {
          for (int attempt = 0; attempt < 3 && !isConnected; attempt++) {
            if (attempt > 0) await Future.delayed(const Duration(seconds: 10));
            Logger.debug('DeviceProvider: Background sync connect attempt ${attempt + 1}/3');
            await scanAndConnectToDevice();
          }
        }
        // sync triggers in _onDeviceConnected if connection succeeds
      } else {
        _doBackgroundSync();
      }
    });
  }

  Future<void> _doBackgroundSync() async {
    if (!SharedPreferencesUtil().autoSyncEnabled) return;
    final walSync = ServiceManager.instance().wal.getSyncs();
    if (walSync.isSyncing) return;
    if (RecordingsManager.isProcessingAny) return;
    try {
      await walSync.syncAll();
      await RecordingsManager.processAllCompletedSessions();
    } catch (e) {
      Logger.debug('Background sync failed: $e');
    }
  }

  @override
  void dispose() {
    _bleBatteryLevelListener?.cancel();
    _bleButtonListener?.cancel();
    _reconnectionTimer?.cancel();
    _backgroundSyncTimer?.cancel();
    _healthCheckTimer?.cancel();
    _disconnectDebouncer.cancel();
    _connectDebouncer.cancel();
    ServiceManager.instance().device.unsubscribe(this);
    super.dispose();
  }

  void onDeviceDisconnected() async {
    Logger.debug('onDisconnected inside: $connectedDevice');
    _stopHealthCheck();
    setConnectedDevice(null);
    setisDeviceStorageSupport();
    setIsConnected(false);
    updateConnectingStatus(false);

    // Wals
    final walSync = ServiceManager.instance().wal.getSyncs();
    walSync.cancelSync();
    walSync.setDevice(null);

    PlatformManager.instance.crashReporter.logInfo('Omi Device Disconnected');
    _disconnectNotificationTimer?.cancel();
    _disconnectNotificationTimer = Timer(const Duration(seconds: 30), () {
      Logger.debug('Device Disconnected Notification would happen here in full app');
    });

    Future.delayed(const Duration(seconds: 1), () {
      periodicConnect('coming from onDisconnect');
    });
  }

  void _onDeviceConnected(BtDevice device) async {
    Logger.debug('_onConnected inside: $connectedDevice');
    _disconnectNotificationTimer?.cancel();

    // Await these — both call ensureConnection() internally. Fire-and-forget
    // here means they race against the sequential awaits below, each spawning
    // their own BleTransport and calling discoverServices() concurrently.
    await setConnectedDevice(device);
    await setisDeviceStorageSupport();
    setIsConnected(true);

    int currentLevel = await _retrieveBatteryLevel(device.id);
    if (currentLevel != -1) {
      batteryLevel = currentLevel;
    }

    int currentStorage = await _retrieveStorageFullPercentage(device.id);
    if (currentStorage != -1) {
      storageFullPercentage = currentStorage;
    }

    await initiateBleBatteryListener();
    await initiateBleButtonListener();
    if (batteryLevel != -1 && batteryLevel < 20) {
      _hasLowBatteryAlerted = false;
    }
    updateConnectingStatus(false);

    // getDeviceInfo() already ran inside setConnectedDevice(); this is a no-op
    // if firmware revision was fetched successfully (early-exit guard inside it).
    await getDeviceInfo();
    SharedPreferencesUtil().deviceName = device.name;

    // Start periodic health check to detect stale connections
    _startHealthCheck();

    // Wals
    ServiceManager.instance().wal.getSyncs().setDevice(device);
    _doBackgroundSync(); // fire-and-forget

    notifyListeners();
    onDeviceConnected?.call(device);
  }

  void _handleDeviceConnected(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return;
    }
    _onDeviceConnected(connection.device);
  }

  Future setisDeviceStorageSupport() async {
    final dev = connectedDevice;
    if (dev == null) {
      isDeviceStorageSupport = false;
    } else {
      var storageFiles = await _getStorageList(dev.id);
      isDeviceStorageSupport = storageFiles.isNotEmpty;
    }
    notifyListeners();
  }

  @override
  void onDeviceConnectionStateChanged(String deviceId, DeviceConnectionState state) async {
    Logger.debug("provider > device connection state changed...$deviceId...$state...${connectedDevice?.id}");
    switch (state) {
      case DeviceConnectionState.connected:
        _disconnectDebouncer.cancel();
        _connectDebouncer.run(() => _handleDeviceConnected(deviceId));
        break;
      case DeviceConnectionState.disconnected:
        _connectDebouncer.cancel();
        if (deviceId == connectedDevice?.id || deviceId == pairedDevice?.id) {
          _disconnectDebouncer.run(onDeviceDisconnected);
        }
        break;
    }
  }

  @override
  void onDevices(List<BtDevice> devices) async {}

  @override
  void onStatusChanged(DeviceServiceStatus status) {}

  prepareDFU() {
    final dev = connectedDevice;
    if (dev == null) {
      return;
    }
    _bleDisconnectDevice(dev);
    _reconnectAt = DateTime.now().add(const Duration(seconds: 30));
  }
}
