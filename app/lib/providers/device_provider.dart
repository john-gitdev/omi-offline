import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/devices/device_crash_log.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/wals.dart';
import 'package:omi/utils/audio/foreground.dart';
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/other/debouncer.dart';
import 'package:omi/utils/platform/platform_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class DeviceProvider extends ChangeNotifier
    with WidgetsBindingObserver
    implements IDeviceServiceSubscription, IWalServiceListener {
  bool _disposed = false;
  bool isConnecting = false;
  bool isConnected = false;
  bool isBluetoothEnabled = true;
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
  Timer? _resumeReconnectDebounce;
  DateTime? _reconnectAt;
  final int _connectionCheckSeconds = 15; // Scan every 15s instead of 30s

  Timer? _backgroundSyncTimer;
  DateTime? nextSyncTime;
  bool _pendingAppOpenSync = false;
  bool _pendingBackgroundSync = false;
  // Guards against overlapping _doBackgroundSync runs. The wakelock is a global
  // boolean (not ref-counted), so two interleaved runs would let the first to
  // finish disable it while the second is still syncing in the background.
  bool _backgroundSyncActive = false;

  Timer? _reconnectDelayTimer;
  Timer? _disconnectNotificationTimer;
  // Foreground keep-alive: sends HEARTBEAT (0x32) to storage characteristic
  // every 20s so the firmware (oo-1.9.0+) doesn't trip its 30s idle-disconnect
  // while the user is actively in the app. Stops in background — background
  // sync is driven by the periodic timer, and the firmware disconnect there
  // saves Omi battery.
  Timer? _foregroundKeepAliveTimer;
  final Debouncer _disconnectDebouncer = Debouncer(delay: const Duration(milliseconds: 500));
  final Debouncer _connectDebouncer = Debouncer(delay: const Duration(milliseconds: 1000));
  bool _isHandlingDisconnect = false;
  int _consecutiveAccidentalDisconnects = 0;

  bool _manualRecording = false;
  bool get manualRecording => _manualRecording;

  String? lastSyncError;
  DateTime? lastSyncErrorTime;

  // Crash logs collected each time the device connects (newest first, capped at 50)
  final List<DeviceCrashLog> crashLogs = [];
  static const _crashLogsKey = 'deviceCrashLogs';

  void _loadCrashLogs() {
    try {
      final raw = SharedPreferencesUtil().getString(_crashLogsKey);
      if (raw.isEmpty) return;
      final list = jsonDecode(raw) as List<dynamic>;
      crashLogs
        ..clear()
        ..addAll(list.map((e) => DeviceCrashLog.fromJson(e as Map<String, dynamic>)));
    } catch (e) {
      Logger.debug('DeviceProvider: failed to load crash logs: $e');
    }
  }

  Future<void> _saveCrashLogs() async {
    try {
      await SharedPreferencesUtil().saveString(_crashLogsKey, jsonEncode(crashLogs.map((e) => e.toJson()).toList()));
    } catch (e) {
      Logger.debug('DeviceProvider: failed to save crash logs: $e');
    }
  }

  Future<void> clearCrashLogs() async {
    crashLogs.clear();
    await _saveCrashLogs();
    notifyListeners();
  }

  void Function(BtDevice device)? onDeviceConnected;

  DeviceProvider() {
    WidgetsBinding.instance.addObserver(this);
    // Correctly initialize foreground state for cases where app starts in background.
    final state = WidgetsBinding.instance.lifecycleState;
    _isAppInForeground = state == null || state == AppLifecycleState.resumed;

    // Seed from last known value so battery indicator isn't grey on launch.
    final saved = SharedPreferencesUtil().lastBatteryLevel;
    if (saved >= 0) batteryLevel = saved;
    _loadCrashLogs();
    ServiceManager.instance().device.subscribe(this, this);
    ServiceManager.instance().wal.subscribe(this, this);
    FlutterForegroundTask.addTaskDataCallback(_onForegroundTaskData);
    BleBridge.instance.bluetoothStateChangedCallback = (state) {
      Logger.debug('Bluetooth state changed: $state');
      if (state == 'on') {
        isBluetoothEnabled = true;
        notifyListeners();
        // Don't auto-reconnect on BT-toggle if maximize-battery is on and the
        // app is backgrounded — that mode wants the device disconnected
        // between scheduled syncs.
        if (!isConnected &&
            SharedPreferencesUtil().btDevice.id.isNotEmpty &&
            !isConnecting &&
            (!SharedPreferencesUtil().maximizeBattery || _isAppInForeground)) {
          scanAndConnectToDevice();
        }
      } else if (state == 'off') {
        isBluetoothEnabled = false;
        notifyListeners();
        if (isConnected || isConnecting) {
          onDeviceDisconnected();
        }
      }
    };
    if (SharedPreferencesUtil().btDevice.id.isNotEmpty) {
      Future.microtask(() => periodicConnect('app open', boundDeviceOnly: true));
      if (!SharedPreferencesUtil().maximizeBattery && _shouldSyncNow()) {
        _pendingAppOpenSync = true;
      }
    }
    _startBackgroundSyncTimer();
  }

  void _onForegroundTaskData(Object data) {
    if (data == 'heartbeat') {
      Logger.debug('DeviceProvider: Heartbeat received from foreground task');
      if (!_isAppInForeground) {
        // Use heartbeat to trigger reconnection if disconnected. Skip when
        // maximize-battery is on — that mode wants the device disconnected
        // between scheduled syncs; the sync-if-due branch below still
        // reconnects when a sync is actually due.
        if (!isConnected &&
            !isConnecting &&
            SharedPreferencesUtil().btDevice.id.isNotEmpty &&
            !SharedPreferencesUtil().maximizeBattery) {
          Logger.debug('DeviceProvider: Heartbeat triggering reconnection scan');
          scanAndConnectToDevice();
        }

        // Use heartbeat to trigger sync if due
        final next = nextSyncTime;
        if (next != null && DateTime.now().isAfter(next)) {
          Logger.debug('DeviceProvider: Heartbeat triggering background sync');
          if (isConnected) {
            _doBackgroundSync();
          } else {
            _pendingBackgroundSync = true;
            scanAndConnectToDevice();
          }
          // Reset next sync time
          final interval = SharedPreferencesUtil().backgroundSyncIntervalMinutes;
          if (interval > 0) {
            nextSyncTime = DateTime.now().add(Duration(minutes: interval));
            notifyListeners();
          }
        }
      }
    }
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

  Future<void> _setDeviceVadThreshold(int threshold) async {
    final dev = connectedDevice;
    if (dev == null) return;
    final connection = await ServiceManager.instance().device.ensureConnection(dev.id);
    await connection?.setVadThreshold(threshold);
  }

  Future<void> setManualMode(bool enabled) async {
    if (connectedDevice == null) return;
    final prefs = SharedPreferencesUtil();
    prefs.manualMode = enabled;
    _manualRecording = false;
    if (enabled) {
      await _setDeviceVadThreshold(32769);
    } else {
      await _setDeviceVadThreshold(prefs.autoVadThreshold);
    }
    notifyListeners();
  }

  initiateBleButtonListener() async {
    if (connectedDevice == null) return;
    _bleButtonListener?.cancel();
    _bleButtonListener = await _getBleButtonListener(
      connectedDevice?.id ?? '',
      onButtonReceived: (List<int> value) async {
        try {
          if (value.isEmpty) return;
          int event = value[0];
          Logger.debug('DeviceProvider: Button event $event');
          if (event == 2 && SharedPreferencesUtil().manualMode) {
            if (_manualRecording) {
              _manualRecording = false;
              await _setDeviceVadThreshold(32769);
              Logger.debug('DeviceProvider: Manual mode — recording stopped.');
            } else {
              _manualRecording = true;
              await _setDeviceVadThreshold(65535);
              Logger.debug('DeviceProvider: Manual mode — recording started.');
            }
            notifyListeners();
          }
        } catch (e) {
          Logger.error('DeviceProvider: Button handler error: $e');
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
      if (!isBluetoothEnabled) return;
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
    if (!isBluetoothEnabled) return null;
    var device = await _getConnectedDevice();
    if (device != null) return device;
    final pairedDeviceId = SharedPreferencesUtil().btDevice.id;
    if (pairedDeviceId.isNotEmpty) {
      // Fast path: direct connect-by-MAC. On OnePlus and similar OEMs where the
      // device is still system-cached, native OmiBleManager.connectGatt picks
      // autoConnect=false and reattaches in <1s. Even when not cached, a direct
      // connectGatt(autoConnect=false) to a known MAC is faster than a 10s scan.
      try {
        await ServiceManager.instance().device
            .ensureConnection(pairedDeviceId, force: true)
            .timeout(const Duration(seconds: 10));
        await Future.delayed(const Duration(seconds: 1));
        device = await _getConnectedDevice();
        if (device != null) return device;
      } catch (_) {}
    }
    // Fallback: full scan when direct connect failed (device out of range,
    // bond lost, or MAC changed).
    await ServiceManager.instance().device.discover(desirableDeviceId: pairedDeviceId, timeout: 10);
    await Future.delayed(const Duration(seconds: 2));
    return connectedDevice;
  }

  Future scanAndConnectToDevice() async {
    if (!isBluetoothEnabled) return;
    if (isFirmwareUpdateInProgress) return;
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
    if (!_isAppInForeground) {
      if (isConnecting && !isConnected) {
        ForegroundUtil.updateNotification(
          title: 'Scanning for Omi device...',
          text: 'Looking for nearby device...',
        );
      } else if (!isConnecting) {
        ForegroundUtil.updateNotification(
          title: 'Omi is active',
          text: isConnected ? 'Connected to device' : 'Running in the background',
        );
      }
    }
    notifyListeners();
  }

  void setIsConnected(bool value) {
    isConnected = value;
    if (isConnected) _reconnectionTimer?.cancel();
    notifyListeners();
  }

  void _startForegroundKeepAlive() {
    _foregroundKeepAliveTimer?.cancel();
    if (!_isAppInForeground || !isConnected || connectedDevice == null) return;
    _foregroundKeepAliveTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      if (!isConnected || connectedDevice == null) return;
      final conn = await ServiceManager.instance().device.ensureConnection(connectedDevice!.id);
      await conn?.sendKeepAlive();
    });
  }

  void _stopForegroundKeepAlive() {
    _foregroundKeepAliveTimer?.cancel();
    _foregroundKeepAliveTimer = null;
  }

  void restartBackgroundSyncTimer() => _startBackgroundSyncTimer();

  void _startBackgroundSyncTimer() {
    _backgroundSyncTimer?.cancel();
    final interval = SharedPreferencesUtil().backgroundSyncIntervalMinutes;
    if (interval <= 0) {
      nextSyncTime = null;
      notifyListeners();
      return; // Manual only
    }
    nextSyncTime = DateTime.now().add(Duration(minutes: interval));
    notifyListeners();

    _backgroundSyncTimer = Timer.periodic(Duration(minutes: interval), (_) async {
      if (_disposed) return;
      nextSyncTime = DateTime.now().add(Duration(minutes: interval));
      notifyListeners();

      if (!isConnected) {
        if (!isConnecting) {
          // Set the flag BEFORE the scan so _handleDeviceConnected's
          // maximize-battery+background guard knows this connection is a
          // sanctioned background sync and shouldn't be dropped.
          _pendingBackgroundSync = true;
          bool connectedThisTick = false;
          try {
            for (int attempt = 0; attempt < 3 && !isConnected; attempt++) {
              if (attempt > 0) await Future.delayed(const Duration(seconds: 10));
              await scanAndConnectToDevice();
              if (isConnected) {
                connectedThisTick = true;
                break;
              }
            }
          } finally {
            // Clear in finally so a thrown scan (TimeoutException, GATT
            // errors, permission failure) doesn't leave the flag stuck true
            // and bypass the drop guard for future connections.
            if (!connectedThisTick) {
              _pendingBackgroundSync = false;
            }
          }
          // If connectedThisTick, _finishDeviceSetup will clear the flag and
          // kick off _doBackgroundSync.
        }
      } else {
        _doBackgroundSync();
      }
    });
  }

  Future<void> _doBackgroundSync() async {
    if (isFirmwareUpdateInProgress) return;
    // Re-entrancy guard: set before any await so a second caller (e.g. the Dart
    // timer firing alongside the foreground heartbeat) bails out before touching
    // the shared wakelock. Cleared in the outer finally.
    if (_backgroundSyncActive) return;
    _backgroundSyncActive = true;
    try {
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

      void onProcessingProgress() {
        if (!_isAppInForeground && RecordingsManager.isProcessingAny) {
          final progress = RecordingsManager.processingProgress.value;
          ForegroundUtil.updateNotification(
            title: 'Processing recordings...',
            text: progress < 1.0 ? '${(progress * 100).toInt()}% complete...' : 'Finishing processing...',
          );
        }
      }

      try {
        WakelockPlus.enable();
        if (!await ForegroundUtil.isRunningService) {
          await ForegroundUtil.startForegroundTask(
            title: 'Syncing recordings...',
            text: 'Preparing to sync segments...',
          );
        } else {
          await ForegroundUtil.updateNotification(
            title: 'Syncing recordings...',
            text: 'Preparing to sync segments...',
          );
        }
        await walSync.syncAll(progress: _BackgroundSyncProgress());

        await ForegroundUtil.updateNotification(
          title: 'Processing recordings...',
          text: 'Preparing to process segments...',
        );
        RecordingsManager.processingProgress.addListener(onProcessingProgress);
        await RecordingsManager.processAllCompletedSessions();
        RecordingsManager.processingProgress.removeListener(onProcessingProgress);

        await ForegroundUtil.updateNotification(
          title: 'Syncing recordings...',
          text: 'Finalizing sync...',
        );
        await walSync.syncAll(progress: _BackgroundSyncProgress());
        SharedPreferencesUtil().lastSyncCompletedMs = DateTime.now().millisecondsSinceEpoch;
      } catch (e) {
        lastSyncError = e.toString();
        lastSyncErrorTime = DateTime.now();
        notifyListeners();
      } finally {
        WakelockPlus.disable();
        RecordingsManager.processingProgress.removeListener(onProcessingProgress);
        // Only release the foreground service (and wake lock) when the app is
        // visible. In background we keep it alive so the next timer tick fires.
        if (_isAppInForeground) {
          await ForegroundUtil.stopForegroundTask();
        } else {
          ForegroundUtil.updateNotification(
            title: isConnected ? 'Omi connected' : 'Omi is active',
            text: isConnected ? 'Connected to device' : 'Running in the background',
          );
        }

        // Disconnect after the full sync+process cycle (both syncAll calls) so
        // that new firmware files created during processing are also captured
        // before we drop the connection.
        if (!_isAppInForeground &&
            SharedPreferencesUtil().maximizeBattery &&
            !isFirmwareUpdateInProgress &&
            !_isOnFirmwareUpdatePage &&
            isConnected) {
          final missingCount = ServiceManager.instance().wal.getSyncs().estimatedTotalSegments;
          if (missingCount <= 0) {
            Logger.debug(
              'Maximizing battery: disconnecting device after background sync — no segments remaining.',
            );
            ServiceManager.instance().device.disconnectDevice(isManual: true);
          } else {
            Logger.debug(
              'Maximizing battery: keeping connection — $missingCount segments still remaining after sync.',
            );
          }
        }
      }
    } finally {
      _backgroundSyncActive = false;
    }
  }

  void onAppPaused() async {
    if (!_isAppInForeground) return;
    _isAppInForeground = false;
    _stopForegroundKeepAlive();
    _reconnectionTimer?.cancel();
    // If maximize-battery is on, also cancel any pending 1-second reconnect
    // armed by a recent accidental disconnect — otherwise it fires after we
    // transition to background and restarts periodicConnect's scan loop. For
    // !maximize-battery users we keep the timer so an accidental drop right
    // before lock-screen still reconnects quickly in background.
    if (SharedPreferencesUtil().maximizeBattery) {
      _reconnectDelayTimer?.cancel();
    }
    _resumeReconnectDebounce?.cancel();
    // Keep _backgroundSyncTimer running so periodic sync fires overnight.
    // Start the foreground service so Android keeps the process alive with a
    // wake lock — without this the CPU sleeps and the Dart timer never fires.
    final interval = SharedPreferencesUtil().backgroundSyncIntervalMinutes;
    if (interval > 0 && SharedPreferencesUtil().btDevice.id.isNotEmpty) {
      if (!await ForegroundUtil.isRunningService) {
        await ForegroundUtil.startForegroundTask();
      }
    }
    if (SharedPreferencesUtil().maximizeBattery && !isFirmwareUpdateInProgress && !_isOnFirmwareUpdatePage) {
      final walSync = ServiceManager.instance().wal.getSyncs();
      if (!walSync.isSyncing) {
        Logger.debug('Maximizing battery: disconnecting device because app is paused.');
        ServiceManager.instance().device.disconnectDevice(isManual: true);
      }
    }
  }

  bool _shouldSyncNow() {
    final lastMs = SharedPreferencesUtil().lastSyncCompletedMs;
    if (lastMs <= 0) return true;
    return DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(lastMs)).inMinutes >= 10;
  }

  void onAppResumed() {
    _isAppInForeground = true;
    if (isConnected) _startForegroundKeepAlive();
    // Release the overnight wake lock now that the user has the app open.
    final walSync = ServiceManager.instance().wal.getSyncs();
    if (!walSync.isSyncing) {
      ForegroundUtil.stopForegroundTask();
    }

    final prefs = SharedPreferencesUtil();
    if (!prefs.maximizeBattery && prefs.btDevice.id.isNotEmpty && _shouldSyncNow()) {
      if (isConnected) {
        unawaited(_doBackgroundSync().then((_) => _startBackgroundSyncTimer()));
      } else {
        _pendingAppOpenSync = true;
        periodicConnect('app resumed', boundDeviceOnly: true);
      }
      return;
    }

    if (isConnected) {
      // Drain pending segments if the background sync left the connection
      // alive because missingCount > 0. Without this the user resumes onto a
      // live connection that just sits idle until the next 30-min tick.
      if (prefs.maximizeBattery && !walSync.isSyncing && walSync.estimatedTotalSegments > 0) {
        unawaited(_doBackgroundSync());
      }
      // Don't reset the timer if it's already ticking — preserves the overnight
      // schedule so briefly unlocking the screen doesn't restart the 30-min clock.
      if (!(_backgroundSyncTimer?.isActive ?? false)) {
        _startBackgroundSyncTimer();
      }
    } else {
      if (prefs.btDevice.id.isNotEmpty) {
        // Debounce the resume-triggered scan. OnePlus (and similar OEMs) can
        // emit transient resumed/paused cycles for system overlays or
        // notification panels — without the debounce, each blip kicks off a
        // 15s scan loop and the in-flight scan can complete (and stick) after
        // the next pause, leaving a stale background connection.
        _resumeReconnectDebounce?.cancel();
        _resumeReconnectDebounce = Timer(const Duration(seconds: 2), () {
          if (_isAppInForeground && !isConnected && !isConnecting) {
            periodicConnect('app resumed', boundDeviceOnly: true);
          }
        });
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
    Logger.debug('Preparing DFU...');
    isFirmwareUpdateInProgress = true;
    _reconnectionTimer?.cancel();
    _reconnectDelayTimer?.cancel();
    _resumeReconnectDebounce?.cancel();
    _backgroundSyncTimer?.cancel();
    _foregroundKeepAliveTimer?.cancel();

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
    _resumeReconnectDebounce?.cancel();
    _backgroundSyncTimer?.cancel();
    _foregroundKeepAliveTimer?.cancel();
    _disconnectDebouncer.cancel();
    _connectDebouncer.cancel();
    ServiceManager.instance().device.unsubscribe(this);
    ServiceManager.instance().wal.unsubscribe(this);
    super.dispose();
  }

  void onDeviceDisconnected({bool isManual = false}) async {
    // In maximize-battery + background mode, cancel any pending reconnect on
    // every disconnect callback. The BLE transport fires two state-change
    // callbacks per manual disconnect (isManual=false from the GATT layer
    // then isManual=true from the dart-side intent) ~10ms apart, and the
    // re-entrancy guard below only lets one fully run. Doing this before the
    // re-entrancy / already-disconnected early-returns ensures the survivor
    // can't leave a stale timer armed regardless of which event wins. Outside
    // maximize-battery+background we leave the timer alone so a single
    // accidental disconnect still reconnects via the body's arming below.
    if (SharedPreferencesUtil().maximizeBattery && !_isAppInForeground) {
      _reconnectDelayTimer?.cancel();
      _reconnectionTimer?.cancel();
      _consecutiveAccidentalDisconnects = 0;
    }
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
    setIsConnected(false);
    updateConnectingStatus(false);
    _stopForegroundKeepAlive();

    final walSync = ServiceManager.instance().wal.getSyncs();
    walSync.cancelSync();
    walSync.setDevice(null);

    PlatformManager.instance.crashReporter.logInfo('Omi Device Disconnected (isManual: $isManual)');
    _disconnectNotificationTimer?.cancel();
    _isHandlingDisconnect = false;

    _reconnectDelayTimer?.cancel();
    // When maximize-battery is on and the app is backgrounded, never auto-
    // reconnect — sync is driven by the background timer / heartbeat. Don't
    // gate on `isManual`: the GATT layer's disconnect callback arrives as
    // isManual=false even when WE initiated the disconnect, and may be the
    // call that reaches this branch instead of the isManual=true one.
    if (SharedPreferencesUtil().maximizeBattery && !_isAppInForeground) {
      _consecutiveAccidentalDisconnects = 0;
      return;
    }

    if (!isManual) {
      _consecutiveAccidentalDisconnects++;
    } else {
      _consecutiveAccidentalDisconnects = 0;
    }

    final delaySeconds = isManual ? 1 : (1 << (_consecutiveAccidentalDisconnects - 1)).clamp(1, 60);
    Logger.debug(
      'DeviceProvider: reconnecting in $delaySeconds seconds (consecutiveFailures: $_consecutiveAccidentalDisconnects)',
    );

    _reconnectDelayTimer = Timer(Duration(seconds: delaySeconds), () {
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
  void onSyncFinished() {}

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
      _startForegroundKeepAlive();

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

    {
      final prefs = SharedPreferencesUtil();
      final conn = await ServiceManager.instance().device.ensureConnection(device.id);
      final thr = await conn?.getVadThreshold();
      if (prefs.manualMode) {
        if (thr == 65535) {
          _manualRecording = true;
        } else if (thr == 32769) {
          _manualRecording = false;
        } else {
          // Device is at an auto-mode threshold — push manual standby.
          _manualRecording = false;
          await _setDeviceVadThreshold(32769);
        }
      } else {
        _manualRecording = false;
        // App is in auto mode; if firmware is in a manual state (e.g. after
        // an OTA wiped settings_storage and the new firmware defaults to
        // 32769), push the user's saved auto threshold.
        if (thr == 32769 || thr == 65535) {
          await _setDeviceVadThreshold(prefs.autoVadThreshold);
        }
      }
    }

    await ServiceManager.instance().wal.getSyncs().setDevice(device, prefetchedFiles: []);

    // Timer connected in background and deferred the sync until now so that
    // walSync._device is set before syncAll is called.
    if (_pendingBackgroundSync) {
      _pendingBackgroundSync = false;
      unawaited(_doBackgroundSync());
    }

    await getDeviceInfo();
    SharedPreferencesUtil().deviceName = device.name;

    // Read crash diagnostics and store for Debug Tools display
    final conn = await ServiceManager.instance().device.ensureConnection(device.id);
    if (conn != null) {
      final log = await conn.getDiagnostics();
      if (log != null) {
        // Only add if it's a new event (different device, cause, or uptime)
        bool isDuplicate = crashLogs.isNotEmpty &&
            crashLogs.first.deviceId == log.deviceId &&
            crashLogs.first.resetCause == log.resetCause &&
            crashLogs.first.uptimeSeconds == log.uptimeSeconds;

        if (!isDuplicate) {
          crashLogs.insert(0, log);
          if (crashLogs.length > 50) crashLogs.removeLast();
          await _saveCrashLogs();
          if (log.isCrash) {
            await DebugLogManager.logEvent('device_crash', {
              ...log.toJson(),
              'cause_label': log.causeLabel,
              'uptime_label': log.uptimeStr,
            });
          }
        }
      }
    }

    notifyListeners();
    onDeviceConnected?.call(device);

    if (_pendingAppOpenSync) {
      _pendingAppOpenSync = false;
      unawaited(Future.delayed(const Duration(seconds: 10), () {
        if (!_disposed && isConnected) {
          unawaited(_doBackgroundSync().then((_) => _startBackgroundSyncTimer()));
        }
      }));
    }
  }

  void _handleDeviceConnected(String deviceId) async {
    _consecutiveAccidentalDisconnects = 0;
    try {
      var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
      if (connection == null) return;
      // Defense in depth: if a foreground-initiated scan completed after the
      // user backgrounded the app with maximize-battery on, drop the
      // connection. Background syncs (timer / heartbeat-sync-if-due) set
      // _pendingBackgroundSync first, so they're exempt.
      if (SharedPreferencesUtil().maximizeBattery &&
          !_isAppInForeground &&
          !_pendingBackgroundSync &&
          !isFirmwareUpdateInProgress &&
          !_isOnFirmwareUpdatePage) {
        Logger.debug('Maximizing battery: dropping background-completed connection');
        unawaited(ServiceManager.instance().device.disconnectDevice(isManual: true));
        return;
      }
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
  void onDeviceConnectionStateChanged(String deviceId, DeviceConnectionState state, {bool isManual = false}) {
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
          _disconnectDebouncer.run(() => onDeviceDisconnected(isManual: isManual));
        }
        break;
    }
  }

  @override
  void onDevices(List<BtDevice> devices) async {}

  @override
  void onStatusChanged(DeviceServiceStatus status) {}
}

class _BackgroundSyncProgress implements IWalSyncProgressListener {
  @override
  void onWalSyncedProgress(double percentage, {double? speedKBps, SyncPhase? phase}) {
    ForegroundUtil.updateNotification(
      title: 'Syncing recordings...',
      text: '${(percentage * 100).toInt()}% complete...',
    );
  }
}
