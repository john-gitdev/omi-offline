import 'dart:async';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/discovery/bluetooth_discoverer.dart';
import 'package:omi/utils/logger.dart';

enum DeviceConnectionState {
  connected,
  disconnected,
}

abstract interface class IDeviceService {
  void start();
  Future stop();

  void subscribe(IDeviceServiceSubsciption subscription, Object context);
  void unsubscribe(Object context);

  Future<List<BtDevice>> discover({String? desirableDeviceId});
  Future<DeviceConnection?> ensureConnection(String deviceId, {bool force = false});

  // Connection management
  DeviceConnection? get connection;
  Stream<DeviceConnectionState> get connectionStateStream;

  // WiFi sync support
  bool get isWifiSyncInProgress;
  void setWifiSyncInProgress(bool value);
  Future<void> disconnectDevice();

  DeviceServiceStatus get status;
  DeviceConnectionState get connectionState;
  BtDevice? get pairedDevice;
}

enum DeviceServiceStatus {
  init,
  ready,
  stop,
}

abstract interface class IDeviceServiceSubsciption {
  void onDevices(List<BtDevice> devices);
  void onStatusChanged(DeviceServiceStatus status);
  void onDeviceConnectionStateChanged(String deviceId, DeviceConnectionState state);
}

class DeviceService implements IDeviceService {
  final Map<Object, IDeviceServiceSubsciption> _subscriptions = {};
  DeviceServiceStatus _serviceStatus = DeviceServiceStatus.init;

  DeviceConnection? _connection;
  bool _isWifiSyncInProgress = false;

  @override
  DeviceConnection? get connection => _connection;

  @override
  bool get isWifiSyncInProgress => _isWifiSyncInProgress;

  @override
  DeviceServiceStatus get status => _serviceStatus;

  @override
  DeviceConnectionState get connectionState => _connection?.status ?? DeviceConnectionState.disconnected;

  @override
  BtDevice? get pairedDevice => _connection?.device;

  @override
  void start() {
    _serviceStatus = DeviceServiceStatus.ready;
    _onStatusChanged(_serviceStatus);
  }

  @override
  Future stop() async {
    await disconnectDevice();
    _serviceStatus = DeviceServiceStatus.stop;
    _onStatusChanged(_serviceStatus);
    _subscriptions.clear();
  }

  @override
  void subscribe(IDeviceServiceSubsciption subscription, Object context) {
    _subscriptions[context.hashCode] = subscription;
    subscription.onStatusChanged(_serviceStatus);
  }

  @override
  void unsubscribe(Object context) {
    _subscriptions.remove(context.hashCode);
  }

  @override
  Future<List<BtDevice>> discover({String? desirableDeviceId}) async {
    final discoverer = BluetoothDeviceDiscoverer();
    final result = await discoverer.discover();
    final devices = result.devices;
    
    // If we were looking for a specific device and found it, we can stop early
    if (desirableDeviceId != null && devices.any((d) => d.id == desirableDeviceId)) {
       Logger.debug('DeviceService: Found desirable device $desirableDeviceId');
    }

    for (var s in _subscriptions.values) {
      s.onDevices(devices);
    }
    
    return devices;
  }

  @override
  Future<DeviceConnection?> ensureConnection(String deviceId, {bool force = false}) async {
    final currentConnection = _connection;
    if (currentConnection != null && currentConnection.device.id == deviceId && !force) {
      return currentConnection;
    }

    final existingConnection = _connection;
    if (existingConnection != null) {
      await existingConnection.disconnect();
    }

    final device = BtDevice(id: deviceId, name: 'Omi', type: DeviceType.omi, rssi: 0);
    _connection = DeviceConnectionFactory.create(device);

    final newConnection = _connection;
    if (newConnection != null) {
      await newConnection.connect(onConnectionStateChanged: (id, state) {
        for (var s in _subscriptions.values) {
          s.onDeviceConnectionStateChanged(id, state);
        }
      });
    }

    return _connection;
  }

  @override
  Stream<DeviceConnectionState> get connectionStateStream {
    return Stream.value(connectionState);
  }

  @override
  void setWifiSyncInProgress(bool value) {
    _isWifiSyncInProgress = value;
  }

  @override
  Future<void> disconnectDevice() async {
    final currentConnection = _connection;
    if (currentConnection != null) {
      await currentConnection.disconnect();
      _connection = null;
    }
  }

  void _onStatusChanged(DeviceServiceStatus status) {
    for (var s in _subscriptions.values) {
      s.onStatusChanged(status);
    }
  }
}
