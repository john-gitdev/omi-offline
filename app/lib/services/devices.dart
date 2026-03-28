import 'dart:async';
import 'package:collection/collection.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/services/devices/discovery/native_bluetooth_discoverer.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/mutex.dart';
import 'package:omi/services/devices/discovery/device_discoverer.dart';

enum DeviceConnectionState {
  connected,
  connecting,
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

  final StreamController<DeviceConnectionState> _connectionStateController =
      StreamController<DeviceConnectionState>.broadcast();

  DeviceConnection? _connection;
  List<BtDevice> _devices = [];
  DeviceDiscoverer? _activeDiscoverer;

  DateTime? _firstConnectedAt;
  final Mutex _mutex = Mutex();

  @override
  DeviceConnection? get connection => _connection;

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
    final previous = _activeDiscoverer;
    if (previous != null) {
      Logger.debug('DeviceService: Cancelling previous scan before starting new one');
      await previous.stop();
      _activeDiscoverer = null;
    }

    final discoverer = NativeBluetoothDiscoverer();
    _activeDiscoverer = discoverer;

    try {
      final result = await discoverer.discover();
      final devices = result.devices;

      if (desirableDeviceId != null && devices.any((d) => d.id == desirableDeviceId)) {
        Logger.debug('DeviceService: Found desirable device $desirableDeviceId');
      }

      _devices = devices;

      for (var s in List.from(_subscriptions.values)) {
        s.onDevices(devices);
      }

      return devices;
    } finally {
      if (_activeDiscoverer == discoverer) _activeDiscoverer = null;
    }
  }

  @override
  Future<DeviceConnection?> ensureConnection(String deviceId, {bool force = false}) async {
    await _mutex.acquire();
    try {
      Logger.debug("ensureConnection ${_connection?.device.id} ${_connection?.status} $force");

      // If a connection object already exists for this device, never tear it down —
      // native owns reconnection once a transport is live.
      if (_connection != null && _connection!.device.id == deviceId) {
        if (_connection!.status == DeviceConnectionState.connected) {
          return _connection;
        }
        // Same device but disconnected — native is handling reconnect; nothing to do.
        return null;
      }

      // No existing connection for this device. Only attempt a fresh connect on force.
      if (!force) return null;

      try {
        await _connectToDevice(deviceId);
      } on DeviceConnectionException catch (e) {
        Logger.debug(e.cause);
        return null;
      }

      _firstConnectedAt ??= DateTime.now();
      return _connection;
    } finally {
      _mutex.release();
    }
  }

  Future<void> _connectToDevice(String id) async {
    if (_connection != null) {
      if (_connection!.status == DeviceConnectionState.connected) {
        await _connection!.disconnect();
      }
      await _connection!.transport.dispose();
    }
    _connection = null;

    var device = _devices.firstWhereOrNull((f) => f.id == id);
    Logger.debug('[DeviceService] device lookup result: ${device?.name ?? "NULL"}');

    if (device == null) {
      Logger.debug('[DeviceService] Device not in discovered list, checking stored device');
      device = _getStoredDevice(id);
      if (device != null) {
        Logger.debug('[DeviceService] Using stored device: ${device.name}');
        if (!_devices.any((d) => d.id == device!.id)) {
          _devices.add(device);
        }
      } else {
        Logger.debug('[DeviceService] No stored device available for $id, returning');
        return;
      }
    }

    _connection = DeviceConnectionFactory.create(device);
    if (_connection != null) {
      await _connection!.connect(onConnectionStateChanged: (id, state) {
        _connectionStateController.add(state);
        // Schedule notifications outside mutex to prevent deadlock
        Future.microtask(() {
          for (var s in List.from(_subscriptions.values)) {
            s.onDeviceConnectionStateChanged(id, state);
          }
        });
      });
      SharedPreferencesUtil().lastConnectedDeviceAddress = device.id;
    } else {
      Logger.debug('[DeviceService] Failed to create device connection for ${device.id}');
    }
  }

  BtDevice? _getStoredDevice(String id) {
    try {
      final storedDevice = SharedPreferencesUtil().btDevice;
      if (storedDevice.id == id && storedDevice.id.isNotEmpty) {
        return storedDevice;
      }
    } catch (e) {
      Logger.debug('Error getting stored device: $e');
    }
    return null;
  }

  @override
  Stream<DeviceConnectionState> get connectionStateStream => _connectionStateController.stream;

  Future<bool> ping() async {
    final conn = _connection;
    if (conn == null) return false;
    return conn.ping();
  }

  @override
  Future<void> disconnectDevice() async {
    final currentConnection = _connection;
    _connection = null;
    if (currentConnection != null) {
      try {
        await currentConnection.disconnect().timeout(const Duration(seconds: 5));
      } catch (_) {
      }
    }
  }

  void _onStatusChanged(DeviceServiceStatus status) {
    for (var s in List.from(_subscriptions.values)) {
      s.onStatusChanged(status);
    }
  }
}
