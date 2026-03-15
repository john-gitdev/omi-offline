import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'package:omi/utils/bluetooth/bluetooth_adapter.dart';
import 'package:omi/utils/logger.dart';
import 'device_transport.dart';

class BleTransport extends DeviceTransport {
  final BluetoothDevice _bleDevice;
  final StreamController<DeviceTransportState> _connectionStateController;
  final Map<String, StreamController<List<int>>> _streamControllers = {};
  final Map<String, StreamSubscription> _characteristicSubscriptions = {};

  List<BluetoothService> _services = [];
  DeviceTransportState _state = DeviceTransportState.disconnected;
  StreamSubscription<BluetoothConnectionState>? _bleConnectionSubscription;

  BleTransport(this._bleDevice) : _connectionStateController = StreamController<DeviceTransportState>.broadcast() {
    _bleConnectionSubscription = _bleDevice.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        // Clear services so the next connect() always runs discoverServices().
        _services = [];
        _updateState(DeviceTransportState.disconnected);
      }
      // Do NOT emit connected here. Only connect() emits connected, and only
      // after discoverServices() succeeds. Emitting connected from the OS
      // callback fires _onDeviceConnected before _services is populated,
      // causing every characteristic read to fail immediately.
    });
  }

  @override
  String get deviceId => _bleDevice.remoteId.str;

  @override
  Stream<DeviceTransportState> get connectionStateStream => _connectionStateController.stream;

  void _updateState(DeviceTransportState newState) {
    if (_state != newState) {
      _state = newState;
      _connectionStateController.add(_state);
    }
  }

  @override
  Future<void> connect() async {
    // Only skip the full connect sequence if we are already connected AND have
    // already discovered services. If _services is empty (e.g. the constructor's
    // connectionState listener fired "connected" because the OS-level BLE link was
    // already up from a previous session) we must still run discoverServices() so
    // that _getCharacteristic() callers don't all race to discover concurrently.
    if (_state == DeviceTransportState.connected && _services.isNotEmpty) {
      return;
    }

    _updateState(DeviceTransportState.connecting);

    try {
      // Wait for Bluetooth adapter to be ready
      await BluetoothAdapter.adapterState.where((val) => val == BluetoothAdapterStateHelper.on).first;

      // Connect to device
      await _bleDevice.connect(license: License.free);
      await _bleDevice.connectionState.where((val) => val == BluetoothConnectionState.connected).first;

      // Request larger MTU for better performance on Android
      if (Platform.isAndroid && _bleDevice.mtuNow < 512) {
        await _bleDevice.requestMtu(512);
      }

      // Discover services with a small delay to ensure device is ready
      await Future.delayed(const Duration(milliseconds: 500));
      _services = await _bleDevice.discoverServices();

      _updateState(DeviceTransportState.connected);
    } catch (e) {
      _updateState(DeviceTransportState.disconnected);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    if (_state == DeviceTransportState.disconnected) {
      return;
    }

    _updateState(DeviceTransportState.disconnecting);

    try {
      for (final subscription in _characteristicSubscriptions.values) {
        await subscription.cancel();
      }
      _characteristicSubscriptions.clear();

      for (final controller in _streamControllers.values) {
        await controller.close();
      }
      _streamControllers.clear();

      await _bleDevice.disconnect();

      _updateState(DeviceTransportState.disconnected);
    } catch (e) {
      _updateState(DeviceTransportState.disconnected);
      rethrow;
    }
  }

  @override
  Future<bool> isConnected() async {
    return _bleDevice.isConnected;
  }

  @override
  Future<bool> ping() async {
    try {
      await _bleDevice.readRssi(timeout: 10);
      return true;
    } catch (e) {
      Logger.debug('BLE Transport ping failed: $e');
      return false;
    }
  }

  @override
  Stream<List<int>> getCharacteristicStream(String serviceUuid, String characteristicUuid) {
    final key = '$serviceUuid:$characteristicUuid';

    if (!_streamControllers.containsKey(key)) {
      _streamControllers[key] = StreamController<List<int>>.broadcast();
      _setupCharacteristicListener(serviceUuid, characteristicUuid, key);
    }

    return _streamControllers[key]?.stream ?? const Stream.empty();
  }

  Future<void> _setupCharacteristicListener(String serviceUuid, String characteristicUuid, String key) async {
    try {
      final characteristic = await _getCharacteristic(serviceUuid, characteristicUuid);
      if (characteristic == null) {
        Logger.debug('BLE Transport: Characteristic not found: $serviceUuid:$characteristicUuid');
        return;
      }

      await characteristic.setNotifyValue(true);

      final subscription = characteristic.onValueReceived.listen(
        (value) {
          if (_streamControllers[key] != null && !(_streamControllers[key]?.isClosed ?? true)) {
            _streamControllers[key]?.add(value);
          }
        },
        onError: (error) {
          Logger.debug('BLE Transport characteristic stream error: $error');
        },
      );

      _characteristicSubscriptions[key] = subscription;
      _bleDevice.cancelWhenDisconnected(subscription);
    } catch (e) {
      Logger.debug('BLE Transport: Failed to setup characteristic listener: $e');
    }
  }

  @override
  Future<List<int>> readCharacteristic(String serviceUuid, String characteristicUuid) async {
    final characteristic = await _getCharacteristic(serviceUuid, characteristicUuid);
    if (characteristic == null) {
      return [];
    }

    try {
      return await characteristic.read();
    } catch (e) {
      Logger.debug('BLE Transport: Failed to read characteristic: $e');
      return [];
    }
  }

  @override
  Future<void> writeCharacteristic(String serviceUuid, String characteristicUuid, List<int> data) async {
    final characteristic = await _getCharacteristic(serviceUuid, characteristicUuid);
    if (characteristic == null) {
      throw Exception('Characteristic not found: $serviceUuid:$characteristicUuid');
    }

    try {
      // Use allowLongWrite when data exceeds the current MTU payload size.
      final needsLongWrite = data.length > (_bleDevice.mtuNow - 3);
      await characteristic.write(data, allowLongWrite: needsLongWrite);
    } catch (e) {
      Logger.debug('BLE Transport: Failed to write characteristic: $e');
      rethrow;
    }
  }

  Future<BluetoothCharacteristic?> _getCharacteristic(String serviceUuid, String characteristicUuid) async {
    // Retry up to 3 times, but ONLY when the service itself is missing (transient
    // discovery timing issue). If the service is present but the characteristic is
    // not, no amount of re-discovery will help — bail immediately.
    for (int retry = 0; retry < 3; retry++) {
      if (_services.isEmpty || retry > 0) {
        Logger.debug('BLE Transport: Discovering services (attempt ${retry + 1})...');
        _services = await _bleDevice.discoverServices();
      }

      final service = _services.firstWhereOrNull(
        (s) => s.uuid.str128.toLowerCase() == serviceUuid.toLowerCase(),
      );

      if (service != null) {
        // Service found — characteristic is either present or permanently absent.
        // Do not retry; re-discovery cannot add a characteristic the firmware lacks.
        return service.characteristics.firstWhereOrNull(
          (c) => c.uuid.str128.toLowerCase() == characteristicUuid.toLowerCase(),
        );
      }

      // Service not found — could be a discovery timing issue; retry with back-off.
      if (retry < 2) {
        Logger.debug('BLE Transport: Service $serviceUuid not found (attempt ${retry + 1}), retrying...');
        await Future.delayed(Duration(milliseconds: 500 * (retry + 1)));
      }
    }

    return null;
  }

  @override
  Future<void> dispose() async {
    await _bleConnectionSubscription?.cancel();

    for (final subscription in _characteristicSubscriptions.values) {
      await subscription.cancel();
    }
    _characteristicSubscriptions.clear();

    for (final controller in _streamControllers.values) {
      await controller.close();
    }
    _streamControllers.clear();

    await _connectionStateController.close();
  }
}
