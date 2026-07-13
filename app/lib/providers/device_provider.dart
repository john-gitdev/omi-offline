import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/devices/device_crash_log.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'package:omi/pages/recordings/recordings_controller.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/wals.dart';
import 'package:omi/utils/audio/sync_notification.dart';
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
  bool isMuted = false;
  DateTime? muteSince;
  StreamSubscription<List<int>>? _bleMuteListener;
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
  DateTime? _nextSyncTime;
  DateTime? get nextSyncTime => _nextSyncTime;
  // Mirror into SyncNotification so its self-contained idle() can render the
  // "Next sync at H:MM" title from any caller (e.g. the foreground pipeline)
  // without a DeviceProvider reference.
  set nextSyncTime(DateTime? value) {
    _nextSyncTime = value;
    SyncNotification.nextSyncTime = value;
  }

  bool _pendingAppOpenSync = false;
  bool _pendingBackgroundSync = false;
  // Set when a background disconnect interrupts an active sync. Allows the
  // native BLE auto-reconnect to pass _handleDeviceConnected's drop-guard and
  // fire _doBackgroundSync to finish what was left on the device.
  bool _pendingSyncResume = false;
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
  static const Duration _backgroundDisconnectGrace = Duration(seconds: 15);
  // Background-connect settle watchdog. A scheduled-sync connect attempt paints
  // a "Connecting…" notification and normally settles it back to the idle "Last
  // Sync" line in its finally / _connectThenSyncOrFail when the device is
  // unreachable. Under Doze the process can be frozen mid-attempt, so that
  // settle never runs and the notification is stranded on "Connecting…" until
  // the next scheduled wake (observed: stuck for ~20 min overnight). This timer
  // is the safety net: armed whenever a background connect paints "Connecting…",
  // it forces the notification to the idle line if we're still not connected and
  // no sync owns it. A timer that comes due while the isolate is frozen fires as
  // soon as the isolate thaws, so it also recovers a frozen attempt on the next
  // CPU slice. The window is longer than the timer body's 3-attempt connect loop
  // (~100 s) so a legitimately slow connect isn't cut short.
  //
  // Belt-and-suspenders: the watchdog only recovers *after* a thaw, which under
  // a long Doze can be many minutes away. So for the duration of the attempt we
  // also hold a CPU partial wake-lock (see [_acquireConnectWakeLock]) so the
  // process can't be frozen mid-connect in the first place — then this timer
  // fires on schedule. The wake-lock is the primary fix; the timer is the
  // fallback for when the wake-lock can't hold (battery-optimisation exemption
  // denied) or the process is killed outright.
  Timer? _connectSettleWatchdog;
  static const Duration _connectSettleTimeout = Duration(seconds: 150);
  // Held (Android) while a background connect attempt is outstanding so Doze
  // can't freeze the process mid-connect and strand a "Connecting…" notification
  // — a freeze is exactly what stops the settle watchdog (and
  // _connectThenSyncOrFail's give-up) from ever running. The native lock is
  // reference-counted, so releasing it here never disturbs a concurrent DFU or
  // processing run. This flag keeps the acquire/release pair balanced across the
  // watchdog's several resolution paths (success, give-up, fire, dispose).
  bool _connectWakeLockHeld = false;
  // Keep-alive: sends HEARTBEAT (0x32) to storage characteristic every 5s so
  // the firmware doesn't trip its 15s idle-disconnect (the 5s cadence leaves a
  // 10s margin and survives two missed beats). Runs while the user is actively in
  // the app, during an active background sync
  // (_backgroundSyncActive) — a single large-file read sends no command for
  // >15s, so without an in-flight keep-alive the firmware drops the link
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
    Logger.debug('[BLE] DeviceProvider init: lifecycleState=$state _isAppInForeground=$_isAppInForeground');

    // Seed from last known value so battery indicator isn't grey on launch.
    final saved = SharedPreferencesUtil().lastBatteryLevel;
    if (saved >= 0) batteryLevel = saved;
    _loadCrashLogs();
    ServiceManager.instance().device.subscribe(this, this);
    ServiceManager.instance().wal.subscribe(this, this);
    BleBridge.instance.backgroundSyncRequestedCallback = _onBackgroundSyncRequested;
    BleBridge.instance.stateRestoredCallback = _onStateRestored;
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

  void _onBackgroundSyncRequested() {
    Logger.debug(
        '[BLE] _onBackgroundSyncRequested: OS scheduler fired (fg=$_isAppInForeground connected=$isConnected)');
    if (isConnected) {
      _doBackgroundSync();
    } else {
      _pendingBackgroundSync = true;
      unawaited(SyncNotification.connecting());
      _armConnectSettleWatchdog();
      unawaited(_connectThenSyncOrFail());
    }
  }

  /// iOS CoreBluetooth State Restoration: iOS relaunched the app in the
  /// background because a bound peripheral came back into range, and native's
  /// `willRestoreState` has already re-initiated the connection. We only need to
  /// sanction a background sync so the imminent [_handleDeviceConnected] survives
  /// its background drop-guard and [_finishDeviceSetup] fires [_doBackgroundSync]
  /// — the same path the auto-sync timer uses. Gated on [_shouldSyncNow] so
  /// Manual Only and not-yet-due wakes stay quiet.
  ///
  /// iOS-only by design: Android never emits onStateRestored — it wakes via
  /// WorkManager/exact-alarm regardless of whether the device is in range, and
  /// the user wants that kept as-is.
  void _onStateRestored(List<String> peripheralUuids) {
    if (!Platform.isIOS) return;
    final due = _shouldSyncNow();
    Logger.debug('[BLE] _onStateRestored: ${peripheralUuids.length} peripheral(s) restored, syncDue=$due '
        '(connected=$isConnected)');
    if (!due) return;
    if (isConnected) {
      _doBackgroundSync();
    } else {
      // Native is already reconnecting the restored peripheral. Flag the pending
      // sync now so _handleDeviceConnected lets the background link through.
      _pendingBackgroundSync = true;
    }
  }

  /// Connect for an alarm-triggered background sync. On success,
  /// [_finishDeviceSetup] clears the pending flag and runs [_doBackgroundSync];
  /// on failure, advance to the next slot and settle to idle so the notification
  /// doesn't stick on "Connecting…".
  Future<void> _connectThenSyncOrFail() async {
    try {
      await scanAndConnectToDevice();
    } catch (_) {}
    if (!isConnected) {
      _pendingBackgroundSync = false;
      _failSyncCycleToIdle();
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
        _pushBatteryToNative(currentLevel);
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

  /// Read the device's mute state once (used on connect). The live listener
  /// keeps it current thereafter.
  Future<void> updateMuteState() async {
    if (connectedDevice == null) return;
    var connection = await ServiceManager.instance().device.ensureConnection(connectedDevice!.id);
    if (connection == null) return;
    final state = await connection.getMuteState();
    _applyMuteState(state.muted, state.since);
  }

  /// Subscribe to mute-state notifications (ungated on the firmware side, so it
  /// fires even mid-sync). Initial state comes from [updateMuteState] on connect.
  Future<void> initiateBleMuteListener() async {
    final oldListener = _bleMuteListener;
    _bleMuteListener = null;
    await oldListener?.cancel();
    if (connectedDevice == null) return;
    var connection = await ServiceManager.instance().device.ensureConnection(connectedDevice!.id);
    if (connection == null) return;
    _bleMuteListener = await connection.getMuteListener(
      onMuteChange: (bool muted, DateTime? since) => _applyMuteState(muted, since),
    );
  }

  void _applyMuteState(bool muted, DateTime? since) {
    if (isMuted == muted && muteSince == since) return;
    isMuted = muted;
    muteSince = since;
    // Mirror into the OS notification's resting line.
    SyncNotification.isMuted = muted;
    SyncNotification.muteSince = since;
    unawaited(SyncNotification.idle(isConnected: true));
    notifyListeners();
  }

  /// Toggle mute over BLE (battery-icon tap). The firmware ignores this in
  /// manual mode, so we re-read the device's authoritative state afterward
  /// instead of assuming the write took effect.
  Future<void> setMuted(bool muted) async {
    final dev = connectedDevice;
    if (dev == null) return;
    final connection = await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection == null) return;
    await connection.setMute(muted);
    await updateMuteState();
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
          _pushBatteryToNative(value);
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

  /// Push the button config for the device's current mode to the firmware.
  /// The app owns two per-mode configs; the firmware holds a single active slot,
  /// so the active one must be (re)pushed on connect and whenever the mode flips.
  ///
  /// On first run after upgrading to per-mode configs, the device's existing
  /// single config is preserved into the auto slot (its default already matched
  /// auto), and manual seeds from its default. Idempotent via [buttonConfigMigrated].
  /// Returns true only if the active config was actually written to the
  /// firmware, so callers doing an optimistic UI write (the combine-switch flip)
  /// can revert and notify on a mid-push BLE drop. Existing callers that push on
  /// connect / mode-switch ignore the result (a failure is retried on the next
  /// connect).
  Future<bool> pushActiveButtonConfig() async {
    final dev = connectedDevice;
    if (dev == null) return false;
    final connection = await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection == null) return false;
    final prefs = SharedPreferencesUtil();
    try {
      if (!prefs.buttonConfigMigrated) {
        final existing = await connection.getButtonConfig();
        // A null read means the characteristic was unreachable (transient BLE
        // failure / disconnect mid-handshake). Bail without completing the
        // one-time migration AND without pushing our defaults — otherwise a
        // single failed first read would permanently skip preservation and
        // overwrite a customized firmware mapping with the app default. Retry on
        // the next connect.
        if (existing == null) return false;
        // Preserve a pre-existing customized/old-firmware config into the auto
        // slot; skip a factory-fresh device on new firmware so it keeps the
        // proper auto default. Normalize to the current combine style so a
        // preserved split (4/5) config can't leave the picker holding an action
        // it no longer offers when Combine is on (and vice versa).
        if (SharedPreferencesUtil.shouldPreserveExistingButtonConfig(existing)) {
          prefs.buttonConfigAuto =
              SharedPreferencesUtil.normalizeButtonConfigForCombine(existing, prefs.combineRecordButton);
        }
        prefs.buttonConfigMigrated = true;
      }
      // Belt-and-suspenders: never push a config inconsistent with the combine
      // style (idempotent when the stored config is already normalized).
      await connection.setButtonConfig(
          SharedPreferencesUtil.normalizeButtonConfigForCombine(prefs.activeButtonConfig, prefs.combineRecordButton));
      return true;
    } catch (e) {
      Logger.error('DeviceProvider: pushActiveButtonConfig failed: $e');
      return false;
    }
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
    // Mode flipped — make the new mode's button mapping live on the device.
    await pushActiveButtonConfig();
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
            // The firmware already toggled (and persists) the recording state on
            // this tap. READ it back rather than echoing a command off our own
            // (possibly stale) guess — echoing could flip the device to the
            // opposite of what you actually did. The firmware owns the button.
            final conn = await ServiceManager.instance().device.ensureConnection(connectedDevice?.id ?? '');
            final thr = await conn?.getVadThreshold();
            if (thr == 65535 || thr == 32769) {
              _manualRecording = thr == 65535;
              Logger.debug('DeviceProvider: Manual mode — recording '
                  '${_manualRecording ? "started" : "stopped"} (read from device).');
              notifyListeners();
            }
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
    if (pairedDeviceId.isEmpty) return null;

    final t0 = DateTime.now();
    Logger.debug('[BLE] _scanConnectDevice: starting connect to $pairedDeviceId');

    // Kick off native connect. This holds the Dart mutex internally until the
    // device is fully ready (services + MTU). Native owns connect + retry; there
    // is nothing for Dart to do but wait.
    //
    // Do NOT start a parallel discover() here when the connect is slow. discover()
    // runs an unfiltered SCAN_MODE_LOW_LATENCY scan (OmiBleManager.startScan), a
    // 100%-duty-cycle radio load, and it fired precisely when establishment was
    // most fragile — a link must be heard within 6 connection events (~165 ms) or
    // the central reports HCI 0x3e. Because it only triggered once a connect was
    // already struggling, it fed back on itself: slow connect → maximal scan →
    // establishment fails → retry → scan again. Its result was discarded anyway
    // (`unawaited`); the connect never consumed it. See NOTES.md "BLE: advertising
    // but won't connect".
    final connectFuture = ServiceManager.instance().device.ensureConnection(pairedDeviceId, force: true);

    // 30s budget, matching the native transport's own device-ready timeout.
    try {
      await connectFuture.timeout(const Duration(seconds: 30));
      final elapsed = DateTime.now().difference(t0).inMilliseconds;
      Logger.debug('[BLE] _scanConnectDevice: device ready after ${elapsed}ms');
      device = await _getConnectedDevice();
      if (device != null) return device;
    } catch (e) {
      Logger.debug(
          '[BLE] _scanConnectDevice: timed out/failed after ${DateTime.now().difference(t0).inMilliseconds}ms ($e)');
    }

    await Future.delayed(const Duration(seconds: 2));
    Logger.debug('[BLE] _scanConnectDevice: returning connectedDevice=${connectedDevice?.id}');
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
    _foregroundKeepAliveTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!isConnected || connectedDevice == null) return;
      final conn = await ServiceManager.instance().device.ensureConnection(connectedDevice!.id);
      final ok = (conn != null) && (await conn.sendKeepAlive());
      if (ok) {
        _consecutiveKeepAliveFails = 0;
        return;
      }
      _consecutiveKeepAliveFails++;
      // During DFU the link is saturated with SMP packets, so a keep-alive
      // write to the storage characteristic can transiently time out. Keep
      // SENDING (the firmware resets its idle timer only on storage-char
      // activity), but never force-disconnect — that would abort an otherwise
      // healthy firmware update. The DFU layer owns connection health here.
      if (_consecutiveKeepAliveFails >= 2 && !isFirmwareUpdateInProgress) {
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

  /// Notification writer for background processing progress. Registered on
  /// [RecordingsManager.processingProgress] whenever the app is backgrounded so
  /// the notification stays live even if [RecordingsController] is disposed.
  /// Gated on [_isAppInForeground] so it is silent when the app is open and
  DateTime _lastProcessingNotif = DateTime.fromMillisecondsSinceEpoch(0);

  /// [RecordingsController] owns the notification in time-remaining format.
  void _onProcessingProgress() {
    if (!_isAppInForeground && RecordingsManager.isProcessingAny) {
      final now = DateTime.now();
      if (now.difference(_lastProcessingNotif) < const Duration(seconds: 5)) return;
      _lastProcessingNotif = now;
      SyncNotification.processing(RecordingsController.processingNotificationText());
    }
  }

  /// True while a sync or processing run owns the foreground notification (it
  /// shows its own live progress). Idle-notification writers must check this
  /// before touching the notification so they don't clobber that progress.
  bool get _syncOwnsNotification =>
      ServiceManager.instance().wal.getSyncs().isSyncing ||
      RecordingsManager.isProcessingAny ||
      RecordingsManager.isSuccessNotificationActive.value ||
      _backgroundSyncActive;

  /// The single source of truth for the idle notification text shown when no
  /// sync/process is running. With auto-sync on, the title is the next-sync time
  /// and the subtext is the last-sync summary; the absolute "Next sync at H:MM"
  /// needs no per-minute refresh (it's woken/advanced by the exact alarm). With
  /// auto-sync off (Manual Only) the service isn't persistent, so this is a no-op
  /// at the native layer unless a connection notification is already up.
  Future<void> _showIdleNotification() async {
    await SyncNotification.idle(isConnected: isConnected, isConnecting: isConnecting);
  }

  void _pushBatteryToNative(int level) {
    if (!Platform.isAndroid) return;
    unawaited(BleHostApi().setDeviceBattery(level, DateTime.now().millisecondsSinceEpoch));
  }

  void restartBackgroundSyncTimer() => _startBackgroundSyncTimer();

  void _startBackgroundSyncTimer() {
    _backgroundSyncTimer?.cancel();
    final interval = SharedPreferencesUtil().backgroundSyncIntervalMinutes;
    // Keep WorkManager in sync with the Dart timer interval so both fire on
    // the same schedule. WorkManager is the fallback when the process is alive
    // but the foreground service was killed by an OEM battery optimizer.
    if (Platform.isAndroid) {
      unawaited(BleHostApi().rescheduleBackgroundSync(interval));
    }
    // Pin the single notification persistent while auto-sync is on and a device
    // is bound, so the idle "Next sync / Last Sync" line survives BLE disconnect
    // and app background. Manual Only / unbound releases it (connection-only
    // service lifetime — no idle notification, no redundant "Connected" line).
    final deviceBound = SharedPreferencesUtil().btDevice.id.isNotEmpty;
    unawaited(SyncNotification.setPersistent(interval > 0 && deviceBound));
    if (interval <= 0) {
      nextSyncTime = null;
      if (Platform.isAndroid) unawaited(BleHostApi().setNextSyncTime(0));
      notifyListeners();
      return; // Manual only
    }
    nextSyncTime = DateTime.now().add(Duration(minutes: interval));
    if (Platform.isAndroid) unawaited(BleHostApi().setNextSyncTime(nextSyncTime!.millisecondsSinceEpoch));
    notifyListeners();

    _backgroundSyncTimer = Timer.periodic(Duration(minutes: interval), (_) async {
      if (_disposed) return;
      nextSyncTime = DateTime.now().add(Duration(minutes: interval));
      if (Platform.isAndroid) unawaited(BleHostApi().setNextSyncTime(nextSyncTime!.millisecondsSinceEpoch));
      notifyListeners();

      if (!isConnected) {
        if (!isConnecting) {
          // Set the flag BEFORE the scan so _handleDeviceConnected's
          // background drop-guard knows this connection is a sanctioned
          // background sync and shouldn't be dropped.
          _pendingBackgroundSync = true;
          unawaited(SyncNotification.connecting());
          _armConnectSettleWatchdog();
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
              // Connect failed: advance to the next auto-sync slot and settle the
              // notification back to idle (never leave it stuck on "Connecting…").
              _failSyncCycleToIdle();
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

      try {
        WakelockPlus.enable();
        // Android: partial CPU wakelock. iOS: a beginBackgroundTask assertion so
        // the decode isn't suspended the instant the app backgrounds mid-run
        // (bounded window; longer decodes resume via the _draft pipeline). Both
        // are released in the finally below.
        if (Platform.isAndroid || Platform.isIOS) BleHostApi().acquireProcessingWakeLock();
        // Keep the firmware from idle-dropping the link mid-sync. Without this a
        // single >30s file read (large stitched/draft recordings) sends no
        // command for the firmware's 30s idle window and dies as "Stream closed
        // without EOT", so that file never finishes. _backgroundSyncActive is
        // set, so this also arms the keep-alive in the background. See
        // _startForegroundKeepAlive.
        _startForegroundKeepAlive();
        await SyncNotification.preparingSync();
        // A setup-phase failure in this sync (no connection, storage full,
        // or any early abort that throws) must NOT skip processing — bins that
        // already reached disk should still be decoded, mirroring how the
        // foreground pipeline auto-processes on disconnect. A transfer-phase
        // disconnect doesn't throw (syncAll returns partial and falls through),
        // so this inner catch only covers the early-abort cases.
        try {
          final result = await walSync.syncAll(progress: _BackgroundSyncProgress());
          SharedPreferencesUtil().lastSyncPartial = result?.isPartial ?? false;
          SharedPreferencesUtil().lastSyncSkipped = false;
          SharedPreferencesUtil().lastSyncCompletedMs = DateTime.now().millisecondsSinceEpoch;
          SharedPreferencesUtil().lastSyncStatusMs = DateTime.now().millisecondsSinceEpoch;
          await SyncNotification.finishingSync();
        } catch (e) {
          SharedPreferencesUtil().lastSyncPartial = true;
          SharedPreferencesUtil().lastSyncSkipped = false;
          // Stamp the time too so the notification reads "Partial • <now>" rather
          // than pinning a fresh "Partial" status to a stale prior-sync timestamp.
          SharedPreferencesUtil().lastSyncCompletedMs = DateTime.now().millisecondsSinceEpoch;
          SharedPreferencesUtil().lastSyncStatusMs = DateTime.now().millisecondsSinceEpoch;
          lastSyncError = e.toString();
          lastSyncErrorTime = DateTime.now();
          notifyListeners();
        }

        await SyncNotification.preparingProcessing();
        // Remove-before-add: onAppPaused may already hold a registration, and
        // ChangeNotifier allows duplicates that each fire separately.
        RecordingsManager.processingProgress.removeListener(_onProcessingProgress);
        RecordingsManager.processingProgress.addListener(_onProcessingProgress);
        // processAllCompletedSessions decodes in draft mode (a partial trailing
        // bin stays a draft and its source bin is kept for resume) and swallows
        // its own errors, so it runs whether or not the sync above succeeded.
        await RecordingsManager.processAllCompletedSessions();
        RecordingsManager.processingProgress.removeListener(_onProcessingProgress);
        await SyncNotification.finishingProcessing();
      } catch (e) {
        lastSyncError = e.toString();
        lastSyncErrorTime = DateTime.now();
        notifyListeners();
      } finally {
        WakelockPlus.disable();
        if (Platform.isAndroid || Platform.isIOS) BleHostApi().releaseProcessingWakeLock();
        // The keep-alive only covers the sync itself in the background; in the
        // foreground the connect/resume keep-alive owns it, so leave it running.
        if (!_isAppInForeground) _stopForegroundKeepAlive();
        RecordingsManager.processingProgress.removeListener(_onProcessingProgress);

        // Success state: show "Conversations ready" for 10s if we finished normally.
        if (lastSyncError == null && !RecordingsManager.isProcessingAny) {
          RecordingsManager.isSuccessNotificationActive.value = true;
          unawaited(SyncNotification.complete());
          await Future.delayed(const Duration(seconds: 10));
          RecordingsManager.isSuccessNotificationActive.value = false;
        }

        // Disconnect after the full sync+process cycle so that new firmware files
        // created during processing are also captured before we drop the
        // connection. Always disconnect — even if segments remain there is no
        // point holding the link, because the keep-alive has stopped and the
        // firmware idle-drops it within ~30s with nothing to reconnect it in the
        // background. Any leftover segments are picked up by the next scheduled
        // sync (or on app open/resume when one is due).
        if (!_isAppInForeground && !isFirmwareUpdateInProgress && !_isOnFirmwareUpdatePage && isConnected) {
          Logger.debug('Background sync done: disconnecting device.');
          unawaited(SyncNotification.disconnecting());
          ServiceManager.instance().device.disconnectDevice(isManual: true);
        }

        // The single notification persists across the disconnect and app
        // background — revert it to the idle "Next sync / Last Sync" line.
        unawaited(_showIdleNotification());
      }
    } finally {
      _backgroundSyncActive = false;
    }
  }

  /// Arm the background-connect settle watchdog (see [_connectSettleWatchdog]).
  /// Idempotent — re-arming cancels any prior timer, so each "Connecting…" paint
  /// resets the window.
  void _armConnectSettleWatchdog() {
    _connectSettleWatchdog?.cancel();
    _acquireConnectWakeLock();
    _connectSettleWatchdog = Timer(_connectSettleTimeout, () {
      _connectSettleWatchdog = null;
      // The connect window is over either way — drop the wake-lock now so it
      // can't outlive the attempt (give-up below releases it again, harmlessly).
      _releaseConnectWakeLock();
      // A connection arrived, or a sync/process now owns the notification —
      // whatever is showing isn't a stale "Connecting…", so leave it alone.
      if (_disposed || isConnected || _backgroundSyncActive || _syncOwnsNotification) return;
      Logger.debug('DeviceProvider: connect watchdog fired — settling stranded "Connecting…" notification to idle');
      _failSyncCycleToIdle();
    });
  }

  void _cancelConnectSettleWatchdog() {
    _connectSettleWatchdog?.cancel();
    _connectSettleWatchdog = null;
    _releaseConnectWakeLock();
  }

  /// Acquire/release the connect-phase CPU wake-lock. Reference-counted natively
  /// and guarded here so the pair stays balanced no matter which watchdog path
  /// fires. Android-only: iOS has no stranded-"Connecting…" failure mode (no
  /// persistent connection notification), and its acquireProcessingWakeLock
  /// starts a bounded background-task assertion we don't want to burn on every
  /// scheduled connect — so the gate keeps it from ever running there.
  void _acquireConnectWakeLock() {
    if (_connectWakeLockHeld || !Platform.isAndroid) return;
    _connectWakeLockHeld = true;
    BleHostApi().acquireProcessingWakeLock();
  }

  void _releaseConnectWakeLock() {
    if (!_connectWakeLockHeld) return;
    _connectWakeLockHeld = false;
    BleHostApi().releaseProcessingWakeLock();
  }

  /// A sync cycle could not run (e.g. the device wasn't reachable). Advance to
  /// the next auto-sync slot — re-arm the native exact alarm and recompute
  /// [nextSyncTime] — and settle the notification back to the idle line so it
  /// never sticks on "Connecting…".
  void _failSyncCycleToIdle() {
    _cancelConnectSettleWatchdog();
    final interval = SharedPreferencesUtil().backgroundSyncIntervalMinutes;
    if (interval > 0) {
      nextSyncTime = DateTime.now().add(Duration(minutes: interval));
      if (Platform.isAndroid) unawaited(BleHostApi().setNextSyncTime(nextSyncTime!.millisecondsSinceEpoch));
      notifyListeners();
    }
    SharedPreferencesUtil().lastSyncSkipped = true;
    // A skip didn't move any data, so leave lastSyncCompletedMs alone; only stamp the
    // status timestamp so the notification shows "Skipped • <now>".
    SharedPreferencesUtil().lastSyncStatusMs = DateTime.now().millisecondsSinceEpoch;
    unawaited(_showIdleNotification());
  }

  void onAppPaused() async {
    if (!_isAppInForeground) return;
    _isAppInForeground = false;
    // Take over processing-progress notification updates in case a foreground-
    // triggered run is in flight. Remove before add to guarantee exactly one
    // registration — _doBackgroundSync may have already registered it, and
    // ChangeNotifier allows duplicates that each fire separately.
    RecordingsManager.processingProgress.removeListener(_onProcessingProgress);
    RecordingsManager.processingProgress.addListener(_onProcessingProgress);
    RecordingsManager.isSuccessNotificationActive.removeListener(_onSuccessNotificationChanged);
    RecordingsManager.isSuccessNotificationActive.addListener(_onSuccessNotificationChanged);

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
      // The single notification is already persistent; just refresh it to the
      // idle "Next sync" line unless a sync/process is actively driving it.
      if (!_syncOwnsNotification) {
        await _showIdleNotification();
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

  void _onSuccessNotificationChanged() {
    if (!_isAppInForeground && !RecordingsManager.isSuccessNotificationActive.value && !_syncOwnsNotification) {
      unawaited(_showIdleNotification());
    }
  }

  bool _shouldSyncNow() {
    // One timer governs everything: opening the app syncs only once the auto-sync
    // interval has elapsed since the last sync — the same threshold the background
    // timer uses, not a separate hardcoded window. "Manual Only" (interval <= 0)
    // never auto-syncs on open; the user syncs by hand.
    final interval = SharedPreferencesUtil().backgroundSyncIntervalMinutes;
    if (interval <= 0) return false;
    if (SharedPreferencesUtil().lastSyncSkipped) return true;
    final lastMs = SharedPreferencesUtil().lastSyncCompletedMs;
    if (lastMs <= 0) return true;
    return DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(lastMs)).inMinutes >= interval;
  }

  void onAppResumed() {
    _isAppInForeground = true;
    // RecordingsController resumes ownership of processing notifications.
    RecordingsManager.processingProgress.removeListener(_onProcessingProgress);
    // Came back within the grace window — keep the (still-live) connection.
    _pauseDisconnectTimer?.cancel();
    if (isConnected) _startForegroundKeepAlive();
    // Release the overnight wake lock now that the user has the app open.
    final walSync = ServiceManager.instance().wal.getSyncs();
    // The single notification is persistent (it survives foreground/background),
    // so we no longer tear it down on resume — just settle it to the idle line
    // when nothing is actively driving it.
    if (!walSync.isSyncing &&
        !RecordingsManager.isProcessingAny &&
        !RecordingsManager.isSuccessNotificationActive.value) {
      unawaited(_showIdleNotification());
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
      // Skip for Manual Only (interval <= 0) — user controls sync explicitly.
      if (prefs.backgroundSyncIntervalMinutes > 0 && !walSync.isSyncing && walSync.estimatedTotalSegments > 0) {
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
    // Keep _foregroundKeepAliveTimer running: DFU uses the SMP service, not the
    // Omi storage characteristic, so transport_mark_activity() never fires during
    // the transfer. Without the keep-alive the firmware's 15 s idle-disconnect
    // triggers mid-DFU and kills the connection. Newer firmware also defers
    // idle-disconnect while a DFU image upload is active (sd_get_ota_active), so
    // this heartbeat is the backstop that flashes a device still running the
    // older firmware that lacks that defer — keep it until the floor firmware
    // version guarantees the defer.

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
    _bleMuteListener?.cancel();
    _reconnectionTimer?.cancel();
    _reconnectDelayTimer?.cancel();
    _resumeReconnectDebounce?.cancel();
    _pauseDisconnectTimer?.cancel();
    _connectSettleWatchdog?.cancel();
    _releaseConnectWakeLock();
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
    await _bleMuteListener?.cancel();
    _bleMuteListener = null;
    if (isMuted) {
      isMuted = false;
      muteSince = null;
      SyncNotification.isMuted = false;
      SyncNotification.muteSince = null;
    }
    notifyListeners();
    await setConnectedDevice(null);
    setIsConnected(false);
    updateConnectingStatus(false);
    _stopForegroundKeepAlive();

    final walSync = ServiceManager.instance().wal.getSyncs();
    // Mark for resume before cancelling so the flag is set even if cancelSync
    // triggers a re-entrant callback. Only arm it in the background — foreground
    // disconnects recover through the normal reconnect loop.
    //
    // Arm on _backgroundSyncActive too, not just isSyncing: a background sync's
    // connect+setup window (time-sync, diagnostics, pushActiveButtonConfig) runs
    // before syncAll flips isSyncing, so an accidental drop there would otherwise
    // fall through to _handleDeviceConnected's drop-guard and kill the reconnect
    // mid-run. _backgroundSyncActive spans the whole _doBackgroundSync attempt.
    // Safe against the intentional end-of-sync disconnect (_doBackgroundSync's
    // :937): that path clears _backgroundSyncActive synchronously (:945) in the
    // same turn, before its debounced disconnect callback reaches here.
    if (!_isAppInForeground && (walSync.isSyncing || _backgroundSyncActive)) {
      _pendingSyncResume = true;
    }
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
      // Connected — the connect attempt is no longer in flight, so the settle
      // watchdog must not later fire and stamp a spurious "Skipped".
      _cancelConnectSettleWatchdog();
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

    unawaited(SyncNotification.requestPermissions());

    // Re-anchor the firmware clock on every connected transition, not just the
    // Dart-initiated connect path. A native auto-reconnect (e.g. after a
    // firmware reboot/crash) re-establishes the link without calling
    // OmiDeviceConnection.connect(), so without this the device would keep a
    // reset clock and mis-stamp new recordings.
    final timeSyncConn = await ServiceManager.instance().device.ensureConnection(device.id);
    await timeSyncConn?.syncTime();

    await initiateBleBatteryListener();
    await updateBatteryLevel();
    await updateChargingState();
    await initiateBleMuteListener();
    await updateMuteState();
    await initiateBleButtonListener();

    {
      final prefs = SharedPreferencesUtil();
      final conn = await ServiceManager.instance().device.ensureConnection(device.id);
      final thr = await conn?.getVadThreshold();
      // Read-and-adopt: the firmware persists the threshold across reboot and
      // oo→oo OTA, so it is the source of truth. Reflect whatever it holds rather
      // than overwriting it with our remembered preference — pushing here would
      // stomp a change made on the device while it was offline (e.g. a button
      // start). Mode + auto sensitivity are only changed by an explicit in-app
      // action, which writes + persists at that moment.
      if (thr == 65535 || thr == 32769) {
        // Manual recording sentinels → manual mode; 65535 = recording, 32769 = standby.
        prefs.manualMode = true;
        _manualRecording = thr == 65535;
      } else if (thr != null) {
        // A real auto-sensitivity value → auto mode.
        prefs.manualMode = false;
        _manualRecording = false;
      }
      // thr == null (read failed) → leave the last-known state untouched.
      notifyListeners();
    }

    // The mode was just adopted from the device above, so push the matching
    // per-mode button config (and run the one-time migration) now that
    // prefs.manualMode is current.
    await pushActiveButtonConfig();

    await ServiceManager.instance().wal.getSyncs().setDevice(device, prefetchedFiles: []);

    // Timer connected in background and deferred the sync until now so that
    // walSync._device is set before syncAll is called. _pendingSyncResume takes
    // the same path: fire _doBackgroundSync to pick up what the interrupted sync
    // left on the device.
    if (_pendingBackgroundSync || _pendingSyncResume) {
      _pendingBackgroundSync = false;
      _pendingSyncResume = false;
      unawaited(SyncNotification.connected());
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

      // Log the persisted BLE connect-failure counters on every connect so they land
      // in 'Save Diagnostic Logs to File'. The counts survive a reboot, so after
      // power-cycling to reconnect, this captures failures from before the reboot.
      // See NOTES.md "BLE: advertising but won't connect". Skip if a sync is already
      // transferring — a GATT read racing the storage stream throws Error 133 on
      // Android (next connect logs it instead).
      //
      // Logged whatever the values are, including all-zero. Counters that did not move
      // across an outage are the reading that acquits the peripheral — it never heard
      // the CONNECT_INDs — and are exactly as diagnostic as counters that did. Gating
      // on `> 0` made that case indistinguishable from a read that never happened.
      // The counters are cumulative across boots, so only their movement between two
      // consecutive lines means anything.
      final dropStats = conn.isStorageBusy ? null : await conn.getDropStats();
      if (dropStats != null) {
        if (dropStats.failedConnCount > 0 || dropStats.estabFailCount > 0) {
          Logger.warning('Device BLE connect-fail counters: conn=${dropStats.failedConnCount} '
              'estab_0x3e=${dropStats.estabFailCount} '
              '(last failure during ${dropStats.lastFailedConnDuringSlowAdv ? "slow" : "fast"} advertising)');
        }
        await DebugLogManager.logEvent('device_conn_fail', {
          'failed_conn_count': dropStats.failedConnCount,
          'estab_fail_count': dropStats.estabFailCount,
          'last_failure_adv_mode': dropStats.lastFailedConnDuringSlowAdv ? 'slow' : 'fast',
        });

        // Priority Recording diagnostics (0x0062, offsets 44–56). A start with no
        // matching stop, a dropped marker write, or an empty-bin rotation is the
        // on-device fingerprint of a lost Priority Recording — surfaced here so it's
        // traceable from the app log without an RTT capture. Counters are cumulative
        // since boot; only movement between two readings means anything. Skip the noise
        // when all zero (older firmware, or no priority recording has run).
        final bool priorityActivity = dropStats.priorityRecordStarts > 0 ||
            dropStats.priorityRecordStops > 0 ||
            dropStats.markerWriteDrops > 0 ||
            dropStats.emptyBinRotations > 0;
        if (priorityActivity) {
          final priorityMsg = 'Device priority-record counters: starts=${dropStats.priorityRecordStarts} '
              'stops=${dropStats.priorityRecordStops} markerDrops=${dropStats.markerWriteDrops} '
              'emptyBinRotations=${dropStats.emptyBinRotations}';
          if (dropStats.markerWriteDrops > 0 || dropStats.emptyBinRotations > 0) {
            Logger.warning('$priorityMsg — possible lost Priority Recording (marker/audio dropped on-device)');
          } else {
            Logger.debug(priorityMsg);
          }
          await DebugLogManager.logEvent('device_priority_stats', {
            'priority_starts': dropStats.priorityRecordStarts,
            'priority_stops': dropStats.priorityRecordStops,
            'marker_write_drops': dropStats.markerWriteDrops,
            'empty_bin_rotations': dropStats.emptyBinRotations,
          });
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
    Logger.debug(
        '[BLE] _handleDeviceConnected: $deviceId (fg=$_isAppInForeground pendingBgSync=$_pendingBackgroundSync pendingResume=$_pendingSyncResume)');
    try {
      var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
      if (connection == null) {
        Logger.warning(
            '[BLE] _handleDeviceConnected: ensureConnection returned null for $deviceId — state mismatch or device already disconnected');
        return;
      }
      // Defense in depth: if a foreground-initiated scan completed after the
      // user backgrounded the app, drop the connection — the device is meant to
      // stay disconnected in the background. Background syncs (timer /
      // heartbeat-sync-if-due) set _pendingBackgroundSync first, so they're
      // exempt.
      if (!_isAppInForeground &&
          !_pendingBackgroundSync &&
          !_pendingSyncResume &&
          !isFirmwareUpdateInProgress &&
          !_isOnFirmwareUpdatePage) {
        // The link is up but nothing sanctioned it. Usually that's a foreground-initiated
        // scan that landed after the app was backgrounded (drop it — the device is meant to
        // stay disconnected in the background). But it's also how a native auto-reconnect
        // that recovered a long outage arrives — e.g. a BLE wedge cleared after many minutes,
        // with unsynced audio waiting. Tell the two apart by whether a sync is actually due:
        // if it is, adopt this hard-won link as a background sync instead of discarding it.
        // (See NOTES.md "BLE: advertising but won't connect" — the guard used to throw away
        // 51-minute wedge recoveries, forcing another outage until the user toggled Bluetooth.)
        if (_shouldSyncNow()) {
          Logger.debug('[BLE] _handleDeviceConnected: backgrounded but sync is due — adopting link as background sync');
          _pendingBackgroundSync = true;
        } else {
          Logger.debug('[BLE] _handleDeviceConnected: dropping — app is backgrounded and no sync was pending');
          unawaited(ServiceManager.instance().device.disconnectDevice(isManual: true));
          return;
        }
      }
      Logger.debug('[BLE] _handleDeviceConnected: proceeding to setup for ${connection.device.id}');
      _onDeviceConnected(connection.device);
    } catch (e) {
      Logger.error('[BLE] _handleDeviceConnected: exception: $e');
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
  void onStatusChanged(DeviceServiceStatus status) {
    notifyListeners();
  }
}

class _BackgroundSyncProgress implements IWalSyncProgressListener {
  DateTime _lastNotif = DateTime.fromMillisecondsSinceEpoch(0);
  int _totalCount = 0;

  @override
  void onWalSyncedProgress(double percentage, {double? speedKBps, SyncPhase? phase}) {
    // In foreground the recordings_controller is the global WAL progress listener
    // and owns the notification — defer to it to avoid flip-flopping.
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) return;
    final now = DateTime.now();
    if (now.difference(_lastNotif) < const Duration(seconds: 1)) return;
    _lastNotif = now;
    final estimated = ServiceManager.instance().wal.getSyncs().estimatedTotalSegments;
    if (estimated > _totalCount) _totalCount = estimated;
    final synced = (percentage * _totalCount).round().clamp(0, _totalCount);
    SyncNotification.syncing(RecordingsController.syncingNotificationText(synced, _totalCount));
  }
}
