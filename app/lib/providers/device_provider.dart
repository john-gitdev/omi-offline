import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/services/device_clock_anchor.dart';
import 'package:omi/services/devices/device_drop_stats.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/devices/device_crash_log.dart';
import 'package:omi/services/devices/diag_log_record.dart';
import 'package:omi/services/devices/errors.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'package:omi/pages/recordings/recordings_controller.dart';
import 'package:omi/services/recordings_manager.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/vad/vad_types.dart';
import 'package:omi/services/wals.dart';
import 'package:omi/utils/audio/sync_notification.dart';
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/other/debouncer.dart';
import 'package:omi/utils/platform/platform_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Outcome of [DeviceProvider.setMuted], so the UI can explain a silent no-op
/// instead of leaving the user to guess why the mute toggle did nothing.
enum MuteResult {
  /// The device adopted the requested mute state.
  applied,

  /// The firmware ignored the write because an auto-mode Priority Recording is
  /// force-capturing (which can't be muted).
  priorityRecording,

  /// The firmware ignored the write because the device is actually in manual
  /// mode (mute is unavailable there).
  manualMode,

  /// The write or read-back didn't complete — the device was unreachable.
  unreachable,
}

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
  // How often the tick re-checks whether an in-flight sync has finished. NOT a second
  // grace window: the grace and this cadence used to be the same 15 s, which made one
  // value do two jobs. The tick re-armed for a full grace whenever it found a sync
  // running, so the grace a user actually got after a sync was however much of the
  // window happened to be left when the sync ended — anywhere in [0, 15 s]. A sync
  // finishing a second before the tick dropped the link a second later, losing exactly
  // the quick-return protection the grace exists for. Poll at this cadence while the
  // link is busy, then hand back one FULL grace once it goes idle.
  static const Duration _backgroundDisconnectPoll = Duration(seconds: 3);
  // Whether the previous tick found a sync holding the link. Turns the next idle tick
  // into "start the real grace now" instead of "disconnect now". Cleared whenever the
  // window is (re)opened or cancelled, so it always describes the current window.
  bool _pauseGraceSawSync = false;
  // Background-connect give-up watchdog. A scheduled-sync connect attempt that never
  // resolves must still END the cycle: advance the auto-sync schedule and record the
  // Skip, both of which [_failSyncCycleToIdle] does. Normally the attempt's own finally
  // / [_connectThenSyncOrFail] gets there, but under Doze the process can be frozen
  // mid-attempt so neither runs. This timer is the safety net; a timer that comes due
  // while the isolate is frozen fires as soon as it thaws, so it also recovers a frozen
  // attempt on the next CPU slice. The window is longer than the connect chain below it
  // (~90 s) so a legitimately slow connect isn't cut short.
  //
  // This used to be described as a NOTIFICATION fix — it existed to un-stick a stranded
  // "Connecting…" line. That transient no longer exists (the notification reports work and
  // outcomes, never link state), so what is left is the schedule/Skip bookkeeping, which
  // was always the load-bearing half: without it the three auto-sync triggers drift apart
  // and the resting line goes on asserting a stale "Complete" through an outage.
  //
  // Belt-and-suspenders: the watchdog only recovers *after* a thaw, which under a long
  // Doze can be many minutes away. So for the duration of the attempt we also hold a CPU
  // partial wake-lock (see [_acquireConnectWakeLock]) so the process can't be frozen
  // mid-connect in the first place — which protects the CONNECT itself, not just this
  // timer. The wake-lock is the primary fix; the timer is the fallback for when it can't
  // hold (battery-optimisation exemption denied) or the process is killed outright.
  Timer? _connectSettleWatchdog;
  static const Duration _connectSettleTimeout = Duration(seconds: 150);
  // Held (Android) while a background connect attempt is outstanding so Doze
  // can't freeze the process mid-connect and lose the whole cycle — a freeze is exactly
  // what stops the give-up watchdog (and _connectThenSyncOrFail's own give-up) from ever
  // running, and it stalls the connect it is meant to be making. The native lock is
  // reference-counted, so releasing it here never disturbs a concurrent DFU or
  // processing run. This flag keeps the acquire/release pair balanced across the
  // watchdog's several resolution paths (success, give-up, fire, dispose).
  bool _connectWakeLockHeld = false;
  // Keep-alive: sends HEARTBEAT (0x32) to storage characteristic every 10s so
  // the firmware doesn't trip its 60s idle-disconnect (six beats fit the window, so
  // five may be missed — a wider margin than the old 5s/15s pair, which tolerated
  // two). Both numbers moved together: at 5s into a 60s window this fired eleven
  // times more often than the timeout needed, and every beat is a GATT write that
  // wakes a radio the idle connection parameters had just been widened to let sleep
  // (transport.c CONN_PARAM_IDLE_*). 10s halves that traffic while keeping the
  // liveness check below responsive (two failures ⇒ ~20s, versus ~40s at a 20s
  // cadence).
  //
  // That check is NOT made redundant by the firmware's own 60s timeout, which is
  // the obvious objection to it. The two cover opposite sides. The firmware's
  // timer reclaims the DEVICE's radio from a phone that holds the link and goes
  // quiet, and it can only fire while the firmware is still party to the link.
  // This one covers the phone's belief: a wedged Android GATT, or a peer that is
  // already gone with no disconnect reported. In that state the firmware is not in
  // the connection at all — it may have hung up long ago, or be switched off — so
  // nothing on its side will ever resolve it, and the app would sit "connected"
  // indefinitely. Hence recycleConnection() below rather than a mere flag: the fix
  // is to rebuild the phone's GATT, which is also what the ghost-purge path exists
  // for. Where the two DO overlap (writes failing on a link the firmware still
  // holds) this is simply the faster of the two.
  // Runs while the user is actively in
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
  // Whether this link has ever carried a successful keep-alive. Arms the recycle
  // below: rebuilding the GATT is a remedy for a link that WAS working and stopped,
  // and says nothing useful about one that has not come up yet. Reset with the
  // failure counter whenever the keep-alive is (re)started, so it describes the
  // current link rather than any previous one.
  bool _keepAliveEverSucceeded = false;
  final Debouncer _disconnectDebouncer = Debouncer(delay: const Duration(milliseconds: 500));
  final Debouncer _connectDebouncer = Debouncer(delay: const Duration(milliseconds: 1000));
  bool _isHandlingDisconnect = false;
  int _consecutiveAccidentalDisconnects = 0;

  bool _manualRecording = false;
  bool get manualRecording => _manualRecording;

  /// Everything the firmware owns, read ONCE per connect in the window before the
  /// background sync starts, and served from here afterwards.
  ///
  /// Why a cache at all: these reads have to be serialized against the storage
  /// characteristic (an unguarded GATT read racing the transfer stream drops the
  /// link on Android with Error 133), so every reader used the non-blocking
  /// [DeviceConnection.getFeaturesIfIdle] and got `null` whenever a sync held the
  /// lock. Four call sites each read the same immutable-per-connection bytes and
  /// each failed on its own — Device Settings hid every capability-gated row,
  /// Button Configuration hid the Toggle action, Debug Tools lost the event log.
  /// Reading once, early, and sharing the answer removes three of those reads and
  /// the failure mode with them.
  ///
  /// `null` means UNREAD, never "the device has none" — the distinction the old
  /// `getFeatures()` (which returned 0 on failure) could not express, and the
  /// reason a single unanswered read used to empty a whole page. Consumers must
  /// fall back to their own read rather than rendering a null as "absent".
  ///
  /// Not device-scoped: only one Omi is ever paired, and the values are refreshed
  /// on every connect, so a stale entry cannot outlive the device it describes.
  int? deviceFeatures;
  int? deviceVadThreshold;
  int? deviceLedDimRatio;
  int? deviceMicGain;
  int? devicePriorityRecordCap;
  bool? deviceConnectedLed;
  bool? deviceLedBootEnabled;

  String? lastSyncError;
  DateTime? lastSyncErrorTime;

  // Crash logs collected each time the device connects (newest first, capped at 50)
  final List<DeviceCrashLog> crashLogs = [];
  static const _crashLogsKey = 'deviceCrashLogs';

  // On-device diagnostic event log (dev tool, OMI_FEATURE_DIAG_LOG / bit 12; see
  // OmiFeatures.diagLog). Whether the connected firmware advertises the capability,
  // and the most recent drained batch for the Debug Tools viewer. See
  // diag_log_record.dart.
  bool diagLogSupported = false;
  List<DiagLogRecord> diagLogRecords = [];
  int diagLogDroppedCount = 0;
  DateTime? diagLogLastPulledAt;

  /// Whether the DEVICE's runtime capture gate is believed on, and when that belief
  /// was last confirmed by a successful 0x0064 write. Distinct from the
  /// `diagLogEnabled` pref on purpose: the push is skipped while a sync holds the
  /// storage lock and can fail outright, so the pref alone says nothing about whether
  /// the device is actually recording events. A snapshot that reports the pref as
  /// "capture=true" while the device's gate is off makes an empty log look like a
  /// quiet device instead of an un-armed one.
  bool? diagLogGateOnDevice;
  DateTime? diagLogGatePushedAt;

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

  /// [uiAttached] is native's answer to "is there an Activity right now" — see the
  /// foreground note in the constructor. Optional so tests and any future caller that
  /// cannot ask keep the pre-existing behaviour.
  DeviceProvider({bool? uiAttached}) {
    WidgetsBinding.instance.addObserver(this);
    // Correctly initialize foreground state for cases where app starts in background.
    //
    // `lifecycleState` is authoritative WHEN IT IS SET. It is null until the first
    // lifecycle event arrives, and null used to mean "we just launched, assume
    // foreground" — safe, because this object could only ever be built by the widget
    // tree, which meant a screen existed.
    //
    // That is no longer true. The Flutter engine now outlives MainActivity, so this can
    // be constructed in a process WorkManager started with no Activity at all, where
    // lifecycleState stays null indefinitely and "assume foreground" is simply wrong —
    // it would keep the app pinging the Omi to hold a link open as though a user were
    // watching. Native is the one that actually knows, so ask it rather than infer from
    // an absence.
    final state = WidgetsBinding.instance.lifecycleState;
    _isAppInForeground = state != null ? state == AppLifecycleState.resumed : (uiAttached ?? true);
    Logger.debug('[BLE] DeviceProvider init: lifecycleState=$state uiAttached=$uiAttached '
        '_isAppInForeground=$_isAppInForeground');

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
      // Sync on app open whenever one is due. The device is disconnected in the
      // background, so the periodic timer/heartbeat may not have fired; opening
      // the app is the reliable trigger.
      final syncDue = _shouldSyncNow();
      if (syncDue) _pendingAppOpenSync = true;
      // This used to connect unconditionally, on the reasoning — written when only a
      // screen could build this object — that `_isAppInForeground` is true here, so the
      // link survives _handleDeviceConnected's drop-guard long enough to sync. Since
      // 0.36.0 a WorkManager or alarm wake constructs it with no UI at all, where that
      // is false: the connect was made and the guard hung up on it seconds later, for
      // nothing. Connect when someone is watching, or when the sync that follows needs
      // the link; otherwise leave the radio alone and let the schedule bring it up.
      if (_isAppInForeground || syncDue) {
        Future.microtask(() => periodicConnect('app open', boundDeviceOnly: true, userInitiated: true));
      }
    }
    SharedPreferencesUtil.lastSyncCompleted.addListener(_onSyncCompleted);
    _startBackgroundSyncTimer();
    // Last, deliberately. It can push the notification, and _startBackgroundSyncTimer is
    // what publishes nextSyncTime — sweeping earlier would render "Omi Offline" instead
    // of "Next sync at H:MM". It also means the `_shouldSyncNow()` above ran without the
    // skip this may set, so an orphan brings the next sync forward by a tick rather than
    // forcing a connect during launch; the flag persists, so nothing is lost.
    _sweepOrphanedSyncCycle();
  }

  /// Re-anchor the auto-sync schedule off the back of a completed sync, whoever ran it.
  ///
  /// The foreground pipeline (`RecordingsController`) is the case this exists for: it
  /// stamps `lastSyncCompletedMs` from a page that holds no DeviceProvider, so before
  /// this the timer and the alarm kept their original phase and a manual sync was
  /// followed by an automatic one moments later. The background path reaches here too
  /// — harmlessly, since it is re-anchoring to a completion instant a few seconds after
  /// the tick that started it.
  void _onSyncCompleted() {
    if (_disposed) return;
    _anchorAutoSyncSchedule();
  }

  void _onBackgroundSyncRequested() {
    // `hasDevice`, not just `isConnected`: the WAL layer is handed the device at the very
    // END of _onDeviceConnected, so "the link is up" and "a sync can run" are different
    // questions and a connect whose setup never finished answers them differently.
    // Calling _doBackgroundSync there reaches syncAll's `_device == null` guard, which
    // returns null — a skip that no amount of retrying can turn into a sync, because
    // nothing on that path ever registers the device. Taking the connect branch instead
    // runs setup, which is the only thing that can.
    final walRegistered = ServiceManager.instance().wal.getSyncs().hasDevice;
    Logger.debug(
      '[BLE] _onBackgroundSyncRequested: OS scheduler fired '
      '(fg=$_isAppInForeground connected=$isConnected walRegistered=$walRegistered)',
    );
    if (isConnected && walRegistered) {
      _doBackgroundSync();
    } else {
      _pendingBackgroundSync = true;
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
    Logger.debug(
      '[BLE] _onStateRestored: ${peripheralUuids.length} peripheral(s) restored, syncDue=$due '
      '(connected=$isConnected)',
    );
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
  /// on failure, advance to the next slot and record the Skip.
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
    if (state == null) return; // read failed — keep the last-known state
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

  /// Toggle mute over BLE (mute-icon tap) and report the outcome so the UI can
  /// explain a no-op instead of failing silently.
  ///
  /// The firmware honors mute only in auto mode at rest; it silently ignores the
  /// write while an auto-mode Priority Recording force-captures (and in manual
  /// mode, though the toggle isn't shown there). We tell a genuine firmware
  /// ignore apart from a comms failure via the write ACK + read-back, then
  /// confirm the reason from the PERSISTED VAD threshold so a stale mode
  /// assumption isn't mislabeled.
  Future<MuteResult> setMuted(bool muted) async {
    final dev = connectedDevice;
    if (dev == null) return MuteResult.unreachable;
    final connection = await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection == null) return MuteResult.unreachable;
    // With-response write: true means the firmware received it (and ran
    // mute_apply); false means the write never landed.
    final wrote = await connection.setMute(muted);
    if (!wrote) return MuteResult.unreachable;
    // Read back the authoritative state. Null = the read itself failed, so we
    // can't tell whether the mute took — treat as unreachable, not "ignored".
    final state = await connection.getMuteState();
    if (state == null) return MuteResult.unreachable;
    _applyMuteState(state.muted, state.since);
    if (state.muted == muted) return MuteResult.applied;
    // Write landed + read succeeded but the device didn't adopt the request: the
    // firmware ignored it. Confirm the mode from the persisted threshold — an
    // auto value means a Priority Recording is force-capturing; a sentinel means
    // the device is really in manual mode, so re-adopt that (matching the
    // connect-time read-and-adopt) to stop offering mute. A failed read can't
    // confirm the reason, so don't assert a specific one — report unreachable.
    final thr = await connection.getVadThreshold();
    if (thr == null) return MuteResult.unreachable;
    if (thr == 32769 || thr == 65535) {
      SharedPreferencesUtil().manualMode = true;
      notifyListeners();
      return MuteResult.manualMode;
    }
    return MuteResult.priorityRecording;
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

  /// True when the app adopted a recording mode from the Omi that differs from
  /// the one the user chose. Only reachable for an Omi the app has never
  /// configured — a replacement, or one whose settings were reset — because the
  /// button cannot move the persisted threshold across the auto/manual line and a
  /// firmware update does not clear it. Surfaced as a banner on the recordings
  /// page; cleared when the user reviews or dismisses it.
  bool recordingModeMismatch = false;

  void dismissRecordingModeMismatch() {
    if (!recordingModeMismatch) return;
    recordingModeMismatch = false;
    notifyListeners();
  }

  /// Appends the OUTGOING mode's settings to the switch history, so a backlog
  /// recorded under them is still cut by them. Must be called BEFORE the caller
  /// changes anything the settings are derived from.
  void _recordModeSwitch(SharedPreferencesUtil prefs) {
    prefs.processingModeSwitchHistory = ModeSwitchRecord.encode(
      ModeSwitchRecord.append(
        ModeSwitchRecord.decode(prefs.processingModeSwitchHistory),
        ModeSwitchRecord(
          atUtcSeconds: DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
          settings: ProcessingSettings.fromPrefs().mode,
        ),
      ),
    );
  }

  /// Bring the app's recording mode into line with the Omi's.
  ///
  /// Almost always a no-op: only the app can move the persisted threshold across
  /// the auto/manual line, so the two normally agree. When they don't, this is an
  /// Omi the app has never configured.
  ///
  /// Everything that depends on the mode moves together. Leaving the flat vad*
  /// prefs behind is what would make an adopted mode dangerous rather than merely
  /// surprising: the processor reads those, not the label.
  void _adoptRecordingModeFromDevice(SharedPreferencesUtil prefs, bool manual) {
    if (prefs.manualMode == manual) return;
    Logger.debug('DeviceProvider: adopting ${manual ? "manual" : "auto"} mode from the device — the app had '
        '${prefs.manualMode ? "manual" : "auto"}. Only an Omi this app has not configured can differ.');
    _recordModeSwitch(prefs);
    prefs.manualMode = manual;
    prefs.applyRecordingModeDefaults(manual);
    // Worth telling the user about only if they had chosen a mode themselves; a
    // fresh install carries a default, not a preference.
    if (prefs.manualModeUserSet) recordingModeMismatch = true;
  }

  /// Writes the Omi's AAD threshold and confirms it actually landed.
  ///
  /// Returns whether the device now holds [threshold]. Reading it back is not
  /// belt-and-braces here — it is the only honest signal, because every layer
  /// underneath fails **silently**:
  ///   * `performSetVadThreshold` wraps its BLE write in `catch (_) {}`;
  ///   * `DeviceConnection.setVadThreshold` no-ops when not connected;
  ///   * `ensureConnection` can hand back null.
  /// So "no exception was thrown" says nothing at all about whether the Omi
  /// changed, and the old void signature had no way to tell the caller.
  ///
  /// The read is honest about the right thing: `0013`'s read handler returns
  /// `app_settings_get_vad_threshold()`, the PERSISTED value, and the write
  /// handler persists before applying. So a mismatch also catches the case where
  /// the live threshold changed but the NVS save failed — which would revert on
  /// the next reboot, so refusing it is correct.
  Future<bool> _setDeviceVadThreshold(int threshold) async {
    final dev = connectedDevice;
    if (dev == null) return false;
    try {
      final connection = await ServiceManager.instance().device.ensureConnection(dev.id);
      if (connection == null) return false;
      await connection.setVadThreshold(threshold);
      final readBack = await connection.getVadThreshold();
      if (readBack == threshold) return true;
      Logger.error('DeviceProvider: VAD threshold write did not take — wrote $threshold, device reports '
          '${readBack ?? "no answer"}.');
      return false;
    } catch (e) {
      Logger.error('DeviceProvider: VAD threshold write to $threshold failed: $e');
      return false;
    }
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
          prefs.buttonConfigAuto = SharedPreferencesUtil.normalizeButtonConfigForCombine(
            existing,
            prefs.combineRecordButton,
          );
        }
        prefs.buttonConfigMigrated = true;
      }
      // Belt-and-suspenders: never push a config inconsistent with the combine
      // style (idempotent when the stored config is already normalized).
      await connection.setButtonConfig(
        SharedPreferencesUtil.normalizeButtonConfigForCombine(prefs.activeButtonConfig, prefs.combineRecordButton),
      );
      return true;
    } catch (e) {
      Logger.error('DeviceProvider: pushActiveButtonConfig failed: $e');
      return false;
    }
  }

  /// Push the on-device diagnostic event log's runtime enable bit (0x0064) to match
  /// the local [SharedPreferencesUtil.diagLogEnabled] pref. Called on connect and
  /// whenever the Debug Tools toggle flips. No-op on firmware without the feature
  /// (the write is swallowed by the connection layer). Default OFF means a rebooted
  /// device stays silent until the app re-pushes here.
  /// Returns true when the gate write reached the device; false when it was skipped
  /// (a sync holds the storage lock), failed, or there's no connection — the caller
  /// can surface that the toggle hasn't applied yet (it re-pushes on next connect).
  Future<bool> pushDiagLogEnabled() async {
    final dev = connectedDevice;
    if (dev == null) return false;
    final connection = await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection == null) return false;
    try {
      final want = SharedPreferencesUtil().diagLogEnabled;
      final ok = await connection.setDiagLogEnabled(want);
      if (ok) {
        diagLogGateOnDevice = want;
        diagLogGatePushedAt = DateTime.now();
      }
      return ok;
    } catch (e) {
      Logger.debug('DeviceProvider: pushDiagLogEnabled failed: $e');
      return false;
    }
  }

  /// Drain the on-device diagnostic event ring (0x0063), acking each batch so the
  /// device clears what it sent, log every record to the debug log, and cache the
  /// batch for the Debug Tools viewer. Returns the record count, or -1 when not
  /// connected / the feature is unavailable / a sync holds the storage lock.
  Future<int> pullDiagLog() async {
    final dev = connectedDevice;
    if (dev == null) return -1;
    final connection = await ServiceManager.instance().device.ensureConnection(dev.id);
    if (connection == null) return -1;
    // Pass the current gate so acking each batch preserves capture state — a Clear
    // while the toggle is OFF must not re-enable on-device logging via the ack write.
    final result = await connection.drainDiagLog(keepEnabled: SharedPreferencesUtil().diagLogEnabled);
    if (result == null) return -1;
    diagLogRecords = result.records;
    diagLogDroppedCount = result.droppedCount;
    diagLogLastPulledAt = DateTime.now();
    // The ack write carries the gate byte, so a drain that acked anything is also a
    // confirmed push. Only then: performDrainDiagLog() breaks out of its loop BEFORE
    // _writeDiagLogControl() when a batch holds no records, and an empty ring is the
    // ordinary case on a routine connect — so treating every drain as confirmation
    // would mark the gate verified on no evidence at all, which is the exact failure
    // this field exists to remove.
    if (result.records.isNotEmpty) {
      diagLogGateOnDevice = SharedPreferencesUtil().diagLogEnabled;
      diagLogGatePushedAt = diagLogLastPulledAt;
    }
    for (final r in result.records) {
      await DebugLogManager.logEvent('device_diag_log', r.toJson());
    }
    if (result.droppedCount > 0) {
      Logger.warning(
        'Diag-log: ${result.records.length} records pulled, '
        '${result.droppedCount} lost to ring overflow while the app was away',
      );
    } else if (result.records.isNotEmpty) {
      Logger.debug('Diag-log: ${result.records.length} records pulled');
    }
    notifyListeners();
    return result.records.length;
  }

  /// Drain (acking everything on the device) and empty the on-screen viewer. Since
  /// [pullDiagLog] already acks each batch, this just does a final drain and clears
  /// the cached records.
  Future<void> clearDiagLog() async {
    await pullDiagLog();
    diagLogRecords = [];
    diagLogDroppedCount = 0;
    notifyListeners();
  }

  /// Returns whether the switch actually happened. False means the device went
  /// away between the toggle being tapped (which the UI gates on being
  /// connected) and the save — in which case NOTHING here ran, and the caller
  /// must not write the new mode's processing prefs either. Writing them anyway
  /// leaves the app cutting audio by manual's rules while `manualMode` still
  /// says auto and the Omi is still in auto — and with no switch recorded, no
  /// history entry is taken either, so the backlog is re-cut unprotected. That
  /// is the 2026-08-14 configuration exactly.
  Future<bool> setManualMode(bool enabled) async {
    if (connectedDevice == null) return false;
    final prefs = SharedPreferencesUtil();

    // DEVICE FIRST, and nothing local until it confirms. The threshold write is
    // the only step here that can fail, and it fails silently (see
    // _setDeviceVadThreshold) — so the old order committed the app to a mode the
    // Omi had never adopted. That divergence is not cosmetic: on the next connect
    // the read-and-adopt block in _onDeviceConnected takes the DEVICE's threshold
    // as the source of truth and flips `manualMode` straight back, while the
    // vad* prefs the settings page wrote on the way out stay put. The app is then
    // cutting audio by one mode's rules while believing it is in the other — the
    // 2026-08-14 configuration, reached without a single line of that bug.
    if (!await _setDeviceVadThreshold(enabled ? 32769 : prefs.autoVadThreshold)) {
      Logger.debug('DeviceProvider: manual-mode switch abandoned — the Omi did not take the threshold write.');
      return false;
    }

    // Everything below is local and cannot fail partway: the caller keys writing
    // the new mode's vad* prefs off our return value, so anything that unwound
    // after this point would reproduce exactly the split state above.
    //
    // Record the OUTGOING mode's processing settings, so the backlog recorded
    // under them is still cut by them. Read here and not in the settings page
    // because this runs BEFORE the page writes the new mode's vad* prefs —
    // ProcessingSettings.fromPrefs() still returns the old mode.
    //
    // Appended, never overwritten: switch twice before the backlog drains and the
    // audio holds two boundaries, each needing its own settings. The processing
    // run walks the entries oldest-first and gives every span the mode it was
    // actually recorded in.
    _recordModeSwitch(prefs);
    prefs.manualMode = enabled;
    // This is the user choosing, as opposed to the app adopting whatever an Omi
    // happened to hold. Only a choice makes a later disagreement worth reporting.
    prefs.manualModeUserSet = true;
    _manualRecording = false;
    // Their own choice is never a mismatch, and re-choosing is how you clear one.
    recordingModeMismatch = false;

    // Mode flipped — make the new mode's button mapping live on the device. Must
    // follow the prefs.manualMode write, which is what it reads to pick a config.
    // Best-effort by design (it is retried on the next connect), and guarded so a
    // BLE failure here cannot unwind past the commit above.
    try {
      await pushActiveButtonConfig();
    } catch (e) {
      Logger.error('DeviceProvider: button config push failed after the mode switch ($e) — '
          'retried on the next connect.');
    }
    notifyListeners();
    return true;
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

  /// [userInitiated] marks the entry points that represent fresh user intent —
  /// opening or resuming the app. Those drop the reconnect wait gate so the attempt
  /// happens now: the backoff exists to stop us churning at the daemon while nobody
  /// is watching, not to make a user who just opened the app wait out a 12-minute
  /// timer. It deliberately does NOT forgive the accumulated failure count — see
  /// [_allowOneImmediateReconnect]. Automatic callers (the post-disconnect retry)
  /// leave the gate armed.
  Future periodicConnect(String printer, {bool boundDeviceOnly = false, bool userInitiated = false}) async {
    if (userInitiated) _allowOneImmediateReconnect();
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

    // Outer backstop only, and the outermost link in a chain that MUST stay monotonic —
    // each guard has to sit above everything it contains, or the outer one fires first and
    // reports a connect that is still legitimately in progress as a failure:
    //
    //   native direct connect        40 s   DIRECT_CONNECT_TIMEOUT_MS
    //   native autoConnect           45 s   AUTO_CONNECT_TIMEOUT_MS
    //     + service discovery      + 15 s   DISCOVERY_TIMEOUT_MS (starts AFTER connect)
    //   = native worst case         ~60 s
    //   transport backstop           75 s   NativeBleTransport._kConnectBackstop
    //   THIS outer guard             90 s
    //   Dart connect-settle       ~150 s   _armConnectSettleWatchdog
    //   native connect-settle       160 s   CONNECT_SETTLE_MS
    //
    // This one exists solely so a wedged ensureConnection (e.g. the device mutex held by a
    // stuck caller) cannot hang the sync cycle forever. It has been wrong twice: 30 s with
    // a comment claiming it matched native, then 70 s after the transport moved to 75 s.
    // Check the whole column above when changing any single value.
    try {
      await connectFuture.timeout(const Duration(seconds: 90));
      final elapsed = DateTime.now().difference(t0).inMilliseconds;
      device = await _getConnectedDevice();
      // Log the OUTCOME, not the arrival. ensureConnection completing does not mean a usable
      // link exists: it resolved at 14:48:40Z on 2026-08-09 for a connection native had torn
      // down two seconds earlier, and the old unconditional 'device ready' line reported that
      // as a success immediately before returning null.
      if (device != null) {
        Logger.debug('[BLE] _scanConnectDevice: device ready after ${elapsed}ms');
        return device;
      }
      Logger.debug(
        '[BLE] _scanConnectDevice: connect resolved after ${elapsed}ms but no connection remains — '
        'native reported the attempt failed while we were waiting',
      );
    } catch (e) {
      Logger.debug(
        '[BLE] _scanConnectDevice: timed out/failed after ${DateTime.now().difference(t0).inMilliseconds}ms ($e)',
      );
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
      // Throttle the foreground reconnect loop during a real outage.
      //
      // Native stops its own fast retry loop after AUTONOMOUS_RETRY_STOP_AFTER (6)
      // failures and hands over to a backing-off recovery alarm (2→4→8→16 min) —
      // precisely because rapid connectGatt/closeGatt churn is the most common cause
      // of the Android Bluetooth daemon wedging. Dart never honoured that handoff:
      // periodicConnect's fixed 15 s timer plus the 30 s connect budget kept firing
      // an attempt every ~45 s, i.e. ~80/hour, for as long as the app stayed open.
      // BLE_Research.md Wedge 5 logged 12 attempts in 16 min into an already-dead
      // stack that way.
      //
      // _reconnectAt has always gated periodicConnect's scan() but was never
      // assigned, so the gate was dead code. Arm it here: the first few failures
      // retry promptly (a transient blip must still clear fast), then back off
      // 45 s → 90 s → 3 min → 6 min → 12 min, capped. Reset on any success.
      // Keyed on isConnected, not on the returned device: _scanConnectDevice() ends
      // by returning `connectedDevice`, which can be a stale non-null handle from an
      // earlier session even when this attempt failed. Treating that as success reset
      // the failure count every time, held the streak below the six-failure threshold
      // and meant the backoff never engaged at all — the daemon-churn protection this
      // exists for would have been silently inert.
      if (!isConnected) {
        _consecutiveConnectFailures++;
        if (_consecutiveConnectFailures >= _reconnectThrottleAfter) {
          final steps = _consecutiveConnectFailures - _reconnectThrottleAfter;
          final delay = Duration(seconds: (45 << steps.clamp(0, 4)).clamp(45, 720));
          _reconnectAt = DateTime.now().add(delay);
          Logger.debug(
            '[BLE] reconnect throttled: failure #$_consecutiveConnectFailures, '
            'next attempt in ${delay.inSeconds}s',
          );
        }
      } else {
        _resetReconnectThrottle();
      }
    } finally {
      updateConnectingStatus(false);
    }
  }

  /// Failures tolerated at the full 15 s cadence before the backoff engages.
  /// Matches native's AUTONOMOUS_RETRY_STOP_AFTER so Dart steps back at the same
  /// point native does, rather than hammering on past it.
  static const int _reconnectThrottleAfter = 6;
  int _consecutiveConnectFailures = 0;

  /// Clear the throttle so the next disconnect reconnects promptly. Called on any
  /// successful connect — including ones that arrive via native's own retry or the
  /// recovery alarm, not just through scanAndConnectToDevice. A connect is the only
  /// event that proves the link is healthy, so it is the only one that may zero the
  /// failure count.
  void _resetReconnectThrottle() {
    _consecutiveConnectFailures = 0;
    _reconnectAt = null;
  }

  /// Let one attempt through **now** without forgiving the outage.
  ///
  /// Reserved for `app open` — a real launch, once per process. It deliberately does
  /// NOT zero [_consecutiveConnectFailures]: that would buy another six fast attempts
  /// at the 15 s cadence, ~4.5 minutes of churn, every time it fired. Dropping only
  /// the wait gate gives the immediate attempt; if it fails, the backoff resumes from
  /// where the outage had already pushed it rather than restarting at the fast
  /// cadence.
  ///
  /// **Not called from the `resumed` lifecycle callback.** `resumed` is not a proxy
  /// for user intent: OnePlus and similar OEMs emit transient paused/resumed cycles
  /// for system overlays and the notification shade (which is why the resume scan is
  /// debounced at all — see [_resumeReconnectDebounce]). Bypassing the backoff on
  /// each of those blips would let a pulled-down notification panel restart the
  /// connectGatt/closeGatt burst this throttle exists to stop (BLE_Research.md,
  /// Wedge 5) — system events driving daemon churn with no user asking for anything.
  /// An explicit reconnect is already unthrottled by a different route: the sync
  /// page's buttons call [scanAndConnectToDevice] directly, which never consults
  /// [_reconnectAt].
  void _allowOneImmediateReconnect() {
    _reconnectAt = null;
  }

  void updateConnectingStatus(bool value) {
    isConnecting = value;
    // Refresh the one idle notification, which renders no connection state at all — so
    // this is a re-read of the last-sync prefs and the next-sync title, not a transient.
    // That is the point: the device connects only briefly at scheduled-sync time, and a
    // line that flipped to "Connecting…"/"Connected" on each of those blips is exactly
    // what used to strand. [isConnected] is still passed down because the battery clause
    // needs it; it is not rendered as text.
    //
    // Background-only, not because the notification goes away in the foreground — it is
    // persistent and survives resume — but because RecordingsController owns the line
    // while the user is in the app, and the link is shown there by the app-bar spinner.
    if (!_isAppInForeground && !_syncOwnsNotification) {
      unawaited(_showIdleNotification());
    }
    notifyListeners();
  }

  void setIsConnected(bool value) {
    isConnected = value;
    // Any route to "connected" clears the throttle, not just scanAndConnectToDevice's
    // own success path — a link that native's retry or the recovery alarm brought up
    // must not leave a stale _reconnectAt suppressing the next reconnect.
    if (isConnected) {
      _reconnectionTimer?.cancel();
      _resetReconnectThrottle();
    }
    notifyListeners();
  }

  void _startForegroundKeepAlive() {
    _foregroundKeepAliveTimer?.cancel();
    if ((!_isAppInForeground && !_backgroundSyncActive) || !isConnected || connectedDevice == null) return;
    _consecutiveKeepAliveFails = 0;
    _keepAliveEverSucceeded = false;
    _foregroundKeepAliveTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (!isConnected || connectedDevice == null) return;
      final conn = await ServiceManager.instance().device.ensureConnection(connectedDevice!.id);
      final ok = (conn != null) && (await conn.sendKeepAlive());
      if (ok) {
        _consecutiveKeepAliveFails = 0;
        _keepAliveEverSucceeded = true;
        return;
      }
      _consecutiveKeepAliveFails++;
      // During DFU the link is saturated with SMP packets, so a keep-alive
      // write to the storage characteristic can transiently time out. Keep
      // SENDING (the firmware resets its idle timer only on storage-char
      // activity), but never force-disconnect — that would abort an otherwise
      // healthy firmware update. The DFU layer owns connection health here.
      //
      // _keepAliveEverSucceeded is the other half of that: recycling rebuilds a
      // GATT, which is a remedy for a link that WAS carrying traffic and wedged.
      // A link whose keep-alive has never once landed has not come up yet, and
      // tearing it down is worse than waiting. The case that forced this is the
      // reconnect after a firmware update: the update wipes the bond by design, so
      // until a fresh pairing completes the app cannot write the storage
      // characteristic at all (BT_GATT_PERM_WRITE_ENCRYPT) and every keep-alive
      // fails — and the firmware now deliberately holds the link open through that
      // window (transport.c PAIRING_GRACE_MS). Recycling into it would undo, from
      // the phone side, exactly what the firmware is protecting. isFirmwareUpdate-
      // InProgress does not cover it: on success that flag clears when the user
      // taps Done, which is before the device has finished rebooting and pairing.
      if (_consecutiveKeepAliveFails >= 2 && _keepAliveEverSucceeded && !isFirmwareUpdateInProgress) {
        Logger.debug('KeepAlive: 2 consecutive failures on a link that was working, recycling to resync state');
        _consecutiveKeepAliveFails = 0;
        // Recycle (soft-disconnect → fresh GATT, device stays managed) rather than the
        // heavy disconnectDevice/unmanage path, which sets USER_DISCONNECTED, cancels
        // native background recovery, and can stop the foreground service.
        await ServiceManager.instance().device.recycleConnection();
      }
    });
  }

  void _stopForegroundKeepAlive() {
    _foregroundKeepAliveTimer?.cancel();
    _foregroundKeepAliveTimer = null;
    _consecutiveKeepAliveFails = 0;
    // Cleared with the counter: both describe one link, and a stale "this one was
    // working" carried into the next link would arm the recycle before anything had
    // proved it.
    _keepAliveEverSucceeded = false;
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
  /// auto-sync off (Manual Only) the service isn't pinned persistent, so this reaches
  /// native only while the service happens to still be running.
  Future<void> _showIdleNotification() async {
    await SyncNotification.idle(isConnected: isConnected);
  }

  void _pushBatteryToNative(int level) {
    if (!Platform.isAndroid) return;
    unawaited(BleHostApi().setDeviceBattery(level, DateTime.now().millisecondsSinceEpoch));
  }

  void restartBackgroundSyncTimer() => _startBackgroundSyncTimer();

  void _startBackgroundSyncTimer() {
    final interval = SharedPreferencesUtil().backgroundSyncIntervalMinutes;
    // Keep WorkManager in sync with the Dart timer interval so both fire on
    // the same schedule. WorkManager is the fallback when the process is alive
    // but the foreground service was killed by an OEM battery optimizer.
    //
    // Only here, not in _anchorAutoSyncSchedule: this is a registration keyed to the
    // INTERVAL, and re-registering it on every completed sync would be a binder call
    // per sync for no effect (ExistingPeriodicWorkPolicy.UPDATE keeps the already
    // scheduled run). The worker does not need re-anchoring anyway — it gates itself
    // on lastSyncCompletedMs, so it reads the new schedule the moment it is written.
    if (Platform.isAndroid) {
      unawaited(BleHostApi().rescheduleBackgroundSync(interval));
    }
    // Pin the single notification persistent while auto-sync is on and a device
    // is bound, so the idle "Next sync / Last Sync" line survives BLE disconnect
    // and app background. Manual Only / unbound releases it (connection-only
    // service lifetime — no idle notification, no redundant "Connected" line).
    final deviceBound = SharedPreferencesUtil().btDevice.id.isNotEmpty;
    unawaited(SyncNotification.setPersistent(interval > 0 && deviceBound));
    _anchorAutoSyncSchedule();
  }

  /// Tell the UI and the exact alarm when the next automatic sync is due — the two
  /// consumers that have to be *told* a due time rather than deriving one. `null`
  /// (or Manual Only) disarms the alarm.
  ///
  /// The third consumer, the WorkManager backstop, is absent on purpose: it derives the
  /// same answer from `lastSyncCompletedMs` when it fires, so it needs no push. This is
  /// the only place the two pushed consumers are written, so they cannot drift apart.
  void _publishNextSyncTime(DateTime? at) {
    nextSyncTime = at;
    if (Platform.isAndroid) unawaited(BleHostApi().setNextSyncTime(at?.millisecondsSinceEpoch ?? 0));
    notifyListeners();
  }

  /// Point every automatic trigger at "one full interval from now", and rebuild the
  /// Dart timer so its phase says the same thing.
  ///
  /// Called when the schedule is (re)configured and, via
  /// [SharedPreferencesUtil.lastSyncCompleted], whenever any sync completes — so the
  /// interval consistently means "since the last sync" rather than "since whenever the
  /// timer happened to be built". The three triggers cannot share one clock (the alarm
  /// is a one-shot the OS owns; WorkManager has a 15-minute floor and fires inexactly),
  /// so they agree on the due TIME instead: this method re-anchors the two that are
  /// scheduled ahead of time, and the WorkManager backstop derives the same answer from
  /// lastSyncCompletedMs when it fires.
  void _anchorAutoSyncSchedule() {
    _backgroundSyncTimer?.cancel();
    final interval = SharedPreferencesUtil().backgroundSyncIntervalMinutes;
    if (interval <= 0) {
      _publishNextSyncTime(null); // Manual only
      return;
    }
    _publishNextSyncTime(DateTime.now().add(Duration(minutes: interval)));

    _backgroundSyncTimer = Timer.periodic(Duration(minutes: interval), (_) async {
      if (_disposed) return;
      // Move the displayed time and the alarm forward at the START of the cycle, so a
      // long sync doesn't leave a due time sitting in the past. On success the
      // completion signal re-anchors everything again from the instant the sync
      // actually finished; on a skip this stands, which is what keeps a failed cycle
      // retrying on the normal cadence instead of a full interval after it gave up.
      _publishNextSyncTime(DateTime.now().add(Duration(minutes: interval)));

      if (!isConnected) {
        if (!isConnecting) {
          // Set the flag BEFORE the scan so _handleDeviceConnected's
          // background drop-guard knows this connection is a sanctioned
          // background sync and shouldn't be dropped.
          _pendingBackgroundSync = true;
          _armConnectSettleWatchdog();
          bool connectedThisTick = false;
          try {
            // ONE request per sync window. Native owns connect and retry — it runs its own
            // ladder (backoff 1.5→3→6→12→24 s over AUTONOMOUS_RETRY_STOP_AFTER attempts,
            // then the recovery alarm), and manageDevice preempts a waiting backoff so this
            // request is acted on immediately rather than queued behind it.
            //
            // This used to be a 3-attempt loop with 10 s gaps, which was a second retry
            // governor layered on the first: the two shared no state, so the real attempt
            // pattern was their product, and every iteration landed on native's guard while
            // native was already mid-ladder. Worse, now that manageDevice preempts, a loop
            // here would preempt the backoff on every iteration and pin the ladder near its
            // floor — restoring the connectGatt/closeGatt churn that c4ebcbde removed.
            await scanAndConnectToDevice();
            connectedThisTick = isConnected;
          } finally {
            // Clear in finally so a thrown scan (TimeoutException, GATT
            // errors, permission failure) doesn't leave the flag stuck true
            // and bypass the drop guard for future connections.
            if (!connectedThisTick) {
              _pendingBackgroundSync = false;
              // Connect failed: advance to the next auto-sync slot and record the Skip,
              // so the resting line stops asserting the previous outcome.
              _failSyncCycleToIdle();
            }
          }
          // If connectedThisTick, _finishDeviceSetup will clear the flag and
          // kick off _doBackgroundSync.
        }
      } else if (ServiceManager.instance().wal.getSyncs().hasDevice) {
        _doBackgroundSync();
      } else {
        // Link up, but the WAL layer has no device — either setup is still in flight
        // (it hands over the device last and starts the sync itself) or it never
        // finished. Calling _doBackgroundSync here reaches syncAll's `_device == null`
        // guard and skips, and no retry on this path can fix that because none of it
        // registers the device.
        //
        // So sanction the sync and take the connect path. If setup is running, the flag
        // is what it consumes on the way out. If the link is genuinely up,
        // scanAndConnectToDevice returns immediately and the flag simply waits for the
        // next connect — deliberately not forcing a teardown to provoke one, because
        // this branch is also the ordinary few seconds of setup and tearing down a
        // healthy link to fix a state that is about to fix itself is the worse trade.
        Logger.debug('[BLE] auto-sync tick: link is up but the WAL layer has no device '
            '(settingUp=${_currentlySettingUpId != null}) — deferring to the connect path');
        _pendingBackgroundSync = true;
        unawaited(_connectThenSyncOrFail());
      }
    });
  }

  /// Start a background sync that a pending intent sanctioned, and put the intent
  /// back if the cycle declines to run.
  ///
  /// The intent is consumed up front — the sync is about to start, and a second
  /// connect arriving mid-setup must not queue a duplicate. But [_doBackgroundSync]
  /// can return without doing anything, and the guard that bites here is
  /// `_backgroundSyncActive`: a cycle that failed and is still in its processing
  /// phase (the VAD isolate, which easily outlasts a ~8 s reconnect + setup) still
  /// holds it, so a sync adopted on the reconnect returns immediately having done
  /// nothing. Spending the intent on a call that never ran left the audio waiting
  /// for the next scheduled attempt.
  ///
  /// The flags are re-read rather than assigned back blindly: anything that set a
  /// fresh intent while this was in flight outranks the stale one being restored,
  /// and both flags mean "a sync is sanctioned", so OR is the correct merge.
  void _startSanctionedBackgroundSync() {
    final hadBackgroundSync = _pendingBackgroundSync;
    final hadSyncResume = _pendingSyncResume;
    _pendingBackgroundSync = false;
    _pendingSyncResume = false;
    unawaited(_doBackgroundSync().then((ran) {
      if (ran || _disposed) return;
      _pendingBackgroundSync = _pendingBackgroundSync || hadBackgroundSync;
      _pendingSyncResume = _pendingSyncResume || hadSyncResume;
      Logger.debug('[BLE] background sync declined to run — intent kept');
    }));
  }

  /// Run an intent that was restored while another cycle held the re-entrancy guard.
  ///
  /// Called from [_doBackgroundSync]'s finally, and only for a cycle that actually
  /// ran. Without it a restored intent has exactly one consumer — `_onDeviceConnected`
  /// — so it would sit untouched until the next connect: the link is deliberately
  /// held open while an intent is pending, so nothing would drop it and nothing would
  /// reconnect. It resolved eventually, by the firmware idle-dropping the link after
  /// ~60 s and native reconnecting into it, which is a slow and indirect way to
  /// achieve what the running cycle can hand over directly.
  ///
  /// Cannot recurse: the intent is cleared before the nested cycle starts and only a
  /// fresh connect sets it again, so that cycle's own hand-off finds nothing. A
  /// nested cycle that itself declines restores the intent but returns false, and a
  /// cycle that did not run does not hand off.
  void _runDeferredSyncIntent() {
    if (_disposed || _isAppInForeground || !isConnected) return;
    if (_backgroundSyncActive) return;
    if (!_pendingBackgroundSync && !_pendingSyncResume) return;
    Logger.debug('[BLE] running the sync intent deferred while the previous cycle finished');
    _startSanctionedBackgroundSync();
  }

  /// Runs one background sync+process cycle.
  ///
  /// Returns whether the cycle actually **ran**. False means it declined at one of
  /// the guards below and did nothing at all — which is not the same as running and
  /// failing. A run that reached [IWalSync.syncAll] returns true whatever the
  /// outcome, because a failure is still a cycle and has already recorded itself.
  ///
  /// The distinction exists for [_onDeviceConnected], which consumes
  /// `_pendingBackgroundSync` before calling this and has to know whether that
  /// intent was spent or thrown away. See the restore there.
  Future<bool> _doBackgroundSync() async {
    if (isFirmwareUpdateInProgress) return false;
    // Re-entrancy guard: set before any await so a second caller (e.g. the Dart
    // timer firing alongside the foreground heartbeat) bails out before touching
    // the shared wakelock. Cleared in the outer finally.
    if (_backgroundSyncActive) return false;
    _backgroundSyncActive = true;
    // Past every guard, so this is a cycle. The connect path may already have marked it
    // (a connect that then succeeded lands here); overwriting is correct — the marker
    // names the most recent cycle, and that is the one an orphan sweep should report.
    _markSyncCycleStarted();
    // Set only once every guard is passed, so the finally can tell a cycle that ran
    // from one that declined — see [_runDeferredSyncIntent].
    var ran = false;
    try {
      lastSyncError = null;
      final walSync = ServiceManager.instance().wal.getSyncs();
      if (walSync.isSyncing) {
        final cf = walSync.cancelFuture;
        if (cf != null) {
          await cf;
        } else {
          return false;
        }
      }
      if (RecordingsManager.isProcessingAny) return false;
      // The WAL layer is handed the device at the very END of _onDeviceConnected, so a
      // link can be up while a sync still cannot run. Guarded HERE rather than only at
      // the callers because there are six of them and the whole bug was one path that
      // did not check. Running anyway is not merely futile: syncAll returns null, the
      // cycle records a user-visible "Skipped", and its finally DISCONNECTS the device —
      // so a state that only setup can repair got a teardown once an hour instead
      // (observed 2026-08-31).
      //
      // Declining rather than recording a skip is deliberate: this is an internal
      // not-ready state, not "we tried and could not reach the Omi", and the scheduled
      // triggers already route to the connect path — which runs setup, the only thing
      // that fixes it — when they see the same condition.
      if (!walSync.hasDevice) {
        Logger.warning('DeviceProvider: background sync declined — the WAL layer has no device yet');
        return false;
      }

      try {
        WakelockPlus.enable();
        // Android: partial CPU wakelock. iOS: a beginBackgroundTask assertion so
        // the decode isn't suspended the instant the app backgrounds mid-run
        // (bounded window; longer decodes resume via the _draft pipeline). Both
        // are released in the finally below.
        if (Platform.isAndroid || Platform.isIOS) BleHostApi().acquireProcessingWakeLock();
        // Keep the firmware from idle-dropping the link mid-sync. Without this a
        // single long file read (large stitched/draft recordings) sends no command for
        // the firmware's idle window (transport.c IDLE_DISCONNECT_TIMEOUT_MS, 60 s) and
        // dies as "Stream closed without EOT", so that file never finishes. Belt and
        // braces now — the firmware also defers the idle check outright while a storage
        // transfer is active — but the keep-alive covers the gaps between reads, which
        // that exemption does not. _backgroundSyncActive is
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
          // null = the sync never ran (see IWalSync.syncAll). Recording it as a
          // completed sync is worse here than in the UI: BackgroundSyncWorker
          // gates its next run on lastSyncCompletedMs, so a phantom stamp tells
          // it "not due yet" and suppresses the next REAL attempt for a full
          // interval. Leave the stamp alone and flag the skip.
          final ran = result != null;
          SharedPreferencesUtil().lastSyncSkipped = !ran;
          if (ran) {
            SharedPreferencesUtil().lastSyncCompletedMs = DateTime.now().millisecondsSinceEpoch;
          } else {
            Logger.warning('DeviceProvider: background sync did not run — recording a skip, not a completion');
          }
          SharedPreferencesUtil().lastSyncStatusMs = DateTime.now().millisecondsSinceEpoch;
          await SyncNotification.finishingSync();
        } catch (e) {
          // A run that threw completed nothing, so it must NOT stamp
          // lastSyncCompletedMs — that is the same phantom stamp the `ran == false`
          // branch above refuses to write, and here it costs more than a wasted
          // cycle. All three triggers anchor on that pref, so stamping it pushed the
          // next attempt out a full interval AND (via `lastSyncSkipped = false`)
          // cleared the one flag that lets _handleDeviceConnected adopt a link it
          // gets back. Observed 2026-08-31: setup died at gatt_status_8, native had
          // the link back three seconds later, and the adoption path declined it
          // because this catch had just recorded a completion — six files waited
          // another hour. lastSyncStatusMs still carries the display clock, so the
          // notification reads "<outcome> • <now>" either way.
          //
          // Which outcome depends on whether we ever reached the device.
          // DeviceConnectionException is thrown at syncAll's entry (and the two
          // other no-connection guards) before a byte moves, so nothing was pulled
          // and the honest label is Skipped — which is also the retry gate
          // _shouldSyncNow() reads, so the next connect picks the sync straight back
          // up. Anything else (Cancelled, Phone Storage Full, gap-retry exhaustion)
          // did reach the device and may have landed files, so it is a Partial; not
          // stamping the completion is enough there, because the schedule it leaves
          // in place is the original one rather than an extended one.
          final neverReached = e is DeviceConnectionException;
          SharedPreferencesUtil().lastSyncPartial = !neverReached;
          SharedPreferencesUtil().lastSyncSkipped = neverReached;
          SharedPreferencesUtil().lastSyncStatusMs = DateTime.now().millisecondsSinceEpoch;
          // The cycle is over either way, so move the schedule's phase with it —
          // the pref write that used to do this incidentally is gone, and the alarm
          // is a one-shot that stops firing unless something re-arms it. Same call
          // and same reason as _failSyncCycleToIdle.
          _anchorAutoSyncSchedule();
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
        // connection. Even if segments remain there is no point holding the link,
        // because the keep-alive has stopped and the firmware idle-drops it within
        // ~60s (transport.c IDLE_DISCONNECT_TIMEOUT_MS) with nothing to reconnect it
        // in the background. Any leftover segments are picked up by the next
        // scheduled sync (or on app open/resume when one is due).
        //
        // The one exception is a sync that is already sanctioned and waiting to
        // start. This cycle's processing phase can outlast a reconnect — a failed
        // cycle drops the link, native brings it back seconds later, and
        // _handleDeviceConnected adopts it while this one is still decoding — so
        // "the cycle is over" is not the same as "nothing wants the link". Dropping
        // it here killed the link the adopted sync was about to use, and its
        // _doBackgroundSync then threw DeviceConnectionException for want of the
        // connection this line had just closed.
        final syncPending = _pendingBackgroundSync || _pendingSyncResume;
        if (!_isAppInForeground &&
            !isFirmwareUpdateInProgress &&
            !_isOnFirmwareUpdatePage &&
            !syncPending &&
            isConnected) {
          Logger.debug('Background sync done: disconnecting device.');
          ServiceManager.instance().device.disconnectDevice(isManual: true);
        }

        // The single notification persists across the disconnect and app
        // background — revert it to the idle "Next sync / Last Sync" line.
        unawaited(_showIdleNotification());
      }
      // Past every guard: this cycle ran. Whether it succeeded is a separate
      // question, already recorded in the prefs and lastSyncError above.
      ran = true;
      return true;
    } finally {
      _backgroundSyncActive = false;
      // The cycle is over, whatever the outcome — a `finally`, so a throw counts too.
      // Only process death can now leave the marker behind, which is exactly what the
      // startup sweep reads it for.
      _clearSyncCycleMarker();
      // Ordering matters: the guard is cleared first, so the handed-off cycle is not
      // turned away by the one handing it over.
      if (ran) _runDeferredSyncIntent();
    }
  }

  /// Arm the background-connect settle watchdog (see [_connectSettleWatchdog]).
  /// Idempotent — re-arming cancels any prior timer, so each new connect attempt resets
  /// the window.
  void _armConnectSettleWatchdog() {
    _connectSettleWatchdog?.cancel();
    _markSyncCycleStarted();
    _acquireConnectWakeLock();
    _connectSettleWatchdog = Timer(_connectSettleTimeout, () {
      _connectSettleWatchdog = null;
      // The connect window is over either way — drop the wake-lock now so it
      // can't outlive the attempt (give-up below releases it again, harmlessly).
      _releaseConnectWakeLock();
      // A connection arrived, or a sync/process is now running — the cycle is alive, so
      // it will end itself and must not be failed out from under.
      if (_disposed || isConnected || _backgroundSyncActive || _syncOwnsNotification) return;
      Logger.debug('DeviceProvider: connect watchdog fired — failing the cycle to idle');
      _failSyncCycleToIdle();
    });
  }

  /// Stamp "a background sync cycle is outstanding". Paired with
  /// [_clearSyncCycleMarker] on every terminal path; see
  /// [SharedPreferencesUtil.syncCycleStartedMs] for why liveness rather than a timeout
  /// is what makes an orphan detectable.
  void _markSyncCycleStarted() {
    SharedPreferencesUtil().syncCycleStartedMs = DateTime.now().millisecondsSinceEpoch;
  }

  void _clearSyncCycleMarker() {
    SharedPreferencesUtil().syncCycleStartedMs = 0;
  }

  /// The instant an orphaned cycle should be recorded at, or null when there is nothing
  /// to record. Extracted and pure because both halves are easy to get wrong in the
  /// direction of overwriting a real outcome with a fabricated one.
  ///
  /// Stamped at [startedMs], never at "now": the cycle failed when its process died,
  /// possibly hours earlier, and the notification's job is to say when. And it yields to
  /// any outcome already recorded at or after that instant — a foreground sync, or the
  /// alarm's own Dart-not-up skip — so the writers cannot fight over one cycle.
  @visibleForTesting
  static int? orphanedCycleStatusMs({required int startedMs, required int lastStatusMs}) {
    if (startedMs <= 0) return null;
    if (lastStatusMs >= startedMs) return null;
    return startedMs;
  }

  /// A cycle marked outstanding by a process that is gone can never finish, so record it
  /// as the skip it was. Runs once per process, from the constructor.
  ///
  /// Stamped at the marker's own time, not now: the cycle failed when the process died,
  /// which may have been hours ago, and "Last Sync: Skipped • 3:45 AM" is the true
  /// statement. Yields to any outcome already recorded at or after that instant — a
  /// foreground sync, or the alarm's own Dart-not-up skip — so the two writers cannot
  /// fight over the same cycle.
  void _sweepOrphanedSyncCycle() {
    final prefs = SharedPreferencesUtil();
    final started = prefs.syncCycleStartedMs;
    // Cleared whatever the verdict: a marker this process did not set can never become
    // valid, so leaving it would make the NEXT start re-report the same dead cycle.
    if (started > 0) prefs.syncCycleStartedMs = 0;
    final statusMs = orphanedCycleStatusMs(startedMs: started, lastStatusMs: prefs.lastSyncStatusMs);
    if (statusMs == null) return;
    Logger.debug('DeviceProvider: sync cycle started at $started never finished — recording it as a skip');
    prefs.lastSyncSkipped = true;
    prefs.lastSyncStatusMs = statusMs;
    // The resting line may already be on screen showing the outcome this replaces —
    // native's onCreate renders it from these same prefs, and on a headless start that
    // happens before main() gets here.
    unawaited(_showIdleNotification());
  }

  void _cancelConnectSettleWatchdog() {
    _connectSettleWatchdog?.cancel();
    _connectSettleWatchdog = null;
    _releaseConnectWakeLock();
  }

  /// Acquire/release the connect-phase CPU wake-lock. Reference-counted natively
  /// and guarded here so the pair stays balanced no matter which watchdog path
  /// fires. Android-only: iOS runs background work through BGProcessingTask rather than
  /// a wake-locked foreground service, and its acquireProcessingWakeLock
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
  /// [nextSyncTime] — record the Skip, and refresh the resting line so it reports
  /// this cycle rather than the last one that succeeded.
  void _failSyncCycleToIdle() {
    _cancelConnectSettleWatchdog();
    _clearSyncCycleMarker();
    // Anchor rather than just publish: a cycle that gave up is still a cycle, so the
    // Dart timer's phase has to move with the alarm. Publishing alone left them
    // disagreeing by however long the connect attempt took (~90 s), since only the
    // alarm was pushed — the timer went on firing from its original phase. Harmless in
    // itself (the early fire is a sync that is genuinely due) but it is exactly the
    // drift between triggers this rework exists to remove.
    _anchorAutoSyncSchedule();
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
    // onAppResumed cancels this. If a sync is still in flight when it fires it polls
    // until the sync is done and then starts a fresh full window, so for the
    // start-a-sync-then-background case the grace really does begin once the sync
    // finishes.
    _pauseGraceSawSync = false;
    _armPauseDisconnect();
  }

  /// Arm (or re-arm) the post-background disconnect. A method (not an inline
  /// closure) so the tick can re-arm itself while a sync is still running.
  void _armPauseDisconnect([Duration? delay]) {
    _pauseDisconnectTimer?.cancel();
    _pauseDisconnectTimer = Timer(delay ?? _backgroundDisconnectGrace, _onPauseDisconnectTick);
  }

  void _onPauseDisconnectTick() {
    if (_disposed || _isAppInForeground || !isConnected) return;
    if (isFirmwareUpdateInProgress || _isOnFirmwareUpdatePage) return;
    // A sync is actively using the BLE link — keep the connection (and the keep-alive)
    // alive until it finishes, then re-check on the short poll cadence. This is the
    // start-a-sync-then-background case. Local decode/VAD processing doesn't hold the
    // link, so it doesn't block the disconnect.
    //
    // There is deliberately no `await` between this check and the disconnectDevice()
    // below, and none may be added: Dart's single thread is the only thing making the
    // pair atomic, and a suspension point here would reopen the window for a sync to
    // start after the check and have its link pulled out from under it. (Same invariant
    // as the GATT-cache fingerprint's isSyncing/recycleConnection pair.)
    if (ServiceManager.instance().wal.getSyncs().isSyncing || _backgroundSyncActive) {
      _pauseGraceSawSync = true;
      _armPauseDisconnect(_backgroundDisconnectPoll);
      return;
    }
    // The sync this window was waiting on has just finished. Give the full grace from
    // HERE, so backgrounding during a sync earns the same quick-return window as
    // backgrounding while idle — rather than whatever fraction of it was left over.
    if (_pauseGraceSawSync) {
      _pauseGraceSawSync = false;
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
    _pauseGraceSawSync = false;
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
    // the transfer. Without the keep-alive the firmware's 60 s idle-disconnect
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
    // Static notifier, so this outlives the provider — a missed removal would keep a
    // disposed provider reachable and firing for the life of the process.
    SharedPreferencesUtil.lastSyncCompleted.removeListener(_onSyncCompleted);
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

  /// Fingerprint to persist alongside a GATT-cache recycle, set during setup by
  /// [_gattCacheRefreshFingerprint] and acted on once setup releases
  /// [_currentlySettingUpId]. Null = nothing to do.
  String? _pendingGattFingerprint;

  /// Whether the pending recycle is the one-time migration for a device that has
  /// no fingerprint yet, rather than an observed identity change.
  bool _pendingGattMigration = false;

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

    // Deferred until after the setup guard is released: recycling reconnects,
    // which re-enters _onDeviceConnected — and that early-returns while
    // _currentlySettingUpId still holds this id, so the fresh link would never
    // be set up.
    final fingerprint = _pendingGattFingerprint;
    final wasMigration = _pendingGattMigration;
    _pendingGattFingerprint = null;
    _pendingGattMigration = false;
    if (fingerprint != null) {
      // Re-check for a live transfer HERE rather than trusting the check made
      // during evaluation. The capability read released the storage mutex, and
      // setup itself may have started a background sync in between (it kicks one
      // off unawaited), so a sync can begin after the decision and before this
      // runs — and recycling would abort it mid-file.
      if (ServiceManager.instance().wal.getSyncs().isSyncing) {
        // Nothing has been persisted on this path, so the next connect
        // re-evaluates and retries. Deferred, not dropped.
        Logger.debug('DeviceProvider: GATT-cache refresh deferred — sync in flight');
      } else {
        Logger.warning(
          'DeviceProvider: ${wasMigration ? 'first fingerprint for this device' : 'firmware identity changed'}'
          ' — recycling the link to drop the stale GATT cache',
        );
        // NOTE: no `await` between the isSyncing check above and this call — Dart
        // is single-threaded, so with no suspension point in between nothing can
        // start a sync after the check and before the recycle commits. Do not add
        // one (including an awaited persist) without re-checking afterwards.
        final recycled = await ServiceManager.instance().device.recycleConnection();
        if (recycled) {
          // Record only now that a recycle really ran, so a refresh that doesn't
          // help still happens just once — while one that never started (another
          // recycle already in flight, or the link dropped first) leaves nothing
          // behind to suppress the retry on the next connect.
          await SharedPreferencesUtil().setGattFingerprint(device.id, fingerprint);
        } else {
          Logger.debug('DeviceProvider: GATT-cache refresh not started — retrying on the next connect');
        }
      }
    }
  }

  /// Reads the firmware-owned settings once per connect into the [deviceFeatures]
  /// group, from the idle window before the sync starts.
  ///
  /// Every read here fails soft: a null leaves the field UNREAD and the page that
  /// wants it reads for itself. That matters most for the capability bitfield —
  /// rendering a failed read as "no features" is the bug this whole cache exists
  /// to kill, so it must not be reintroduced by storing 0 for a failure.
  ///
  /// The per-setting reads are gated on the capability bits, exactly as the
  /// settings page gates them: asking a device for a characteristic it does not
  /// implement is a guaranteed failure and a wasted round trip.
  Future<void> _cacheDeviceSettings(String deviceId) async {
    final conn = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (conn == null) return;

    // getFeaturesIfIdle, not getFeatures: even here the storage lock can be held
    // (a resumed sync on a reconnect), and the guarded twin answers null instead
    // of 0 so "unread" stays distinguishable from "has nothing".
    final features = await conn.getFeaturesIfIdle();
    // Leave every field exactly as it was and let the pages fall back to their own
    // reads. On a reconnect that means the previous connection's values survive,
    // which is what we want: all of these are firmware-PERSISTED settings that only
    // this app writes (getLedBootEnabled deliberately reports the stored default,
    // not the volatile live gate the button toggles), so a last-known value is
    // still true. Contrast diagLogGateOnDevice, which resets on every connect
    // precisely because a reboot clears it.
    if (features == null) return;
    deviceFeatures = features;

    if (OmiFeatures.hasFeature(features, OmiFeatures.ledDimming)) {
      deviceLedDimRatio = await conn.getLedDimRatio();
    }
    if (OmiFeatures.hasFeature(features, OmiFeatures.micGain)) {
      deviceMicGain = await conn.getMicGain();
    }
    if (OmiFeatures.hasFeature(features, OmiFeatures.priorityRecordCap)) {
      devicePriorityRecordCap = await conn.getPriorityRecordCap();
    }
    if (OmiFeatures.hasFeature(features, OmiFeatures.ledService)) {
      deviceConnectedLed = await conn.getConnectedLed();
      deviceLedBootEnabled = await conn.getLedBootEnabled();
    }
    notifyListeners();
  }

  /// The fingerprint to persist if Android's cached GATT database for [deviceId]
  /// has to be dropped, or null to leave the cache alone.
  ///
  /// Deliberately neither persists nor recycles: both happen together at the
  /// deferred site in [_onDeviceConnected], which re-checks for a live transfer
  /// first. Persisting here would suppress a refresh that then got skipped.
  ///
  /// Android persists a bonded device's attribute database and answers service
  /// discovery out of it, so a firmware update that adds or moves attributes can
  /// leave the app working from a stale map: new services invisible, and any
  /// service whose handles shifted addressed at the wrong offsets. Recycling the
  /// connection is what fixes it — the native reconnect path closes the gatt, and
  /// closeGatt() calls the BluetoothGatt.refresh() reflection hook, so the new
  /// link rediscovers on air. Nothing extra is needed natively.
  ///
  /// Gated on identity rather than done on every connect, because a rediscovery
  /// costs a full reconnect and the layout can only move across a firmware flash.
  /// The fingerprint is the DIS firmware revision **and** the capability
  /// bitfield: the version alone misses a dev/production swap at the same
  /// version, and those differ in attribute count via CONFIG_OMI_DIAG_LOG.
  Future<String?> _gattCacheRefreshFingerprint(String deviceId) async {
    // iOS exposes no equivalent of refresh(); it relies on the peripheral's
    // Service Changed indication, which it honours far better than Android does.
    if (!Platform.isAndroid) return null;
    try {
      // Read by getDeviceInfo() moments earlier in _finishDeviceSetup. DIS sits
      // at statically-registered handles the firmware can never shift, so it is
      // trustworthy even when everything after it in the cache is stale.
      final fw = pairedDevice?.firmwareRevision;
      if (fw == null || fw.isEmpty) return null;

      // Served from the pre-sync cache rather than read here. This site used to
      // issue its own getFeaturesIfIdle AFTER the sync had started, so on the
      // ordinary background connect (a pending sync holding the storage lock) it
      // answered null and the refresh silently deferred every time. The cached
      // read happens in the idle window instead — same value, same null-means-
      // unread semantics, no second round trip.
      final features = deviceFeatures;
      // Unread (null) or a transient GATT error reading 0 rather than the real
      // flags — neither is a device that lost every capability, and neither may
      // trigger a recycle. Wait for the next connect.
      if (features == null || features == 0) return null;

      final fingerprint = '$fw|$features';
      final prefs = SharedPreferencesUtil();
      final stored = prefs.gattFingerprint(deviceId);
      if (stored == fingerprint) return null;

      if (stored.isEmpty) {
        // No fingerprint recorded for THIS device yet. It may predate
        // fingerprinting and already hold a stale cache from a flash that
        // happened before this code existed, so recording the identity without
        // refreshing would strand it — invisible new services until some
        // unrelated teardown clears the cache. Refresh once per device.
        //
        // This is deliberately per-device and NOT gated on a global one-shot: the
        // key expresses a per-device fact, so that a replacement unit still gets
        // its one refresh instead of being skipped by a flag the previous unit
        // consumed. Only one Omi is paired at a time, so this is about hardware
        // being swapped, not about two devices in use together.
        // The cost of being unable to tell "predates fingerprinting" from
        // "freshly paired, cache already clean" is one wasted reconnect per
        // device, once, which is far cheaper than stranding a device for good.
        _pendingGattMigration = true;
        return fingerprint;
      }

      Logger.debug('DeviceProvider: GATT fingerprint changed "$stored" -> "$fingerprint"');
      return fingerprint;
    } catch (e) {
      Logger.debug('DeviceProvider: GATT-cache fingerprint check failed: $e');
      return null;
    }
  }

  /// Records "this session's uptime U was at wall clock T" from a diagnostics read.
  ///
  /// Both halves come from the SAME read — [DeviceDropStats.deviceSessionId] and
  /// [DeviceDropStats.currentUptimeMs], stamped by [DeviceDropStats.readAt] — which is
  /// the whole reason the session id was added to the 0x0062 payload. Pairing an uptime
  /// with a session id learned from somewhere else (a synced bin filename, an earlier
  /// read) reintroduces the possibility that they describe different boots, and an
  /// anchor bound to the wrong boot re-files correct recordings to a wrong date, which
  /// is worse than not correcting at all.
  ///
  /// Fire-and-forget on purpose: this sits on the connect path, and persisting an
  /// anchor must never delay bringing the link up or block the sync behind it.
  void _captureClockAnchor(DeviceDropStats stats) {
    // 0 = firmware older than the 100-byte payload. The firmware never issues 0 as a
    // real id, so this is "cannot tell me which session it is in", not a session.
    if (stats.deviceSessionId == 0) return;

    // A phone whose own clock is unset would anchor every recording to 1970. The
    // threshold is the same pre-time-sync epoch the WAL layer uses to decide a device
    // timestamp is meaningless.
    final wallMs = stats.readAt.millisecondsSinceEpoch;
    if (wallMs < 946684800000) {
      Logger.debug('Clock anchor: skipped — phone clock reads before 2000');
      return;
    }

    final prefs = SharedPreferencesUtil();
    final anchor = DeviceClockAnchor(
      sessionId: stats.deviceSessionId,
      deviceUptimeMs: stats.currentUptimeMs,
      wallClockMs: wallMs,
    );
    final updated = DeviceClockAnchorSet.decode(prefs.deviceClockAnchors).upsert(anchor);
    prefs.deviceClockAnchors = updated.encode();
    Logger.debug('Clock anchor: $anchor (holding ${updated.anchors.length})');
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

    // MOVED UP, ahead of the sync kickoff below. performGetDeviceInfo fires five
    // plain DIS reads with no storage-lock guard, and it used to run three lines
    // AFTER `unawaited(_doBackgroundSync())` — i.e. straight into a live transfer
    // notify stream, the exact pattern performGetFeaturesIfIdle / ButtonConfigPage /
    // DeviceSettings are each hardened against because it drops the link on Android
    // (Error 133). Guarding the reads instead would be worse: a skipped DIS read
    // leaves no firmware revision, which both the Firmware row and the GATT-cache
    // fingerprint need. Reordering removes the race rather than detecting it.
    //
    // Conditional because setConnectedDevice() already ran getDeviceInfo() at the
    // top of _onDeviceConnected — five DIS reads — and DIS cannot change between
    // there and here. Re-reading unconditionally (which is what the old post-sync
    // call did) simply spent a second five round trips per connect. The retry is
    // still worth having: that first read happens on a link that has only just
    // come up, and a failed one leaves the revision empty, which would then
    // silently disable the GATT-cache fingerprint below.
    if ((pairedDevice?.firmwareRevision ?? '').isEmpty) {
      await getDeviceInfo();
    }
    SharedPreferencesUtil().deviceName = device.name;

    {
      final prefs = SharedPreferencesUtil();
      final conn = await ServiceManager.instance().device.ensureConnection(device.id);
      final thr = await conn?.getVadThreshold();
      deviceVadThreshold = thr;
      // Read-and-adopt: the firmware persists the threshold across reboot and
      // oo→oo OTA, so it is the source of truth. Reflect whatever it holds rather
      // than overwriting it with our remembered preference — pushing here would
      // stomp a change made on the device while it was offline (e.g. a button
      // start). Mode + auto sensitivity are only changed by an explicit in-app
      // action, which writes + persists at that moment.
      if (thr == 65535 || thr == 32769) {
        // Manual recording sentinels → manual mode; 65535 = recording, 32769 = standby.
        // The 32769 <-> 65535 move is the BUTTON's, and stays inside manual mode, so
        // the adopt below no-ops for it and only _manualRecording tracks it. That is
        // the case this whole read-and-adopt exists for.
        _adoptRecordingModeFromDevice(prefs, true);
        _manualRecording = thr == 65535;
      } else if (thr != null) {
        // A real auto-sensitivity value → auto mode.
        _adoptRecordingModeFromDevice(prefs, false);
        _manualRecording = false;
      }
      // thr == null (read failed) → leave the last-known state untouched.
      notifyListeners();
    }

    // Everything the settings pages render, read here and cached — see
    // [deviceFeatures]. This is the last moment on a connect where the link is
    // reliably idle: the sync starts a few lines below and holds the storage lock
    // for the rest of the session, after which every one of these reads is a
    // coin-flip. Failures leave their field null (UNREAD) and each page falls back
    // to reading for itself.
    await _cacheDeviceSettings(device.id);

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
      // No "Connected" transient: _startSanctionedBackgroundSync pushes "Syncing
      // recordings" within a beat, and the notification reports work, not link state.
      _startSanctionedBackgroundSync();
    }

    // Decide now (getDeviceInfo refreshed the firmware revision in the pre-sync
    // block above, and the capability bitfield was cached alongside it) but act
    // later — see the deferred block at the end of _onDeviceConnected. Safe to
    // leave here now that it reads nothing over BLE.
    _pendingGattFingerprint = await _gattCacheRefreshFingerprint(device.id);

    // Read crash diagnostics and store for Debug Tools display
    final conn = await ServiceManager.instance().device.ensureConnection(device.id);
    if (conn != null) {
      final log = await conn.getDiagnostics();
      // Why the last boot happened, for the version stamp below. Latched from
      // the reset itself, so it describes the boot we are talking to now — it is
      // read whether or not the reading is new, since the stamp is written on
      // every connect while `crashLogs` deliberately dedupes.
      final String? resetCause = log?.causeLabel;
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
          // Log once per NEW reading (deduped above), not on every connect. The
          // uptime here is the PREVIOUS session's runtime before the last reset,
          // not current uptime — so word it that way to avoid the "why is uptime
          // stuck at 44h?" confusion.
          if (log.isCrash) {
            Logger.warning(
              'Device diagnostics: CRASH — ${log.causeLabel}; prior boot ran ${log.uptimeStr} before this reset (not current uptime)',
            );
            await DebugLogManager.logEvent('device_crash', {
              ...log.toJson(),
              'cause_label': log.causeLabel,
              'prior_boot_run_label': log.uptimeStr,
            });
          } else {
            Logger.debug(
              'Device diagnostics: last reset = ${log.causeLabel}; prior boot ran ${log.uptimeStr} before it (not current uptime)',
            );
          }
        }
      }

      // Log the persisted BLE connect-failure counters on every connect so they land
      // in 'Save Diagnostic Logs to File'. The counts survive a reboot, so after
      // power-cycling to reconnect, this captures failures from before the reboot.
      // See NOTES.md "BLE: advertising but won't connect". getDropStats() self-skips
      // (returns null) while a sync holds the storage mutex — a GATT read racing the
      // storage stream throws Error 133 on Android — so the next connect logs it
      // instead. The skip is internal to the read, not a separate check-then-act here
      // that a sync could slip through between the check and the read.
      //
      // Logged whatever the values are, including all-zero. Counters that did not move
      // across an outage are the reading that acquits the peripheral — it never heard
      // the CONNECT_INDs — and are exactly as diagnostic as counters that did. Gating
      // on `> 0` made that case indistinguishable from a read that never happened.
      // The counters are cumulative across boots, so only their movement between two
      // consecutive lines means anything.
      final dropStats = await conn.getDropStats();
      if (dropStats != null) {
        // Opportunistic, and that word is load-bearing: getDropStats() returns null
        // while a sync holds the storage mutex, so this is NOT "on connect" — it is
        // "whenever a diagnostics read happens to get through". That is enough. An
        // anchor is not perishable (it describes a boot, and the boot does not change),
        // there is one on every connect that is not mid-sync, and a session that never
        // yields one simply keeps whatever timestamps the Omi assigned. Do not be
        // tempted to force the read through the mutex to guarantee an anchor: a GATT
        // read racing the storage notify stream throws Error 133 on Android and costs
        // the sync, which is a far worse trade than a missing correction.
        _captureClockAnchor(dropStats);

        if (dropStats.failedConnCount > 0 || dropStats.estabFailCount > 0) {
          Logger.warning(
            'Device BLE connect-fail counters: conn=${dropStats.failedConnCount} '
            'estab_0x3e=${dropStats.estabFailCount} '
            '(last failure during ${dropStats.lastFailedConnDuringSlowAdv ? "slow" : "fast"} advertising)',
          );
        }
        await DebugLogManager.logEvent('device_conn_fail', {
          'failed_conn_count': dropStats.failedConnCount,
          'estab_fail_count': dropStats.estabFailCount,
          'last_failure_adv_mode': dropStats.lastFailedConnDuringSlowAdv ? 'slow' : 'fast',
        });

        // SD-write drop counters + LIVE uptime (0x0062). These distinguish "audio was
        // dropped on-device" from "audio was never captured" — the exact fields a
        // vanished-recording post-mortem needs, previously read and discarded.
        // currentUptimeMs is the device's REAL current uptime (unlike the latched
        // prior-boot value from 0x0061 above). Counters are cumulative since boot, so
        // only movement between two readings means anything.
        final int liveUptimeS = dropStats.currentUptimeMs ~/ 1000;
        final String liveUptimeStr = '${liveUptimeS ~/ 3600}h ${(liveUptimeS % 3600) ~/ 60}m';
        final String dropMsg = 'Device SD-drop counters: blocks=${dropStats.blockDrops} '
            'streamFrames=${dropStats.streamFrameDrops} bootFrames=${dropStats.bootFrameDrops} '
            'codecFrames=${dropStats.codecFrameDrops} msgqPeak=${dropStats.msgqPeakDepth} '
            'writeFair=${dropStats.writeFairActivations} '
            // Ring stall pinpoint: slowest SD op + which op, and NAND write/sync errors.
            'ringMaxIo=${dropStats.ringMaxIoMs}ms(${dropStats.ringMaxIoOp}) ringIoErr=${dropStats.ringIoErrors} '
            'liveUptime=$liveUptimeStr';
        if (dropStats.hasAnyDrops) {
          Logger.warning('$dropMsg — on-device audio drops since boot');
        } else {
          Logger.debug(dropMsg);
        }
        await DebugLogManager.logEvent('device_drop_stats', {
          'block_drops': dropStats.blockDrops,
          'stream_frame_drops': dropStats.streamFrameDrops,
          'boot_frame_drops': dropStats.bootFrameDrops,
          'codec_frame_drops': dropStats.codecFrameDrops,
          'msgq_peak_depth': dropStats.msgqPeakDepth,
          'write_fair_activations': dropStats.writeFairActivations,
          'ring_max_io_ms': dropStats.ringMaxIoMs,
          'ring_max_io_op': dropStats.ringMaxIoOp,
          'ring_io_errors': dropStats.ringIoErrors,
          'sd_worker_stack_used': dropStats.sdWorkerStackUsed,
          'codec_stack_used': dropStats.codecStackUsed,
          'live_uptime_ms': dropStats.currentUptimeMs,
          // The advertising interval in force when this connect succeeded — advertising
          // stops once connected, so the value read here is the one that won the link.
          // Logged because it is the baseline half of the slow-advertising lead
          // (BLE_Research.md, Wedge 9): the outage half comes from the scan probe's packet
          // rate, and without a healthy-connect distribution to compare against there is
          // nothing to correlate it with. It was already parsed and shown on the Sync page
          // but never recorded, so it existed only if someone happened to look.
          'adv_active': dropStats.advActiveSlow ? 'slow' : 'fast',
          'adv_desired': dropStats.advDesiredSlow ? 'slow' : 'fast',
          // Mic liveness, from the same read. This is how long the mic has delivered
          // nothing, which is what puts the device into slow advertising in the first place:
          // manual standby parks the mic, and the park path requests the slow interval.
          // Logging it alongside makes the causal chain checkable from a single line.
          // Uses the getter, which does the u32-wrap-safe delta and returns null when the
          // firmware doesn't report it — a plain subtraction goes negative across the ~49.7
          // day wrap and reads as "the mic is alive", hiding a fault in the worst direction.
          'mic_silent_for_ms': dropStats.micSilentForMs,
          'vad_voiced_ms': dropStats.voicedMs,
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
            dropStats.emptyBinRotations > 0 ||
            dropStats.sessionEndMarkerEmits > 0 ||
            dropStats.markerPauseGateSaves > 0;
        if (priorityActivity) {
          // seEmits + pauseGateSaves confirm the pause-gate fix: a stop emits the
          // 0xFFFFFFFC (seEmits moves) and it's kept through the pause (pauseGateSaves
          // moves) rather than lost. emits flat = the firmware finalize path never
          // fired. pauseGateSaves is a rescue, so it is NOT a loss warning.
          final priorityMsg = 'Device priority-record counters: starts=${dropStats.priorityRecordStarts} '
              'stops=${dropStats.priorityRecordStops} markerDrops=${dropStats.markerWriteDrops} '
              'emptyBinRotations=${dropStats.emptyBinRotations} seEmits=${dropStats.sessionEndMarkerEmits} '
              'pauseGateSaves=${dropStats.markerPauseGateSaves}';
          // The empty-bin count deliberately does not raise this warning. An empty bin is
          // produced legitimately by any rotation that lands in a silent stretch: in auto
          // mode a quiet room forwards nothing to the SD worker at all (aad.c returns
          // early while !vad_is_recording), and the age-based rotation is only evaluated
          // when a write arrives — so a bin opened by an explicit rotate (Force Sync's
          // CMD_ROTATE_FILE, a priority-record boundary, a time sync) stays header-only
          // until speech resumes, and the next rotate closes it empty. Two Force Syncs
          // over a quiet lunch break are enough. Warning on that reports data loss where
          // there was no data, which is worse than silent: it sends an investigation
          // after a recording that never existed.
          //
          // markerWriteDrops is the signal, and an empty bin adds nothing to it: a
          // marker that is written force-drains its block immediately, so a bin can only
          // be header-only if nothing was written at all — which is silence, not loss.
          // The count is still reported above; firmware oo-3.0.2 and later say WHY each
          // one happened in the 0x0063 event log.
          if (dropStats.markerWriteDrops > 0) {
            Logger.warning('$priorityMsg — possible lost Priority Recording (marker write dropped on-device)');
          } else {
            Logger.debug(priorityMsg);
          }
          await DebugLogManager.logEvent('device_priority_stats', {
            'priority_starts': dropStats.priorityRecordStarts,
            'priority_stops': dropStats.priorityRecordStops,
            'marker_write_drops': dropStats.markerWriteDrops,
            'empty_bin_rotations': dropStats.emptyBinRotations,
            'session_end_marker_emits': dropStats.sessionEndMarkerEmits,
            'marker_pause_gate_saves': dropStats.markerPauseGateSaves,
          });
        }
      }

      // Firmware identity + reboot check, on every connect. Together with the
      // app_start line this is what makes a version change inferable from the
      // log alone: which firmware produced the surrounding lines, when it
      // changed, and — separately — when the device restarted. A DFU shows up as
      // both (and as a reboot ALONE when the revision string didn't move, e.g. a
      // same-version reflash that only re-sends the net core).
      //
      // dropStats is null while a sync holds the storage lock; the version is
      // still worth stamping, so only the uptime half drops out.
      final fw = pairedDevice?.firmwareRevision;
      if (fw != null && fw.isNotEmpty) {
        await DebugLogManager.logDeviceVersion(
          firmwareRevision: fw,
          hardwareRevision: pairedDevice?.hardwareRevision,
          modelNumber: pairedDevice?.modelNumber,
          uptimeMs: dropStats?.currentUptimeMs,
          resetCause: resetCause,
        );
      }

      // On-device diagnostic event log (dev tool): learn whether the firmware
      // advertises the capability (bit 12), push the runtime gate to match the local
      // pref, and — when enabled — drain the ring into the debug log + Debug Tools
      // viewer (acking as it goes). This connect handler fires _doBackgroundSync
      // unawaited above, so the capability read must serialize against the storage
      // stream (getFeaturesIfIdle self-skips → null) rather than race it into an
      // Android Error 133 like a plain getFeatures would. Null = a sync owns the lock;
      // leave the prior capability state and retry on the next idle connect. The drain
      // itself also self-skips on the same lock.
      //
      // The cache is deliberately NOT device-scoped: only one Omi is ever paired and
      // connected, so records can't be carried across a device switch and it isn't a
      // case worth holding code for.
      // Unknown until THIS connection confirms it, and reset before the feature read
      // rather than inside it: getFeaturesIfIdle() returns null whenever a sync holds
      // the storage lock, and a reset that lives in the success branch would let the
      // previous connection's belief survive — including a stale `true` after a reboot
      // has cleared the device's volatile gate.
      diagLogGateOnDevice = null;
      diagLogGatePushedAt = null;
      // From the pre-sync cache. Read here it was a second getFeaturesIfIdle on a
      // link the sync already held, so it answered null on the ordinary background
      // connect and left diagLogSupported at its previous value. The resets above
      // stay unconditional and stay ABOVE this line for the reason they always
      // did: a reset inside the success branch lets the previous connection's
      // belief survive, including a stale `true` after a reboot cleared the
      // device's volatile gate.
      final int? features = deviceFeatures;
      if (features != null) {
        diagLogSupported = (features & OmiFeatures.diagLog) != 0;
        if (diagLogSupported) {
          await pushDiagLogEnabled();
          if (SharedPreferencesUtil().diagLogEnabled) {
            await pullDiagLog();
          }
        } else {
          diagLogRecords = [];
          diagLogDroppedCount = 0;
        }
      }
    }

    notifyListeners();
    onDeviceConnected?.call(device);

    if (_pendingAppOpenSync) {
      _pendingAppOpenSync = false;
      unawaited(
        Future.delayed(const Duration(seconds: 10), () {
          if (!_disposed && isConnected) {
            unawaited(_doBackgroundSync().then((_) => _startBackgroundSyncTimer()));
          }
        }),
      );
    }
  }

  void _handleDeviceConnected(String deviceId) async {
    _consecutiveAccidentalDisconnects = 0;
    Logger.debug(
      '[BLE] _handleDeviceConnected: $deviceId (fg=$_isAppInForeground pendingBgSync=$_pendingBackgroundSync pendingResume=$_pendingSyncResume)',
    );
    try {
      var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
      if (connection == null) {
        Logger.warning(
          '[BLE] _handleDeviceConnected: ensureConnection returned null for $deviceId — state mismatch or device already disconnected',
        );
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
      final listing = await connection.listFiles();
      final files = listing?.files;
      final stats = await connection.getStorageFileStats();
      if (stats != null) {
        onStorageStatsUpdated(stats);
      } else if (files != null) {
        isDeviceStorageSupport = files.isNotEmpty;
        if (files.isNotEmpty) {
          final usedBytes = files.fold(0, (sum, f) => sum + f.size);
          const totalBytes = 480 * 1024 * 1024;
          storageFullPercentage = ((usedBytes / totalBytes) * 100).round().clamp(0, 100);
        } else {
          storageFullPercentage = 0;
        }
      }
      // else: neither read answered. Leave the last known values alone rather than
      // concluding "this device has no storage" from silence.

      // Also update the WAL sync's view of the world. An empty list here means
      // "register the device, skip the rebuild" (see setDevice), which is exactly
      // what a listing with no answer should do.
      await walSync.setDevice(dev, prefetchedFiles: files ?? const []);
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
        // The bonded id has to be in this set. `connectedDevice` and `pairedDevice` are
        // both assigned in setConnectedDevice, which only _onDeviceConnected calls — so
        // between a successful connect and the end of setup they are still null, and a
        // disconnect landing in that window matched nothing and was dropped on the floor.
        // `scanAndConnectToDevice` has already set isConnected = true by then, and nothing
        // else ever clears it, so the provider latched "connected" against a dead link
        // permanently: every sync path branches on isConnected, so none of them would
        // reconnect, and syncAll found no registered device and skipped. Observed
        // 2026-08-31 — a headless start connected, _handleDeviceConnected's drop-guard
        // dropped the link before setup, and the app sat believing it was connected for
        // seven hours until it was reopened.
        //
        // Safe as the widest of the three because there is exactly one Omi (CLAUDE.md,
        // "One Omi at a time"), and it is the same id `_scanConnectDevice` connects to.
        final knownId = SharedPreferencesUtil().btDevice.id;
        if (deviceId == connectedDevice?.id ||
            deviceId == pairedDevice?.id ||
            (knownId.isNotEmpty && deviceId == knownId)) {
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

  @override
  void onWalSyncedProgress(double percentage, {double? speedKBps, SyncPhase? phase}) {
    // In foreground the recordings_controller is the global WAL progress listener
    // and owns the notification — defer to it to avoid flip-flopping.
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) return;
    final now = DateTime.now();
    if (now.difference(_lastNotif) < const Duration(seconds: 1)) return;
    _lastNotif = now;
    // Read the WAL service's canonical counts — the exact same source the in-app
    // card reads — so the background notification can never disagree with the card.
    final syncs = ServiceManager.instance().wal.getSyncs();
    SyncNotification.syncing(RecordingsController.syncingNotificationText(syncs.syncedSegments, syncs.totalSegments));
  }
}
