import 'dart:async';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/devices/omi_connection.dart';
import 'package:omi/services/devices/storage_file.dart';
import 'package:omi/services/devices/transports/device_transport.dart';
import 'package:omi/services/devices/transports/native_ble_transport.dart';
import 'package:omi/utils/logger.dart';

// UUIDs
const String batteryServiceUuid = '0000180f-0000-1000-8000-00805f9b34fb';
const String batteryLevelCharacteristicUuid = '00002a19-0000-1000-8000-00805f9b34fb';

const String buttonServiceUuid = '23ba7924-0000-1000-7450-346eac492e92';
const String buttonTriggerCharacteristicUuid = '23ba7925-0000-1000-7450-346eac492e92';

const String settingsServiceUuid = '19b10010-e8f2-537e-4f6c-d104768a1214';
const String settingsDimRatioCharacteristicUuid = '19b10011-e8f2-537e-4f6c-d104768a1214';
const String settingsMicGainCharacteristicUuid = '19b10012-e8f2-537e-4f6c-d104768a1214';

const String featuresServiceUuid = '19b10020-e8f2-537e-4f6c-d104768a1214';
const String featuresCharacteristicUuid = '19b10021-e8f2-537e-4f6c-d104768a1214';
const String audioCodecCharacteristicUuid = '19b10022-e8f2-537e-4f6c-d104768a1214';

const String timeSyncServiceUuid = '19b10030-e8f2-537e-4f6c-d104768a1214';
const String timeSyncWriteCharacteristicUuid = '19b10031-e8f2-537e-4f6c-d104768a1214';

const String batteryDetailServiceUuid = '19b10050-e8f2-537e-4f6c-d104768a1214';
// 4-byte notify payload: [mv_lo, mv_hi, percentage (0-100), charging (0/1)]
const String batteryDetailCharacteristicUuid = '19b10051-e8f2-537e-4f6c-d104768a1214';

const String storageDataStreamServiceUuid = '30295780-4301-eabd-2904-2849adfeae43';
const String storageReadControlCharacteristicUuid = '30295782-4301-eabd-2904-2849adfeae43';
const String storageDataStreamCharacteristicUuid = '30295781-4301-eabd-2904-2849adfeae43';

const String disServiceUuid = '0000180a-0000-1000-8000-00805f9b34fb';
const String disModelNumberCharacteristicUuid = '00002a24-0000-1000-8000-00805f9b34fb';
const String disSerialNumberCharacteristicUuid = '00002a25-0000-1000-8000-00805f9b34fb';
const String disFirmwareRevisionCharacteristicUuid = '00002a26-0000-1000-8000-00805f9b34fb';
const String disHardwareRevisionCharacteristicUuid = '00002a27-0000-1000-8000-00805f9b34fb';
const String disManufacturerNameCharacteristicUuid = '00002a29-0000-1000-8000-00805f9b34fb';

class DeviceConnectionFactory {
  static DeviceConnection? create(BtDevice device) {
    DeviceTransport transport;
    transport = NativeBleTransport(device.id);
    return OmiDeviceConnection(device, transport);
  }
}

class DeviceConnectionException implements Exception {
  String cause;
  DeviceConnectionException(this.cause);
}

abstract class DeviceConnection {
  BtDevice device;
  DeviceTransport transport;

  DeviceConnectionState _connectionState = DeviceConnectionState.disconnected;

  DeviceConnectionState get status => _connectionState;

  DeviceConnectionState get connectionState => _connectionState;

  Function(String deviceId, DeviceConnectionState state)? _connectionStateChangedCallback;

  StreamSubscription<DeviceTransportState>? _transportStateSubscription;

  DeviceConnection(this.device, this.transport) {
    // Listen to transport state changes exactly like the original repo
    _transportStateSubscription = transport.connectionStateStream.listen((transportState) {
      final deviceState = _mapTransportStateToDeviceState(transportState);
      if (_connectionState != deviceState) {
        _connectionState = deviceState;
        _connectionStateChangedCallback?.call(device.id, _connectionState);
      }
    });
  }

  DeviceConnectionState _mapTransportStateToDeviceState(DeviceTransportState transportState) {
    switch (transportState) {
      case DeviceTransportState.connected:
        return DeviceConnectionState.connected;
      case DeviceTransportState.disconnected:
      case DeviceTransportState.connecting:
      case DeviceTransportState.disconnecting:
        return DeviceConnectionState.disconnected;
    }
  }

  Future<void> connect({
    void Function(String deviceId, DeviceConnectionState state)? onConnectionStateChanged,
  }) async {
    if (_connectionState == DeviceConnectionState.connected) {
      throw DeviceConnectionException("Connection already established, please disconnect before start new connection");
    }

    // Set callback for connection state changes
    _connectionStateChangedCallback = onConnectionStateChanged;

    try {
      // Use transport to connect
      await transport.connect();

      // Check connection
      await ping();

      // Update device info
      device = await getDeviceInfo(this);
    } catch (e) {
      throw DeviceConnectionException("Transport connection failed: ${e.toString()}");
    }
  }

  Future<void> disconnect() async {
    _connectionState = DeviceConnectionState.disconnected;
    if (_connectionStateChangedCallback != null) {
      _connectionStateChangedCallback!(device.id, _connectionState);
      _connectionStateChangedCallback = null;
    }

    await transport.disconnect();
    await _transportStateSubscription?.cancel();
    _transportStateSubscription = null;
  }

  Future<bool> isConnected() async {
    return _connectionState == DeviceConnectionState.connected;
  }

  /// Lightweight health check — returns true if the device is actually reachable.
  Future<bool> ping() => transport.ping();

  Future<int> retrieveBatteryLevel() async {
    if (await isConnected()) {
      return await performRetrieveBatteryLevel();
    }
    return -1;
  }

  Future<int> performRetrieveBatteryLevel();

  Future<bool> retrieveChargingState() async {
    if (await isConnected()) {
      return performRetrieveChargingState();
    }
    return false;
  }

  Future<bool> performRetrieveChargingState() async => false;


  Future<StreamSubscription<List<int>>?> getBleBatteryLevelListener({
    void Function(int)? onBatteryLevelChange,
    void Function(bool)? onChargingStateChange,
  }) async {
    if (await isConnected()) {
      return await performGetBleBatteryLevelListener(
        onBatteryLevelChange: onBatteryLevelChange,
        onChargingStateChange: onChargingStateChange,
      );
    }
    return null;
  }

  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener({
    void Function(int)? onBatteryLevelChange,
    void Function(bool)? onChargingStateChange,
  }) async {
    final stream = await transport.getCharacteristicStream(batteryServiceUuid, batteryLevelCharacteristicUuid);
    return stream.listen((value) {
      if (value.isNotEmpty && onBatteryLevelChange != null) {
        onBatteryLevelChange(value[0]);
      }
    });
  }


  Future<List<int>> getBleButtonState() async {
    if (await isConnected()) {
      Logger.debug('button state called');
      return await performGetButtonState();
    }
    Logger.debug('button state error');
    return Future.value(<int>[]);
  }

  Future<List<int>> performGetButtonState();

  Future<StreamSubscription<List<int>>?> getBleButtonListener({
    required void Function(List<int>) onButtonReceived,
  }) async {
    if (await isConnected()) {
      return await performGetBleButtonListener(onButtonReceived: onButtonReceived);
    }
    return null;
  }

  Future<StreamSubscription<List<int>>?> performGetBleButtonListener({
    required void Function(List<int>) onButtonReceived,
  }) async {
    return null;
  }

  Future<BleAudioCodec> getAudioCodec() async {
    if (await isConnected()) {
      return await performGetAudioCodec();
    }
    return BleAudioCodec.pcm8;
  }

  Future<BleAudioCodec> performGetAudioCodec();


  Future<List<int>> getStorageList() async {
    if (await isConnected()) {
      return await performGetStorageList();
    }
    return [];
  }

  Future<List<int>> performGetStorageList();

  Future<StreamSubscription<List<int>>?> getBleStorageBytesListener({
    required void Function(List<int>) onStorageBytesReceived,
    Function? onError,
    void Function()? onDone,
  }) async {
    if (await isConnected()) {
      return await performGetBleStorageBytesListener(
        onStorageBytesReceived: onStorageBytesReceived,
        onError: onError,
        onDone: onDone,
      );
    }
    return null;
  }

  Future<StreamSubscription<List<int>>?> performGetBleStorageBytesListener({
    required void Function(List<int>) onStorageBytesReceived,
    Function? onError,
    void Function()? onDone,
  }) async {
    final stream = await transport.getCharacteristicStream(storageDataStreamServiceUuid, storageDataStreamCharacteristicUuid);
    return stream.listen(
      onStorageBytesReceived,
      onError: onError,
      onDone: onDone,
    );
  }

  Future<bool> writeToStorage(int numFile, int command, int offset) async {
    if (await isConnected()) {
      return await performWriteToStorage(numFile, command, offset);
    }
    return false;
  }

  Future<bool> performWriteToStorage(int numFile, int command, int offset);

  /// Send CMD_LIST_FILES (0x10) and return the sorted file list.
  Future<List<StorageFile>> listFiles() async {
    if (await isConnected()) {
      return await performListFiles();
    }
    return [];
  }

  Future<List<StorageFile>> performListFiles() async => [];

  /// Send CMD_DELETE_FILE (0x12) for [fileIndex] and wait for PACKET_ACK.
  Future<bool> deleteFile(int fileIndex) async {
    if (await isConnected()) {
      return await performDeleteFile(fileIndex);
    }
    return false;
  }

  Future<bool> performDeleteFile(int fileIndex) async => false;

  /// Send CMD_STOP (0x03) to halt an in-progress BLE transfer on the firmware side.
  Future<bool> stopStorageSync() async {
    if (await isConnected()) {
      return await performStopStorageSync();
    }
    return false;
  }

  Future<bool> performStopStorageSync() async => false;

  /// Send CMD_ROTATE_FILE (0x13) and wait for PACKET_ACK (0x03, 0x00).
  /// The firmware only sends the ACK after the current file is fully closed
  /// and a new file is successfully opened — safe to call CMD_LIST_FILES immediately after.
  Future<bool> rotateFile() async {
    if (await isConnected()) {
      return await performRotateFile();
    }
    return false;
  }

  Future<bool> performRotateFile() async => false;

  /// Syncs the phone's current time to the device via BLE.
  Future<bool> syncDeviceTime() async {
    if (await isConnected()) {
      return await performSyncDeviceTime();
    }
    return false;
  }

  Future<bool> performSyncDeviceTime() async => false;

  // Feature support and Settings
  Future<int> getFeatures() async {
    if (await isConnected()) {
      return await performGetFeatures();
    }
    return 0;
  }

  Future<int> performGetFeatures() async => 0;

  Future<int?> getLedDimRatio() async {
    if (await isConnected()) {
      return await performGetLedDimRatio();
    }
    return null;
  }

  Future<int?> performGetLedDimRatio() async => null;

  Future<void> setLedDimRatio(int ratio) async {
    if (await isConnected()) {
      await performSetLedDimRatio(ratio);
    }
  }

  Future<void> performSetLedDimRatio(int ratio) async {}

  Future<int?> getMicGain() async {
    if (await isConnected()) {
      return await performGetMicGain();
    }
    return null;
  }

  Future<int?> performGetMicGain() async => null;

  Future<void> setMicGain(int gain) async {
    if (await isConnected()) {
      await performSetMicGain(gain);
    }
  }

  Future<void> performSetMicGain(int gain) async {}

  Future<void> unpair() async {
    if (await isConnected()) {
      await performUnpair();
    }
  }

  Future<void> performUnpair() async {
    await disconnect();
  }

  Future<BtDevice> getDeviceInfo(DeviceConnection? connection) async {
    return performGetDeviceInfo(connection);
  }

  Future<BtDevice> performGetDeviceInfo(DeviceConnection? connection);
}
