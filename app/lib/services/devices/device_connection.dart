import 'dart:async';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/devices/omi_connection.dart';
import 'package:omi/services/devices/device_crash_log.dart';
import 'package:omi/services/devices/device_drop_stats.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'package:omi/services/devices/transports/device_transport.dart';
import 'package:omi/services/devices/transports/native_ble_transport.dart';

import 'errors.dart';

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

  /// See [DeviceTransport.gattConnectFuture].
  Future<void>? get gattConnectFuture => transport.gattConnectFuture;

  Future<int> retrieveBatteryLevel() async {
    if (await isConnected()) return performRetrieveBatteryLevel();
    return -1;
  }

  Future<bool> retrieveChargingState() async {
    if (await isConnected()) return performRetrieveChargingState();
    return false;
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

  Future<List<StorageFile>> listFiles() async {
    if (await isConnected()) return performListFiles();
    return [];
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

  Future<BleAudioCodec?> getAudioCodec() async {
    if (await isConnected()) return performGetAudioCodec();
    return null;
  }

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

  Future<void> setMicGain(int gain) async {
    if (await isConnected()) await performSetMicGain(gain);
  }

  Future<int?> getMicGain() async {
    if (await isConnected()) return performGetMicGain();
    return null;
  }

  Future<void> setVadThreshold(int threshold) async {
    if (await isConnected()) await performSetVadThreshold(threshold);
  }

  Future<int?> getVadThreshold() async {
    if (await isConnected()) return performGetVadThreshold();
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

  Future<StreamSubscription<List<int>>?> getBleButtonListener(
      {required void Function(List<int>) onButtonReceived}) async {
    if (await isConnected()) return performGetBleButtonListener(onButtonReceived: onButtonReceived);
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
  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener({
    void Function(int)? onBatteryLevelChange,
    void Function(bool)? onChargingStateChange,
  });
  Future<List<int>> performGetButtonState();
  Future<BleAudioCodec> performGetAudioCodec();
  Future<StreamSubscription<List<int>>?> performGetBleButtonListener(
      {required void Function(List<int>) onButtonReceived});
  Future<List<int>> performGetStorageList();
  Future<bool> performWriteToStorage(int numFile, int command, int offset, {int? timestamp});
  Future<int> performGetFeatures();
  Future<void> performSetLedDimRatio(int ratio);
  Future<int?> performGetLedDimRatio();
  Future<void> performSetMicGain(int gain);
  Future<int?> performGetMicGain();
  Future<void> performSetVadThreshold(int threshold);
  Future<int?> performGetVadThreshold();
  Future<bool> performSyncDeviceTime();
  Future<bool> performStopStorageSync();
  Future<bool> performRotateFile();
  Future<bool> performClearStorage();
  Future<List<StorageFile>> performListFiles();
  Future<bool> performDeleteFile(StorageFile file, {int? timestamp});
}
