import 'dart:async';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/devices/omi_connection.dart';
import 'package:omi/services/devices/device_crash_log.dart';
import 'package:omi/services/devices/device_drop_stats.dart';
import 'package:omi/services/devices/diag_log_record.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'package:omi/services/devices/transports/device_transport.dart';
import 'package:omi/services/devices/transports/native_ble_transport.dart';

import 'errors.dart';

/// What CMD_LIST_FILES came back with.
///
/// [complete] is false when the device named more files than it delivered — the
/// entries present are valid and worth syncing, but they are not the whole card,
/// so the run that acts on them is a partial sync. The listing can span several
/// notifications (the device caps its list at 150 files, well past what one fits),
/// so a lost packet mid-listing is a real case on a busy link, and it is exactly
/// the case where a caller must not conclude it has seen everything.
typedef StorageListing = ({List<StorageFile> files, bool complete});

class DeviceConnectionFactory {
  static DeviceConnection? create(BtDevice device, {bool requiresBond = true}) {
    DeviceTransport transport = NativeBleTransport(device.id, requiresBond: requiresBond);
    return OmiDeviceConnection(device, transport);
  }
}

abstract class DeviceConnection {
  final BtDevice _device;
  final DeviceTransport transport;

  DeviceConnectionState _connectionState = DeviceConnectionState.disconnected;
  void Function(String deviceId, DeviceConnectionState state, {bool isManual})? _connectionStateChangedCallback;
  StreamSubscription<DeviceTransportState>? _transportStateSubscription;

  DeviceConnection(this._device, this.transport);

  BtDevice get device => _device;
  DeviceConnectionState get status => _connectionState;

  Future<void> connect({
    void Function(String deviceId, DeviceConnectionState state, {bool isManual})? onConnectionStateChanged,
    bool requiresBond = false,
  }) async {
    if (_connectionState == DeviceConnectionState.connected) {
      throw DeviceConnectionException("Connection already established, please disconnect before start new connection");
    }

    _connectionStateChangedCallback = onConnectionStateChanged;

    await _transportStateSubscription?.cancel();
    _transportStateSubscription = transport.connectionStateStream.listen((transportState) {
      final deviceState = _mapTransportStateToDeviceState(transportState);
      if (_connectionState != deviceState) {
        _connectionState = deviceState;
        _connectionStateChangedCallback?.call(device.id, _connectionState, isManual: false);
      }
    });

    try {
      await transport.connect(requiresBond: requiresBond);
    } catch (e) {
      _connectionState = DeviceConnectionState.disconnected;
      _connectionStateChangedCallback?.call(device.id, _connectionState, isManual: false);
      rethrow;
    }
  }

  Future<void> disconnect({bool isManual = true}) async {
    await transport.disconnect();
    _connectionState = DeviceConnectionState.disconnected;
    _connectionStateChangedCallback?.call(device.id, _connectionState, isManual: isManual);
  }

  Future<bool> isConnected() async {
    return _connectionState == DeviceConnectionState.connected;
  }

  Future<int> retrieveBatteryLevel() async {
    if (await isConnected()) return performRetrieveBatteryLevel();
    return -1;
  }

  Future<bool> retrieveChargingState() async {
    if (await isConnected()) return performRetrieveChargingState();
    return false;
  }

  /// Returns null if the device is disconnected or the read failed, so callers
  /// can tell "device says unmuted" apart from "couldn't read".
  Future<({bool muted, DateTime? since})?> getMuteState() async {
    if (await isConnected()) return performGetMuteState();
    return null;
  }

  /// Returns true only if the write was delivered (with-response ACK). False on
  /// a disconnect or write failure.
  Future<bool> setMute(bool muted) async {
    if (await isConnected()) return performSetMute(muted);
    return false;
  }

  Future<StreamSubscription<List<int>>?> getMuteListener({
    required void Function(bool muted, DateTime? since) onMuteChange,
  }) async {
    if (await isConnected()) return performGetMuteListener(onMuteChange: onMuteChange);
    return null;
  }

  Future<DeviceCrashLog?> getDiagnostics() async {
    if (await isConnected()) return performGetDiagnostics();
    return null;
  }

  Future<DeviceCrashLog?> performGetDiagnostics() async => null;

  Future<DeviceDropStats?> getDropStats() async {
    if (await isConnected()) return performGetDropStats();
    return null;
  }

  Future<DeviceDropStats?> performGetDropStats() async => null;

  /// Subscribe to live drop-counter notifications (0x0062). Firmware pushes
  /// these on a timer while subscribed, so the diagnostics view updates during
  /// an SD sync — unlike getDropStats(), whose read races the sync stream.
  /// [onClosed] fires when the underlying stream ends (e.g. a disconnect), so the
  /// caller can drop the dead subscription and re-establish one.
  Future<StreamSubscription<List<int>>?> getDropStatsListener({
    required void Function(DeviceDropStats stats) onDropStats,
    void Function()? onClosed,
  }) async {
    if (await isConnected()) return performGetDropStatsListener(onDropStats: onDropStats, onClosed: onClosed);
    return null;
  }

  Future<StreamSubscription<List<int>>?> performGetDropStatsListener({
    required void Function(DeviceDropStats stats) onDropStats,
    void Function()? onClosed,
  }) async =>
      null;

  /// Tear down the drop-counter subscription at the BLE layer (CCCD=0) so the
  /// firmware stops pushing notifications while the connection stays up.
  Future<void> unsubscribeDropStats() async {}

  /// Set the on-device diagnostic event log's runtime gate (0x0064 enable bit).
  /// Returns true when the write reached the device; false when it was skipped
  /// (a sync holds the storage lock), failed, or the firmware lacks the feature.
  Future<bool> setDiagLogEnabled(bool enable) async {
    if (await isConnected()) return performSetDiagLogEnabled(enable);
    return false;
  }

  Future<bool> performSetDiagLogEnabled(bool enable) async => false;

  /// Drain the on-device diagnostic event ring (0x0063), acking each batch so the
  /// device clears the records it sent. Returns null when not connected or the
  /// feature is unavailable; a non-null (possibly empty) result means the drain ran.
  ///
  /// [keepEnabled] is written as the runtime gate on every ack so draining never
  /// changes capture state as a side effect — pass the current pref so a Clear while
  /// the log is OFF doesn't silently re-enable on-device logging.
  Future<DiagLogDrainResult?> drainDiagLog({bool keepEnabled = true}) async {
    if (await isConnected()) return performDrainDiagLog(keepEnabled: keepEnabled);
    return null;
  }

  Future<DiagLogDrainResult?> performDrainDiagLog({bool keepEnabled = true}) async => null;

  /// `null` and `[]` mean different things, and callers that decide whether a sync
  /// RAN must not conflate them: `[]` is the device answering that it holds no
  /// files, `null` is no answer at all — the link was down, the listing timed out,
  /// or the reply was unusable. Reported as `[]`, a failed listing reads as an
  /// empty card, which the sync layer records as a completed sync: the UI says
  /// "nothing to sync" and `lastSyncCompletedMs` suppresses the next automatic
  /// attempt for a full interval, while the recordings sit on the device.
  ///
  /// Callers that only want "what is on the device right now" and have nothing
  /// riding on the difference say `?? const []` and keep the old behaviour.
  Future<StorageListing?> listFiles() async {
    if (await isConnected()) return performListFiles();
    return null;
  }

  Future<bool> deleteFile(StorageFile file) async {
    if (await isConnected()) return performDeleteFile(file, timestamp: file.timestamp);
    return false;
  }

  DeviceConnectionState _mapTransportStateToDeviceState(DeviceTransportState transportState) {
    switch (transportState) {
      case DeviceTransportState.connected:
        return DeviceConnectionState.connected;
      case DeviceTransportState.connecting:
        return DeviceConnectionState.connecting;
      case DeviceTransportState.disconnected:
      case DeviceTransportState.disconnecting:
        return DeviceConnectionState.disconnected;
    }
  }

  Future<void> requestBond() async {
    await transport.requestBond();
  }

  Future<void> unpair() async {
    await disconnect();
  }

  // ── Facade Methods for UI & Sync ──

  Future<bool> stopStorageSync() async {
    if (await isConnected()) return performStopStorageSync();
    return false;
  }

  /// Sends a zero-payload HEARTBEAT (0x32) write to the storage characteristic.
  /// Used as a foreground keep-alive to reset the firmware's idle-disconnect
  /// timer (oo-1.9.0+).  Returns true on a successful write, false on any
  /// failure (transient BLE error, dead connection, etc).  The caller uses
  /// repeated failures as a liveness signal — if the underlying BLE silently
  /// died while the app still thinks it's connected, the write will fail.
  Future<bool> sendKeepAlive() async {
    // An active storage operation (file transfer) keeps the BLE link busy.
    // Writing the keep-alive byte to the same characteristic during a transfer
    // races with the stream and times out (10 s), stalling the download. Skip
    // it: data flowing over the link is already proof the connection is alive.
    if (isStorageBusy) return true;
    if (await isConnected()) return performSendKeepAlive();
    return false;
  }

  Future<bool> performSendKeepAlive() async => false;

  /// Sends a command to the peripheral to wipe its native OS pairing keys.
  Future<bool> sendUnpairCommand() async => false;

  /// Sends a command to the peripheral to cold-reboot itself. The device ACKs
  /// then restarts, dropping the link; the native layer auto-reconnects once
  /// it re-advertises.
  Future<bool> sendRebootCommand() async => false;

  /// Sends a command to the peripheral to power itself off (ship mode). The
  /// device ACKs then shuts down; it stays off until a button press or charger
  /// wakes it, so no reconnect follows.
  Future<bool> sendShutdownCommand() async => false;

  Future<bool> rotateFile() async {
    if (await isConnected()) return performRotateFile();
    return false;
  }

  Future<bool> writeToStorage(int fileNum, int command, int offset, {int? timestamp}) async {
    if (await isConnected()) return performWriteToStorage(fileNum, command, offset, timestamp: timestamp);
    return false;
  }

  Future<int> getFeatures() async {
    if (await isConnected()) return performGetFeatures();
    return 0;
  }

  /// Read the capability bitfield (0x0021) serialized against storage commands, for
  /// callers that run concurrently with a sync. Returns null when a transfer holds
  /// the storage lock (retry when idle) or the read is unavailable — distinct from
  /// [getFeatures], which reads unconditionally and returns 0 on failure.
  Future<int?> getFeaturesIfIdle() async {
    if (await isConnected()) return performGetFeaturesIfIdle();
    return null;
  }

  Future<int?> performGetFeaturesIfIdle() async => null;

  /// Re-anchors the firmware clock by writing the current UTC epoch.
  /// Safe to call repeatedly — needed on every (re)connect because a native
  /// auto-reconnect after a firmware reboot bypasses [connect], so the device
  /// would otherwise keep a reset clock and mis-stamp new recordings.
  Future<bool> syncTime() async {
    if (await isConnected()) return performSyncDeviceTime();
    return false;
  }

  Future<void> setLedDimRatio(int ratio) async {
    if (await isConnected()) await performSetLedDimRatio(ratio);
  }

  Future<int?> getLedDimRatio() async {
    if (await isConnected()) return performGetLedDimRatio();
    return null;
  }

  /// Turns the solid-blue "connected to phone" LED indicator on/off. With it
  /// off the connection no longer drives the LED, so the recording / mute state
  /// shows through and an idle connected device stays dark.
  Future<void> setConnectedLed(bool enabled) async {
    if (await isConnected()) await performSetConnectedLed(enabled);
  }

  Future<bool?> getConnectedLed() async {
    if (await isConnected()) return performGetConnectedLed();
    return null;
  }

  /// Sets whether the Omi's LEDs come up enabled after a reboot. The write also
  /// applies to the current session, so the change is visible immediately.
  Future<void> setLedBootEnabled(bool enabled) async {
    if (await isConnected()) await performSetLedBootEnabled(enabled);
  }

  /// The stored boot default — not the live gate, which a button gesture can
  /// toggle for the session without changing what the device reboots into.
  Future<bool?> getLedBootEnabled() async {
    if (await isConnected()) return performGetLedBootEnabled();
    return null;
  }

  Future<void> setMicGain(int gain) async {
    if (await isConnected()) await performSetMicGain(gain);
  }

  Future<int?> getMicGain() async {
    if (await isConnected()) return performGetMicGain();
    return null;
  }

  Future<void> setButtonConfig(List<int> config) async {
    if (await isConnected()) await performSetButtonConfig(config);
  }

  Future<List<int>?> getButtonConfig() async {
    if (await isConnected()) return performGetButtonConfig();
    return null;
  }

  Future<void> setHapticConfig(List<int> config) async {
    if (await isConnected()) await performSetHapticConfig(config);
  }

  Future<List<int>?> getHapticConfig() async {
    if (await isConnected()) return performGetHapticConfig();
    return null;
  }

  Future<void> setVadThreshold(int threshold) async {
    if (await isConnected()) await performSetVadThreshold(threshold);
  }

  Future<int?> getVadThreshold() async {
    if (await isConnected()) return performGetVadThreshold();
    return null;
  }

  Future<void> setPriorityRecordCap(int minutes) async {
    if (await isConnected()) await performSetPriorityRecordCap(minutes);
  }

  Future<int?> getPriorityRecordCap() async {
    if (await isConnected()) return performGetPriorityRecordCap();
    return null;
  }

  Future<StreamSubscription<List<int>>?> getBleBatteryLevelListener({
    void Function(int)? onBatteryLevelChange,
    void Function(bool)? onChargingStateChange,
  }) async {
    if (await isConnected()) {
      return performGetBleBatteryLevelListener(
        onBatteryLevelChange: onBatteryLevelChange,
        onChargingStateChange: onChargingStateChange,
      );
    }
    return null;
  }

  Future<List<int>> getStorageList() async {
    if (await isConnected()) return performGetStorageList();
    return [];
  }

  Future<StorageFileStats?> getStorageFileStats() async {
    if (await isConnected()) return performGetStorageFileStats();
    return null;
  }

  // ── Abstract Implementation Hooks ──

  bool get isStorageBusy;
  Future<void> acquireStorageLock([String owner = 'unknown']);
  void releaseStorageLock();
  Future<Stream<List<int>>> getBleStorageBytesStream();
  Future<StorageFileStats?> performGetStorageFileStats();
  Future<BtDevice> performGetDeviceInfo(DeviceConnection? connection);

  Future<int> performRetrieveBatteryLevel();
  Future<bool> performRetrieveChargingState();
  Future<({bool muted, DateTime? since})?> performGetMuteState();
  Future<bool> performSetMute(bool muted);
  Future<StreamSubscription<List<int>>?> performGetMuteListener({
    required void Function(bool muted, DateTime? since) onMuteChange,
  });
  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener({
    void Function(int)? onBatteryLevelChange,
    void Function(bool)? onChargingStateChange,
  });
  Future<List<int>> performGetStorageList();
  Future<bool> performWriteToStorage(int numFile, int command, int offset, {int? timestamp});
  Future<int> performGetFeatures();
  Future<void> performSetLedDimRatio(int ratio);
  Future<int?> performGetLedDimRatio();
  Future<void> performSetConnectedLed(bool enabled);
  Future<bool?> performGetConnectedLed();
  Future<void> performSetLedBootEnabled(bool enabled);
  Future<bool?> performGetLedBootEnabled();
  Future<void> performSetMicGain(int gain);
  Future<int?> performGetMicGain();
  Future<void> performSetButtonConfig(List<int> config);
  Future<List<int>?> performGetButtonConfig();
  Future<void> performSetHapticConfig(List<int> config);
  Future<List<int>?> performGetHapticConfig();
  Future<void> performSetVadThreshold(int threshold);
  Future<int?> performGetVadThreshold();
  Future<void> performSetPriorityRecordCap(int minutes);
  Future<int?> performGetPriorityRecordCap();
  Future<bool> performSyncDeviceTime();
  Future<bool> performStopStorageSync();
  Future<bool> performRotateFile();
  Future<bool> performClearStorage();

  /// null = the device did not answer; an empty [StorageListing.files] = it
  /// answered and holds no files. See [listFiles] and [StorageListing].
  Future<StorageListing?> performListFiles();
  Future<bool> performDeleteFile(StorageFile file, {int? timestamp});
}
