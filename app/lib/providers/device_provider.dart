import 'dart:async';

import 'package:flutter/material.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/wals.dart';
import 'package:omi/utils/audio/foreground.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/other/debouncer.dart';
import 'package:omi/utils/platform/platform_manager.dart';

class DeviceProvider extends ChangeNotifier
    with WidgetsBindingObserver
    implements IDeviceServiceSubsciption, IWalServiceListener {
  bool _disposed = false;
  bool isConnecting = false;
  bool isConnected = false;
  bool _isAppInForeground = true;
  bool isDeviceStorageSupport = false;
  BtDevice? connectedDevice;
  BtDevice? pairedDevice;
  StreamSubscription<List<int>>? _bleBatteryLevelListener;
  StreamSubscription<List<int>>? _bleButtonListener;
  int batteryLevel = -1;
  bool isCharging = false;
  int storageFullPercentage = -1;
  StorageFileStats? storageStats;
  int _lastNotifiedBatteryLevel = -1;
  DateTime? _lastBatteryNotifyTime;
  bool _hasLowBatteryAlerted = false;

  Timer? _reconnectionTimer;
  DateTime? _reconnectAt;
  final int _connectionCheckSeconds = 30; // Scan every 30s instead of 15s

  Timer? _backgroundSyncTimer;

  Timer? _reconnectDelayTimer;
  Timer? _disconnectNotificationTimer;
  final Debouncer _disconnectDebouncer = Debouncer(delay: const Duration(milliseconds: 500));
  final Debouncer _connectDebouncer = Debouncer(delay: const Duration(milliseconds: 100));
  bool _isHandlingDisconnect = false;

  String? lastSyncError;
  DateTime? lastSyncErrorTime;

  void Function(BtDevice device)? onDeviceConnected;

  DeviceProvider() {
    WidgetsBinding.instance.addObserver(this);
    // Correctly initialize foreground state for cases where app starts in background.
    final state = WidgetsBinding.instance.lifecycleState;
    _isAppInForeground = state == null || state == AppLifecycleState.resumed;

    // Seed from last known value so battery indicator isn't grey on launch.
    final saved = SharedPreferencesUtil().lastBatteryLevel;
    if (saved >= 0) batteryLevel = saved;
    ServiceManager.instance().device.subscribe(this, this);
    ServiceManager.instance().wal.subscribe(this, this);
    BleBridge.instance.bluetoothStateChangedCallback = (state) {
      Logger.debug('Bluetooth state changed: $state');
      if (state == 'on') {
        if (!isConnected && SharedPreferencesUtil().btDevice.id.isNotEmpty && !isConnecting) {
          scanAndConnectToDevice();
        }
      } else if (state == 'off') {
        if (isConnected || isConnecting) {
          onDeviceDisconnected();
        }
      }
    };
    if (SharedPreferencesUtil().btDevice.id.isNotEmpty) {
      Future.microtask(() => periodicConnect('app open', boundDeviceOnly: true));
    }
    _startBackgroundSyncTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden || state == AppLifecycleState.detached) {
      onAppPaused();
    } else if (state == AppLifecycleState.resumed) {
      onAppResumed();
    }
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
      final currentConnectedDevice = connectedDevice;
      if (currentConnectedDevice != null) {
        var connection = await ServiceManager.instance().device.ensureConnection(currentConnectedDevice.id);
        final info = await currentConnectedDevice.getDeviceInfo(connection);
        pairedDevice = info;
        SharedPreferencesUtil().btDevice = info;
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

  Future<int> _retrieveBatteryLevel(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return -1;
    return connection.retrieveBatteryLevel();
  }

  Future<StreamSubscription<List<int>>?> _getBleBatteryLevelListener(
    String deviceId, {
    void Function(int)? onBatteryLevelChange,
    void Function(bool)? onChargingStateChange,
  }) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) return null;
    return connection.getBleBatteryLevelListener(
      onBatteryLevelChange: onBatteryLevelChange,
      onChargingStateChange: onChargingStateChange,
    );
  }

  Future<StreamSubscription<List<int>>?> _getBleButtonListener(
    String deviceId, {
    void Function(List<int>)? onButtonReceived,
  }) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null || onButtonReceived == null) return null;
    return connection.getBleButtonListener(onButtonReceived: onButtonReceived);
  }

  Future updateBatteryLevel() async {
    if (connectedDevice != null) {
      int currentLevel = await _retrieveBatteryLevel(connectedDevice!.id);
      if (currentLevel != -1) {
        batteryLevel = currentLevel;
        SharedPreferencesUtil().lastBatteryLevel = currentLevel;
        notifyListeners();
      }
    }
  }

  Future updateChargingState() async {
    if (connectedDevice == null) return;
    var connection = await ServiceManager.instance().device.ensureConnection(connectedDevice!.id);
    if (connection == null) return;
    final charging = await connection.retrieveChargingState();
    if (isCharging != charging) {
      isCharging = charging;
      notifyListeners();
    }
  }

  Future<BtDevice?> _getConnectedDevice() async {
    var deviceId = SharedPreferencesUtil().btDevice.id;
    if (deviceId.isEmpty) return null;
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    return connection?.device;
  }

  Future<void> initiateBleBatteryListener() async {
    final oldListener = _bleBatteryLevelListener;
    _bleBatteryLevelListener = null;
    await oldListener?.cancel();
    if (connectedDevice == null) return;
    _bleBatteryLevelListener = await _getBleBatteryLevelListener(
      connectedDevice?.id ?? '',
      onBatteryLevelChange: (int value) {
        if (batteryLevel != value) {
          batteryLevel = value;
          SharedPreferencesUtil().lastBatteryLevel = value;
          if (batteryLevel < 20 && !_hasLowBatteryAlerted) {
            _hasLowBatteryAlerted = true;
          } else if (batteryLevel >= 20) {
            _hasLowBatteryAlerted = false;
          }
          _lastNotifiedBatteryLevel = value;
          _lastBatteryNotifyTime = DateTime.now();
          notifyListeners();
        }
      },
      onChargingStateChange: (bool charging) {
        if (isCharging != charging) {
          isCharging = charging;
          notifyListeners();
        }
      },
    );
    notifyListeners();
  }

  initiateBleButtonListener() async {
    if (connectedDevice == null) return;
    _bleButtonListener?.cancel();
    _bleButtonListener = await _getBleButtonListener(
      connectedDevice?.id ?? '',
      onButtonReceived: (List<int> value) {
        if (value.isEmpty) return;
        int event = value[0];
        Logger.debug('DeviceProvider: Button event $event');
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
      final reconnectAt = _reconnectAt;
      if (reconnectAt != null && reconnectAt.isAfter(DateTime.now())) return;
      if (boundDeviceOnly && SharedPreferencesUtil().btDevice.id.isEmpty) {
        t.cancel();
        return;
      }
      if ((!isConnected && connectedDevice == null)) {
        if (isConnecting) return;
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
    if (device != null) return device;
    final pairedDeviceId = SharedPreferencesUtil().btDevice.id;
    if (pairedDeviceId.isNotEmpty) {
      try {
        await ServiceManager.instance().device.ensureConnection(pairedDeviceId, force: true);
        await Future.delayed(const Duration(seconds: 2));
        device = await _getConnectedDevice();
        if (device != null) return device;
      } catch (_) {}
    }
    await ServiceManager.instance().device.discover(desirableDeviceId: pairedDeviceId);
    await Future.delayed(const Duration(seconds: 2));
    return connectedDevice;
  }

  Future scanAndConnectToDevice() async {
    updateConnectingStatus(true);
    try {
      if (isConnected) {
        if (connectedDevice == null) {
          connectedDevice = await _getConnectedDevice();
          if (connectedDevice != null) SharedPreferencesUtil().deviceName = connectedDevice!.name;
        }
        setIsConnected(true);
        return;
      }
      var device = await _scanConnectDevice();
      if (device != null) {
        var cDevice = await _getConnectedDevice();
        if (cDevice != null) {
          SharedPreferencesUtil().deviceName = cDevice.name;
          setIsConnected(true);
        }
      }
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
    if (isConnected) _reconnectionTimer?.cancel();
    notifyListeners();
  }

  void restartBackgroundSyncTimer() => _startBackgroundSyncTimer();

  void _startBackgroundSyncTimer() {
    _backgroundSyncTimer?.cancel();
    final interval = SharedPreferencesUtil().backgroundSyncIntervalMinutes;
    if (interval <= 0) return; // Manual only
    _backgroundSyncTimer = Timer.periodic(Duration(minutes: interval), (_) async {
      if (_disposed) return;
      if (!isConnected) {
        if (!isConnecting) {
          for (int attempt = 0; attempt < 3 && !isConnected; attempt++) {
            if (attempt > 0) await Future.delayed(const Duration(seconds: 10));
            await scanAndConnectToDevice();
          }
        }
      } else {
        _doBackgroundSync();
      }
    });
  }

  Future<void> _doBackgroundSync() async {
    lastSyncError = null;
    final walSync = ServiceManager.instance().wal.getSyncs();
    if (walSync.isSyncing) {
      final cf = walSync.cancelFuture;
      if (cf != null) {
        await cf;
      } else {
        return;
      }
    }
    if (RecordingsManager.isProcessingAny) return;
    try {
      await ForegroundUtil.startForegroundTask();
      await walSync.syncAll();
      await RecordingsManager.processAllCompletedSessions();
    } catch (e) {
      lastSyncError = e.toString();
      lastSyncErrorTime = DateTime.now();
      notifyListeners();
    } finally {
      // Only release the foreground service (and wake lock) when the app is
      // visible. In background we keep it alive so the next timer tick fires.
      if (_isAppInForeground) {
        await ForegroundUtil.stopForegroundTask();
      }
    }
  }

  void onAppPaused() {
    if (!_isAppInForeground) return;
    _isAppInForeground = false;
    _reconnectionTimer?.cancel();
    // Keep _backgroundSyncTimer running so periodic sync fires overnight.
    // Start the foreground service so Android keeps the process alive with a
    // wake lock — without this the CPU sleeps and the Dart timer never fires.
    final interval = SharedPreferencesUtil().backgroundSyncIntervalMinutes;
    if (interval > 0 && SharedPreferencesUtil().btDevice.id.isNotEmpty) {
      ForegroundUtil.startForegroundTask();
    }
    if (SharedPreferencesUtil().maximizeBattery) {
      final walSync = ServiceManager.instance().wal.getSyncs();
      if (!walSync.isSyncing) {
        Logger.debug('Maximizing battery: disconnecting device because app is paused.');
        ServiceManager.instance().device.disconnectDevice();
      }
    }
  }

  void onAppResumed() {
    _isAppInForeground = true;
    // Release the overnight wake lock now that the user has the app open.
    final walSync = ServiceManager.instance().wal.getSyncs();
    if (!walSync.isSyncing) {
      ForegroundUtil.stopForegroundTask();
    }
    if (isConnected) {
      _startBackgroundSyncTimer();
    } else {
      if (SharedPreferencesUtil().btDevice.id.isNotEmpty) {
        periodicConnect('app resumed', boundDeviceOnly: true);
      }
    }
  }

  bool isFirmwareUpdateInProgress = false;
  bool _isOnFirmwareUpdatePage = false;

  void setOnFirmwareUpdatePage(bool value) {
    _isOnFirmwareUpdatePage = value;
    notifyListeners();
  }

  void setFirmwareUpdateInProgress(bool value) {
    isFirmwareUpdateInProgress = value;
    notifyListeners();
  }

  void resetFirmwareUpdateState() {
    isFirmwareUpdateInProgress = false;
    notifyListeners();
  }

  Future<void> prepareDFU() async {
    // Stub for now. Usually involves stopping syncs and disconnecting to trigger DFU mode.
    Logger.debug('Preparing DFU...');
    final walSync = ServiceManager.instance().wal.getSyncs();
    if (walSync.isSyncing) {
      walSync.cancelSync();
    }
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _bleBatteryLevelListener?.cancel();
    _bleButtonListener?.cancel();
    _reconnectionTimer?.cancel();
    _reconnectDelayTimer?.cancel();
    _backgroundSyncTimer?.cancel();
    _disconnectDebouncer.cancel();
    _connectDebouncer.cancel();
    ServiceManager.instance().device.unsubscribe(this);
    ServiceManager.instance().wal.unsubscribe(this);
    super.dispose();
  }

  void onDeviceDisconnected() async {
    if (_isHandlingDisconnect) return;
    _isHandlingDisconnect = true;
    if (!isConnected && connectedDevice == null) {
      _isHandlingDisconnect = false;
      return;
    }
    storageFullPercentage = -1;
    storageStats = null;
    isCharging = false;
    notifyListeners();
    await setConnectedDevice(null);
    await refreshStorageStats();
    setIsConnected(false);
    updateConnectingStatus(false);

    final walSync = ServiceManager.instance().wal.getSyncs();
    walSync.cancelSync();
    walSync.setDevice(null);

    PlatformManager.instance.crashReporter.logInfo('Omi Device Disconnected');
    _disconnectNotificationTimer?.cancel();
    _isHandlingDisconnect = false;

    _reconnectDelayTimer?.cancel();
    // Skip reconnect when maximize-battery intentionally disconnected while in background.
    if (SharedPreferencesUtil().maximizeBattery && !_isAppInForeground) return;
    _reconnectDelayTimer = Timer(const Duration(seconds: 1), () {
      if (!_disposed) periodicConnect('coming from onDisconnect');
    });
  }

  @override
  void onWalServiceStatusChanged(WalServiceStatus status) {}

  @override
  void onWalUpdated() {}

  @override
  void onWalSynced(Wal wal) {}

  @override
  void onStorageStatsUpdated(StorageFileStats stats) {
    storageStats = stats;
    final usedBytes = stats.totalUsedBytes;
    final totalBytes = usedBytes + stats.freeBytes;
    if (totalBytes > 0) {
      storageFullPercentage = ((usedBytes / totalBytes) * 100).round().clamp(0, 100);
    } else {
      storageFullPercentage = 0;
    }
    isDeviceStorageSupport = stats.fileCount > 0 || stats.totalUsedBytes > 0;
    notifyListeners();
  }

  @override
  void onSyncFinished() {
    if (SharedPreferencesUtil().maximizeBattery && !_isAppInForeground) {
      Logger.debug('Maximizing battery: disconnecting device after sync completion because app is in background.');
      ServiceManager.instance().device.disconnectDevice();
    }
  }

  @override
  void onDeviceRecordingFailed() {}

  String? _currentlySettingUpId;

  void _onDeviceConnected(BtDevice device) async {
    if (_currentlySettingUpId == device.id) return;
    _currentlySettingUpId = device.id;

    try {
      await setConnectedDevice(device);
      setIsConnected(true);
      updateConnectingStatus(false);
      notifyListeners();

      // Perform remaining setup in background
      await _finishDeviceSetup(device);
    } finally {
      _currentlySettingUpId = null;
    }
  }

  Future<void> _finishDeviceSetup(BtDevice device) async {
    if (_disposed || connectedDevice?.id != device.id) return;

    await initiateBleBatteryListener();
    await updateBatteryLevel();
    await updateChargingState();
    await initiateBleButtonListener();

    await ServiceManager.instance().wal.getSyncs().setDevice(device, prefetchedFiles: []);

    await getDeviceInfo();
    SharedPreferencesUtil().deviceName = device.name;

    _doBackgroundSync();
    notifyListeners();
    onDeviceConnected?.call(device);
  }

  void _handleDeviceConnected(String deviceId) async {
    try {
      var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
      if (connection == null) return;
      _onDeviceConnected(connection.device);
    } catch (e) {
      updateConnectingStatus(false);
    }
  }

  Future<void> refreshStorageStats() async {
    final dev = connectedDevice;
    if (dev == null) return;

    final walSync = ServiceManager.instance().wal.getSyncs();
    if (walSync.isSyncing) {
      Logger.debug('DeviceProvider: Sync already in progress, skipping manual storage refresh.');
      return;
    }

    var connection = await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection == null) return;

    await connection.acquireStorageLock('refreshStorageStats');
    try {
      final files = await connection.listFiles();
      final stats = await connection.getStorageFileStats();
      if (stats != null) {
        onStorageStatsUpdated(stats);
      } else {
        isDeviceStorageSupport = files.isNotEmpty;
        if (files.isNotEmpty) {
          final usedBytes = files.fold(0, (sum, f) => sum + f.size);
          const totalBytes = 480 * 1024 * 1024;
          storageFullPercentage = ((usedBytes / totalBytes) * 100).round().clamp(0, 100);
        } else {
          storageFullPercentage = 0;
        }
      }
      // Also update the WAL sync's view of the world
      await walSync.setDevice(dev, prefetchedFiles: files);
    } finally {
      connection.releaseStorageLock();
      notifyListeners();
    }
  }

  @override
  void onDeviceConnectionStateChanged(String deviceId, DeviceConnectionState state) async {
    switch (state) {
      case DeviceConnectionState.connected:
        updateConnectingStatus(false);
        _disconnectDebouncer.cancel();
        _connectDebouncer.run(() => _handleDeviceConnected(deviceId));
        break;
      case DeviceConnectionState.connecting:
        updateConnectingStatus(true);
        break;
      case DeviceConnectionState.disconnected:
        updateConnectingStatus(false);
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
}
