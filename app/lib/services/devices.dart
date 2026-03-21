import 'dart:async';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/discovery/bluetooth_discoverer.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/services/devices/discovery/device_discoverer.dart';

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

  // WiFi sync disabled.
  // bool get isWifiSyncInProgress;
  // void setWifiSyncInProgress(bool value);
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
  final Map<int, IDeviceServiceSubsciption> _subscriptions = {};
  DeviceServiceStatus _serviceStatus = DeviceServiceStatus.init;

  DeviceConnection? _connection;
  // bool _isWifiSyncInProgress = false; // WiFi sync disabled
  // Tracks the active BLE scan so concurrent calls to discover() can cancel the
  // prior scan before starting a new one. Without this, two scans would run in
  // parallel, and most BLE stacks silently fail or throw on concurrent scans.
  DeviceDiscoverer? _activeDiscoverer;
  // Mutex for ensureConnection(): non-forced callers wait for the in-progress
  // connection attempt instead of spawning a parallel one.  Multiple concurrent
  // callers (battery read, storage read, WAL sync, etc.) all racing into
  // ensureConnection() would each create a separate DeviceConnection/BleTransport
  // and call discoverServices() concurrently — causing the phantom-connection log spam.
  Future<DeviceConnection?>? _pendingConnection;

  @override
  DeviceConnection? get connection => _connection;

  // @override
  // bool get isWifiSyncInProgress => _isWifiSyncInProgress; // WiFi sync disabled

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
    _subscriptions[identityHashCode(context)] = subscription;
    subscription.onStatusChanged(_serviceStatus);
  }

  @override
  void unsubscribe(Object context) {
    _subscriptions.remove(identityHashCode(context));
  }

  @override
  Future<List<BtDevice>> discover({String? desirableDeviceId}) async {
    // Cancel any in-progress scan before starting a new one. Most BLE stacks
    // do not support concurrent scans and will throw or silently return empty.
    final previous = _activeDiscoverer;
    if (previous != null) {
      Logger.debug('DeviceService: Cancelling previous scan before starting new one');
      await previous.stop();
      _activeDiscoverer = null;
    }

    final discoverer = BluetoothDeviceDiscoverer();
    _activeDiscoverer = discoverer;

    try {
      final result = await discoverer.discover();
      final devices = result.devices;

      if (desirableDeviceId != null && devices.any((d) => d.id == desirableDeviceId)) {
        Logger.debug('DeviceService: Found desirable device $desirableDeviceId');
      }

      for (var s in _subscriptions.values) {
        s.onDevices(devices);
      }

      return devices;
    } finally {
      // Clear the reference once the scan completes (or fails), so a subsequent
      // page pop / dispose doesn't call stop() on an already-finished scan.
      if (_activeDiscoverer == discoverer) _activeDiscoverer = null;
    }
  }

  @override
  Future<DeviceConnection?> ensureConnection(String deviceId, {bool force = false}) async {
    // Fast path: already have a live connection to the right device.
    final currentConnection = _connection;
    if (currentConnection != null && currentConnection.device.id == deviceId && !force) {
      return currentConnection;
    }

    // Serialize: if a connection attempt is already running and this isn't a
    // force call, wait for it to finish and return whatever it produced.
    // Without this, N callers (battery, storage, WAL sync …) all race in,
    // each creates its own DeviceConnection/BleTransport, and every one of
    // them calls discoverServices() simultaneously → the phantom-connect storm.
    if (!force) {
      final pending = _pendingConnection;
      if (pending != null) {
        Logger.debug('DeviceService: ensureConnection waiting for in-progress attempt');
        return await pending;
      }
    }

    final future = _performConnect(deviceId);
    _pendingConnection = future;
    try {
      return await future;
    } finally {
      if (identical(_pendingConnection, future)) _pendingConnection = null;
    }
  }

  Future<DeviceConnection?> _performConnect(String deviceId) async {
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

  // @override
  // void setWifiSyncInProgress(bool value) { // WiFi sync disabled
  //   _isWifiSyncInProgress = value;
  // }

  /// Lightweight health check on the current connection.
  Future<bool> ping() async {
    final conn = _connection;
    if (conn == null) return false;
    return conn.ping();
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
