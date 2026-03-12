import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/devices/omi_connection.dart';
import 'package:omi/services/devices/wifi_sync_error.dart';
import 'package:omi/services/devices/transports/device_transport.dart';
import 'package:omi/services/devices/transports/ble_transport.dart';
import 'package:omi/utils/logger.dart';

// UUIDs
const String batteryServiceUuid = '0000180f-0000-1000-8000-00805f9b34fb';
const String batteryLevelCharacteristicUuid = '00002a19-0000-1000-8000-00805f9b34fb';

const String audioServiceUuid = '19b10000-e8f2-537e-4f6c-d104768a1214';
const String audioCharacteristicFormatUuid = '19b10002-e8f2-537e-4f6c-d104768a1214';

const String omiServiceUuid = '19b10000-e8f2-537e-4f6c-d104768a1214';
const String audioDataStreamCharacteristicUuid = '19b10001-e8f2-537e-4f6c-d104768a1214';
const String audioCodecCharacteristicUuid = '19b10002-e8f2-537e-4f6c-d104768a1214';

const String buttonServiceUuid = '19b10010-e8f2-537e-4f6c-d104768a1214';
const String buttonTriggerCharacteristicUuid = '23ba7925-0000-1000-7450-346eac492e92';

const String settingsServiceUuid = '19b10010-e8f2-537e-4f6c-d104768a1214';
const String settingsDimRatioCharacteristicUuid = '19b10011-e8f2-537e-4f6c-d104768a1214';
const String settingsMicGainCharacteristicUuid = '19b10012-e8f2-537e-4f6c-d104768a1214';

const String featuresServiceUuid = '19b10020-e8f2-537e-4f6c-d104768a1214';
const String featuresCharacteristicUuid = '19b10021-e8f2-537e-4f6c-d104768a1214';

const String timeSyncServiceUuid = '19b10030-e8f2-537e-4f6c-d104768a1214';
const String timeSyncWriteCharacteristicUuid = '19b10031-e8f2-537e-4f6c-d104768a1214';

const String speakerDataStreamServiceUuid = '19b10040-e8f2-537e-4f6c-d104768a1214';
const String speakerDataStreamCharacteristicUuid = '19b10041-e8f2-537e-4f6c-d104768a1214';

const String storageDataStreamServiceUuid = '30295780-4301-eabd-2904-2849adfeae43';
const String storageReadControlCharacteristicUuid = '30295782-4301-eabd-2904-2849adfeae43';
const String storageDataStreamCharacteristicUuid = '30295781-4301-eabd-2904-2849adfeae43';
const String storageFullCharacteristicUuid = '30295784-4301-eabd-2904-2849adfeae43';
const String storageDataCharacteristicUuid = '30295781-4301-eabd-2904-2849adfeae43';

class DeviceConnectionFactory {
  static DeviceConnection? create(BtDevice device) {
    DeviceTransport transport;
    final bleDevice = BluetoothDevice.fromId(device.id);
    transport = BleTransport(bleDevice);
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

  DeviceConnection(this.device, this.transport) {
    transport.connectionStateStream.listen((state) {
      _connectionState = state == DeviceTransportState.connected
          ? DeviceConnectionState.connected
          : DeviceConnectionState.disconnected;
    });
  }

  Future<void> connect({
    void Function(String deviceId, DeviceConnectionState state)? onConnectionStateChanged,
  }) async {
    if (_connectionState == DeviceConnectionState.connected) {
      throw DeviceConnectionException("Connection already established, please disconnect before start new connection");
    }

    if (onConnectionStateChanged != null) {
      transport.connectionStateStream.listen((state) {
        onConnectionStateChanged(device.id, 
          state == DeviceTransportState.connected ? DeviceConnectionState.connected : DeviceConnectionState.disconnected);
      });
    }

    try {
      await transport.connect();
    } catch (e) {
      throw DeviceConnectionException("Connection failed: $e");
    }
  }

  Future<void> disconnect() async {
    try {
      await transport.disconnect();
    } catch (e) {
      throw DeviceConnectionException("Disconnect failed: $e");
    }
  }

  Future<bool> isConnected() async {
    return _connectionState == DeviceConnectionState.connected;
  }

  DeviceConnectionState get connectionState => _connectionState;
  DeviceConnectionState get status => _connectionState;

  Future<int> retrieveBatteryLevel() async {
    if (await isConnected()) {
      return await performRetrieveBatteryLevel();
    }
    return -1;
  }

  Future<int> performRetrieveBatteryLevel();

  Future<int> retrieveStorageFull() async {
    if (await isConnected()) {
      return await performRetrieveStorageFull();
    }
    return -1;
  }

  Future<int> performRetrieveStorageFull() async => -1;

  Future<StreamSubscription<List<int>>?> getBleBatteryLevelListener({
    void Function(int)? onBatteryLevelChange,
  }) async {
    if (await isConnected()) {
      return await performGetBleBatteryLevelListener(onBatteryLevelChange: onBatteryLevelChange);
    }
    return null;
  }

  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener({
    void Function(int)? onBatteryLevelChange,
  }) async {
    final stream = transport.getCharacteristicStream(batteryServiceUuid, batteryLevelCharacteristicUuid);
    return stream.listen((value) {
      if (value.isNotEmpty && onBatteryLevelChange != null) {
        onBatteryLevelChange(value[0]);
      }
    }) ;
  }

  Future<StreamSubscription<List<int>>?> getBleStorageFullListener({
    void Function(int)? onStorageFullChange,
  }) async {
    if (await isConnected()) {
      return await performGetBleStorageFullListener(onStorageFullChange: onStorageFullChange);
    }
    return null;
  }

  Future<StreamSubscription<List<int>>?> performGetBleStorageFullListener({
    void Function(int)? onStorageFullChange,
  }) async {
    return null;
  }

  Future<StreamSubscription<List<int>>?> getBleAudioBytesListener({
    required void Function(List<int>) onAudioBytesReceived,
  }) async {
    if (await isConnected()) {
      return await performGetBleAudioBytesListener(onAudioBytesReceived: onAudioBytesReceived);
    }
    return null;
  }

  Future<StreamSubscription<List<int>>?> performGetBleAudioBytesListener({
    required void Function(List<int>) onAudioBytesReceived,
  }) async {
    final stream = transport.getCharacteristicStream(omiServiceUuid, audioDataStreamCharacteristicUuid);
    return stream.listen(onAudioBytesReceived) ;
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

  Future<StreamSubscription<BleAudioCodec>?> getBleAudioCodecListener({
    required void Function(BleAudioCodec) onAudioCodecReceived,
  }) async {
    if (await isConnected()) {
      return await performGetBleAudioCodecListener(onAudioCodecReceived: onAudioCodecReceived);
    }
    return null;
  }

  Future<StreamSubscription<BleAudioCodec>?> performGetBleAudioCodecListener({
    required void Function(BleAudioCodec) onAudioCodecReceived,
  }) async {
    final stream = transport.getCharacteristicStream(audioServiceUuid, audioCharacteristicFormatUuid);
    return stream.map((value) => BleAudioCodec.values[value[0]]).listen(onAudioCodecReceived);
  }


  Future<List<int>> getStorageList() async {
    if (await isConnected()) {
      return await performGetStorageList();
    }
    return [];
  }

  Future<List<int>> performGetStorageList();

  Future<StreamSubscription<List<int>>?> getBleStorageBytesListener({
    required void Function(List<int>) onStorageBytesReceived,
  }) async {
    if (await isConnected()) {
      return await performGetBleStorageBytesListener(onStorageBytesReceived: onStorageBytesReceived);
    }
    return null;
  }

  Future<StreamSubscription<List<int>>?> performGetBleStorageBytesListener({
    required void Function(List<int>) onStorageBytesReceived,
  }) async {
    final stream = transport.getCharacteristicStream(storageDataStreamServiceUuid, storageDataCharacteristicUuid);
    return stream.listen(onStorageBytesReceived) ;
  }

  Future<bool> writeToStorage(int numFile, int command, int offset) async {
    if (await isConnected()) {
      return await performWriteToStorage(numFile, command, offset);
    }
    return false;
  }

  Future<bool> performWriteToStorage(int numFile, int command, int offset);

  Future<bool> playToSpeakerHaptic(int level) async {
    if (await isConnected()) {
      return await performPlayToSpeakerHaptic(level);
    }
    return false;
  }

  Future<bool> performPlayToSpeakerHaptic(int level);

  Future<bool> isWifiSyncSupported() async {
    if (await isConnected()) {
      return await performIsWifiSyncSupported();
    }
    return false;
  }

  Future<bool> performIsWifiSyncSupported() async => false;

  Future<WifiSyncError> setupWifiSync(String ssid, String password) async {
    if (await isConnected()) {
      return await performSetupWifiSync(ssid, password);
    }
    return WifiSyncError(success: false, errorCode: 1);
  }

  Future<WifiSyncError> performSetupWifiSync(String ssid, String password) async {
    return WifiSyncError(success: false, errorCode: 1);
  }

  Future<void> clearWifiSync() async {
    if (await isConnected()) {
      await performClearWifiSync();
    }
  }

  Future<void> performClearWifiSync() async {}

  Future<int?> getWifiSyncStatus() async {
    if (await isConnected()) {
      return await performGetWifiSyncStatus();
    }
    return null;
  }

  Future<int?> performGetWifiSyncStatus() async {
    return null;
  }

  Future<StreamSubscription<int>?> getWifiSyncStatusListener({
    required void Function(int status) onStatusReceived,
  }) async {
    if (await isConnected()) {
      return await performGetWifiSyncStatusListener(onStatusReceived: onStatusReceived);
    }
    return null;
  }

  Future<StreamSubscription<int>?> performGetWifiSyncStatusListener({
    required void Function(int status) onStatusReceived,
  }) async {
    return null;
  }

  Future<bool> startWifiSync() async {
    if (await isConnected()) {
      return await performStartWifiSync();
    }
    return false;
  }

  Future<bool> performStartWifiSync() async => false;

  Future<bool> stopWifiSync() async {
    if (await isConnected()) {
      return await performStopWifiSync();
    }
    return false;
  }

  Future<bool> performStopWifiSync() async => false;

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
