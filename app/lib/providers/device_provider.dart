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
  // Grace window after the app is backgrounded before we drop the BLE link, so
  // a quick app-switch / notification-shade glance doesn't force a reconnect on
  // return. The link survives the window because the keep-alive keeps running
  // throughout (see onAppPaused) — that, not the grace duration, is what
  // prevents a firmware idle-drop, so don't re-add _stopForegroundKeepAlive()
  // at the top of onAppPaused.
  Timer? _pauseDisconnectTimer;
  static const Duration _backgroundDisconnectGrace = Duration(seconds: 30);
  // Keep-alive: sends HEARTBEAT (0x32) to storage characteristic every 20s so
  // the firmware (oo-1.9.0+) doesn't trip its 30s idle-disconnect. Runs while
  // the user is actively in the app, during an active background sync
  // (_backgroundSyncActive) — a single large-file read sends no command for
  // >30s, so without an in-flight keep-alive the firmware drops the link
  // mid-file and that file can never finish syncing ("Stream closed without
  // EOT") — and during the post-background grace window so a quick return
  // doesn't pay a reconnect. Otherwise stops in the background, where the
  // firmware disconnect saves Omi battery and reconnect is driven by the
  // periodic timer. Also acts as a liveness probe: if the write fails twice in
  // a row, the connection has silently died and we force-disconnect to resync
  // state (avoids the "app thinks connected, BLE actually dead" failure mode).
  Timer? _foregroundKeepAliveTimer;
  int _consecutiveKeepAliveFails = 0;
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
        // Only auto-reconnect on BT-toggle while the app is in the foreground.
        // In the background the device is left disconnected between scheduled
        // syncs (the sync timer / heartbeat reconnects when a sync is due).
        if (!isConnected && SharedPreferencesUtil().btDevice.id.isNotEmpty && !isConnecting && _isAppInForeground) {
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
      // Sync on app open whenever one is due. The device is disconnected in the
      // background, so the periodic timer/heartbeat may not have fired; opening
      // the app is the reliable trigger. _isAppInForeground is true here, so the
      // connection survives _handleDeviceConnected's drop-guard long enough to
      // sync.
      if (_shouldSyncNow()) {
        _pendingAppOpenSync = true;
      }
    }
    _startBackgroundSyncTimer();
  }

  void _onForegroundTaskData(Object data) {
    if (data == 'heartbeat') {
      Logger.debug('DeviceProvider: Heartbeat received from foreground task');
      if (!_isAppInForeground) {
        // The device is left disconnected in the background; the sync-if-due
        // branch below is the only thing that reconnects, and only when a sync
        // is actually due.

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
        } else {
          // Not due yet — refresh the countdown subtext on the persistent
          // notification. Skip while a sync/process is running; that flow owns
          // the notification and shows its own progress.
          if (!_syncOwnsNotification) {
            unawaited(_showIdleNotification());
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
        await ServiceManager.instance()
            .device
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
    // Route every background connection-state transition through the one idle
    // notification, which ignores connection state. The device connects only
    // briefly at scheduled-sync time, so without this the transient
    // connect/scan would flip the notification between "Scanning…",
    // "Connected", and the countdown instead of leaving a stable countdown.
    // The foreground never shows this notification (it's stopped on resume),
    // so connecting status surfaces through the widget tree instead.
    if (!_isAppInForeground && !_syncOwnsNotification) {
      unawaited(_showIdleNotification());
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
    if ((!_isAppInForeground && !_backgroundSyncActive) || !isConnected || connectedDevice == null) return;
    _consecutiveKeepAliveFails = 0;
    _foregroundKeepAliveTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      if (!isConnected || connectedDevice == null) return;
      final conn = await ServiceManager.instance().device.ensureConnection(connectedDevice!.id);
      final ok = (conn != null) && (await conn.sendKeepAlive());
      if (ok) {
        _consecutiveKeepAliveFails = 0;
        return;
      }
      _consecutiveKeepAliveFails++;
      if (_consecutiveKeepAliveFails >= 2) {
        Logger.debug('KeepAlive: 2 consecutive failures, force-disconnecting to resync state');
        _consecutiveKeepAliveFails = 0;
        await ServiceManager.instance().device.disconnectDevice(isManual: false);
      }
    });
  }

  void _stopForegroundKeepAlive() {
    _foregroundKeepAliveTimer?.cancel();
    _foregroundKeepAliveTimer = null;
    _consecutiveKeepAliveFails = 0;
  }

  /// True while a sync or processing run owns the foreground notification (it
  /// shows its own live progress). Idle-notification writers must check this
  /// before touching the notification so they don't clobber that progress.
  bool get _syncOwnsNotification =>
      ServiceManager.instance().wal.getSyncs().isSyncing || RecordingsManager.isProcessingAny || _backgroundSyncActive;

  /// The single source of truth for the persistent background notification when
  /// no sync/process is running. It is deliberately **connection-state
  /// independent**: the device stays disconnected in the background and only
  /// connects briefly at scheduled-sync time, so reflecting connection state
  /// here (or writing transient "Scanning…"/"Connected" text) would make the
  /// connection-status and sync-timer writers fight and flicker. Showing only
  /// the next-sync countdown keeps the notification stable.
  ///
  /// The title doubles as the feature name and the subtext counts down to
  /// [nextSyncTime] (refreshed each ~5-min heartbeat). When auto-sync is off
  /// (interval = Manual Only) there is no countdown. Safe to call from the
  /// foreground — [ForegroundUtil.updateNotification] no-ops when the service
  /// isn't running.
  Future<void> _showIdleNotification({bool start = false}) async {
    final next = nextSyncTime;
    final String title;
    final String text;
    if (next == null) {
      title = ForegroundUtil.defaultTitle;
      text = 'Running in the background';
    } else {
      final mins = next.difference(DateTime.now()).inMinutes;
      title = 'Omi Offline Sync Timer';
      text = mins <= 0 ? 'Syncing soon...' : 'Next sync in ~$mins min';
    }
    if (start && !await ForegroundUtil.isRunningService) {
      await ForegroundUtil.startForegroundTask(title: title, text: text);
    } else {
      await ForegroundUtil.updateNotification(title: title, text: text);
    }
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
          // background drop-guard knows this connection is a sanctioned
          // background sync and shouldn't be dropped.
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

      // Update progress in both foreground and background. App-open syncs run
      // through this path too (onAppResumed → _doBackgroundSync), so gating on
      // !_isAppInForeground would freeze the notification at "preparing..." while
      // the user watches with the app open. The RecordingsController pipeline never
      // runs concurrently (guarded above by isProcessingAny / isSyncing), so there
      // is no competing foreground writer to clobber.
      void onProcessingProgress() {
        if (RecordingsManager.isProcessingAny) {
          final progress = RecordingsManager.processingProgress.value;
          ForegroundUtil.updateNotification(
            text: progress < 1.0
                ? 'Processing recordings — ${(progress * 100).toInt()}% complete'
                : 'Processing recordings — finishing...',
          );
        }
      }

      try {
        WakelockPlus.enable();
        // Keep the firmware from idle-dropping the link mid-sync. Without this a
        // single >30s file read (large stitched/draft recordings) sends no
        // command for the firmware's 30s idle window and dies as "Stream closed
        // without EOT", so that file never finishes. _backgroundSyncActive is
        // set, so this also arms the keep-alive in the background. See
        // _startForegroundKeepAlive.
        _startForegroundKeepAlive();
        if (!await ForegroundUtil.isRunningService) {
          await ForegroundUtil.startForegroundTask(text: 'Syncing recordings — preparing...');
        } else {
          await ForegroundUtil.updateNotification(text: 'Syncing recordings — preparing...');
        }
        // A setup-phase failure in this first sync (no connection, storage full,
        // or any early abort that throws) must NOT skip processing — bins that
        // already reached disk should still be decoded, mirroring how the
        // foreground pipeline auto-processes on disconnect. A transfer-phase
        // disconnect doesn't throw (syncAll returns partial and falls through),
        // so this inner catch only covers the early-abort cases.
        bool firstSyncOk = true;
        try {
          await walSync.syncAll(progress: _BackgroundSyncProgress());
        } catch (e) {
          firstSyncOk = false;
          lastSyncError = e.toString();
          lastSyncErrorTime = DateTime.now();
          notifyListeners();
        }

        await ForegroundUtil.updateNotification(text: 'Processing recordings — preparing...');
        RecordingsManager.processingProgress.addListener(onProcessingProgress);
        // processAllCompletedSessions decodes in draft mode (a partial trailing
        // bin stays a draft and its source bin is kept for resume) and swallows
        // its own errors, so it runs whether or not the sync above succeeded.
        await RecordingsManager.processAllCompletedSessions();
        RecordingsManager.processingProgress.removeListener(onProcessingProgress);

        // Finalizing re-sync (captures firmware files created during processing)
        // and the completion stamp only apply to a clean cycle. If the first
        // sync failed or the link dropped, skip both and leave the cycle "due"
        // so the next timer tick / app open retries promptly instead of waiting
        // a full interval — anything left on disk was already processed above.
        if (firstSyncOk && isConnected) {
          await ForegroundUtil.updateNotification(text: 'Syncing recordings — finalizing...');
          await walSync.syncAll(progress: _BackgroundSyncProgress());
          SharedPreferencesUtil().lastSyncCompletedMs = DateTime.now().millisecondsSinceEpoch;
        }
      } catch (e) {
        lastSyncError = e.toString();
        lastSyncErrorTime = DateTime.now();
        notifyListeners();
      } finally {
        WakelockPlus.disable();
        // The keep-alive only covers the sync itself in the background; in the
        // foreground the connect/resume keep-alive owns it, so leave it running.
        if (!_isAppInForeground) _stopForegroundKeepAlive();
        RecordingsManager.processingProgress.removeListener(onProcessingProgress);
        // Only release the foreground service (and wake lock) when the app is
        // visible. In background we keep it alive so the next timer tick fires.
        if (_isAppInForeground) {
          await ForegroundUtil.stopForegroundTask();
        } else {
          unawaited(_showIdleNotification());
        }

        // Disconnect after the full sync+process cycle (both syncAll calls) so
        // that new firmware files created during processing are also captured
        // before we drop the connection. Always disconnect — even if segments
        // remain there is no point holding the link, because the keep-alive has
        // stopped and the firmware idle-drops it within ~30s with nothing to
        // reconnect it in the background. Any leftover segments are picked up by
        // the next scheduled sync (or on app open/resume when one is due).
        if (!_isAppInForeground && !isFirmwareUpdateInProgress && !_isOnFirmwareUpdatePage && isConnected) {
          Logger.debug('Background sync done: disconnecting device.');
          ServiceManager.instance().device.disconnectDevice(isManual: true);
        }
      }
    } finally {
      _backgroundSyncActive = false;
    }
  }

  void onAppPaused() async {
    if (!_isAppInForeground) return;
    _isAppInForeground = false;
    _reconnectionTimer?.cancel();
    // Cancel any pending 1-second reconnect armed by a recent accidental
    // disconnect — otherwise it fires after we transition to background and
    // restarts periodicConnect's scan loop. The device is meant to stay
    // disconnected in the background until the next scheduled sync.
    _reconnectDelayTimer?.cancel();
    _resumeReconnectDebounce?.cancel();
    // Keep _backgroundSyncTimer running so periodic sync fires overnight.
    // Start the foreground service so Android keeps the process alive with a
    // wake lock — without this the CPU sleeps and the Dart timer never fires.
    final interval = SharedPreferencesUtil().backgroundSyncIntervalMinutes;
    if (interval > 0 && SharedPreferencesUtil().btDevice.id.isNotEmpty) {
      // A running sync/process already owns the foreground notification (and
      // keeps the service alive); don't overwrite its live progress with the
      // idle countdown. Otherwise start/refresh the "next sync" timer.
      if (!_syncOwnsNotification) {
        await _showIdleNotification(start: true);
      }
    }
    // Grace period: don't drop the link the instant we're backgrounded — a
    // quick app-switch / notification-shade glance shouldn't force a reconnect
    // when the user comes right back. Leave the keep-alive running so the
    // firmware doesn't idle-drop the link before the window elapses;
    // onAppResumed cancels this. If a sync is still in flight when it fires it
    // re-arms, so for the start-a-sync-then-background case the grace
    // effectively begins once the sync finishes.
    _armPauseDisconnect();
  }

  /// Arm (or re-arm) the post-background disconnect. A method (not an inline
  /// closure) so the tick can re-arm itself while a sync is still running.
  void _armPauseDisconnect() {
    _pauseDisconnectTimer?.cancel();
    _pauseDisconnectTimer = Timer(_backgroundDisconnectGrace, _onPauseDisconnectTick);
  }

  void _onPauseDisconnectTick() {
    if (_disposed || _isAppInForeground || !isConnected) return;
    if (isFirmwareUpdateInProgress || _isOnFirmwareUpdatePage) return;
    // A sync is actively using the BLE link — keep the connection (and the
    // keep-alive) alive until it finishes, then re-check. This is the
    // start-a-sync-then-background case: keep-alive runs through the sync and
    // the grace effectively starts once it's over. Local decode/VAD processing
    // doesn't hold the link, so it doesn't block the disconnect.
    if (ServiceManager.instance().wal.getSyncs().isSyncing || _backgroundSyncActive) {
      _armPauseDisconnect();
      return;
    }
    _stopForegroundKeepAlive();
    Logger.debug('Background grace elapsed: disconnecting device to save battery.');
    ServiceManager.instance().device.disconnectDevice(isManual: true);
  }

  bool _shouldSyncNow() {
    // One timer governs everything: opening the app syncs only once the auto-sync
    // interval has elapsed since the last sync — the same threshold the background
    // timer uses, not a separate hardcoded window. "Manual Only" (interval <= 0)
    // never auto-syncs on open; the user syncs by hand.
    final interval = SharedPreferencesUtil().backgroundSyncIntervalMinutes;
    if (interval <= 0) return false;
    final lastMs = SharedPreferencesUtil().lastSyncCompletedMs;
    if (lastMs <= 0) return true;
    return DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(lastMs)).inMinutes >= interval;
  }

  void onAppResumed() {
    _isAppInForeground = true;
    // Came back within the grace window — keep the (still-live) connection.
    _pauseDisconnectTimer?.cancel();
    if (isConnected) _startForegroundKeepAlive();
    // Release the overnight wake lock now that the user has the app open.
    final walSync = ServiceManager.instance().wal.getSyncs();
    if (!walSync.isSyncing) {
      ForegroundUtil.stopForegroundTask();
    }

    final prefs = SharedPreferencesUtil();
    // Sync on resume whenever one is due. The device is disconnected while
    // backgrounded and the periodic timer/heartbeat are unreliable under Doze,
    // so resuming the app is the dependable trigger. We're in the foreground
    // now, so the reconnect survives _handleDeviceConnected's background
    // drop-guard and _finishDeviceSetup's _pendingAppOpenSync path fires the
    // sync.
    if (prefs.btDevice.id.isNotEmpty && _shouldSyncNow()) {
      if (isConnected) {
        unawaited(_doBackgroundSync().then((_) => _startBackgroundSyncTimer()));
      } else {
        _pendingAppOpenSync = true;
        periodicConnect('app resumed', boundDeviceOnly: true);
      }
      return;
    }

    if (isConnected) {
      // Defensive: if we somehow resume onto a still-live connection that has
      // pending segments (e.g. a quick background→foreground bounce before the
      // pause-disconnect completed), drain them now instead of leaving the
      // connection idle until the next scheduled tick.
      if (!walSync.isSyncing && walSync.estimatedTotalSegments > 0) {
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
    _pauseDisconnectTimer?.cancel();
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
    _pauseDisconnectTimer?.cancel();
    _backgroundSyncTimer?.cancel();
    _foregroundKeepAliveTimer?.cancel();
    _disconnectDebouncer.cancel();
    _connectDebouncer.cancel();
    ServiceManager.instance().device.unsubscribe(this);
    ServiceManager.instance().wal.unsubscribe(this);
    super.dispose();
  }

  void onDeviceDisconnected({bool isManual = false}) async {
    // In the background, cancel any pending reconnect on every disconnect
    // callback. The BLE transport fires two state-change callbacks per manual
    // disconnect (isManual=false from the GATT layer then isManual=true from
    // the dart-side intent) ~10ms apart, and the re-entrancy guard below only
    // lets one fully run. Doing this before the re-entrancy / already-
    // disconnected early-returns ensures the survivor can't leave a stale timer
    // armed regardless of which event wins. In the foreground we leave the
    // timer alone so a single accidental disconnect still reconnects via the
    // body's arming below.
    if (!_isAppInForeground) {
      _reconnectDelayTimer?.cancel();
      _reconnectionTimer?.cancel();
      _pauseDisconnectTimer?.cancel();
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
    // In the background, never auto-reconnect — sync is driven by the background
    // timer / heartbeat. Don't gate on `isManual`: the GATT layer's disconnect
    // callback arrives as isManual=false even when WE initiated the disconnect,
    // and may be the call that reaches this branch instead of the isManual=true
    // one.
    if (!_isAppInForeground) {
      _consecutiveAccidentalDisconnects = 0;
      return;
    }

    // Manual = the app or user explicitly disconnected (background-pause drop,
    // Unpair from settings, DFU prep, keep-alive liveness force-disconnect).
    // None of those want an immediate reconnect — manual unpair would scan
    // uselessly for the just-removed device. Accidental drops below still get
    // the exponential-backoff reconnect.
    if (isManual) {
      _consecutiveAccidentalDisconnects = 0;
      return;
    }

    _consecutiveAccidentalDisconnects++;
    final delaySeconds = (1 << (_consecutiveAccidentalDisconnects - 1)).clamp(1, 60);
    Logger.debug(
      'DeviceProvider: reconnecting in $delaySeconds seconds (consecutiveFailures: $_consecutiveAccidentalDisconnects)',
    );

    // boundDeviceOnly:true so periodicConnect self-cancels when btDevice.id
    // is empty — closes the unpair race where the GATT layer's isManual=false
    // callback wins over our isManual=true callback (see comment above).
    _reconnectDelayTimer = Timer(Duration(seconds: delaySeconds), () {
      if (!_disposed) periodicConnect('coming from onDisconnect', boundDeviceOnly: true);
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
    // Re-anchor the auto-sync countdown to the moment this sync finished, so a
    // sync at 3:05 with a 30-min interval pushes the next sync to ~3:35 — not to
    // wherever the periodic timer happened to be. The WAL layer forwards this
    // after every syncAll / syncWal / rotateAndSync, so it covers manual syncs
    // (the recordings pipeline + Debug Tools) and background syncs uniformly.
    // _startBackgroundSyncTimer re-reads the interval, so "Manual Only" still
    // clears the countdown. _doBackgroundSync is fire-and-forget from the timer
    // body, so cancelling/recreating the timer here can't re-enter it.
    if (_disposed) return;
    _startBackgroundSyncTimer();
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
      // user backgrounded the app, drop the connection — the device is meant to
      // stay disconnected in the background. Background syncs (timer /
      // heartbeat-sync-if-due) set _pendingBackgroundSync first, so they're
      // exempt.
      if (!_isAppInForeground && !_pendingBackgroundSync && !isFirmwareUpdateInProgress && !_isOnFirmwareUpdatePage) {
        Logger.debug('App backgrounded: dropping background-completed connection');
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
      text: 'Syncing recordings — ${(percentage * 100).toInt()}% complete',
    );
  }
}
