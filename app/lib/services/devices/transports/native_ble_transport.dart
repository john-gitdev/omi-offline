import 'dart:async';
import 'dart:typed_data';

import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/utils/logger.dart';
import 'device_transport.dart';

class NativeBleTransport extends DeviceTransport {
  final String _peripheralUuid;
  final BleHostApi _hostApi = BleHostApi();

  final _connectionStateController = StreamController<DeviceTransportState>.broadcast();
  final Map<String, StreamController<List<int>>> _streamControllers = {};
  final Set<String> _activeSubscriptionKeys = {};

  /// Discovered services from native.
  List<BleService> _services = [];
  Completer<void>? _deviceReadyCompleter;

  DeviceTransportState _state = DeviceTransportState.disconnected;

  NativeBleTransport(this._peripheralUuid) {
    BleBridge.instance.registerPeripheral(
      peripheralUuid: _peripheralUuid,
      onConnectionState: _handleConnectionState,
      onDeviceReady: _handleDeviceReady,
      onCharacteristicValue: _handleCharacteristicValue,
    );
  }

  @override
  String get deviceId => _peripheralUuid;

  @override
  Stream<DeviceTransportState> get connectionStateStream => _connectionStateController.stream;

  // MARK: - Connection

  @override
  Future<void> connect({bool requiresBond = false}) async {
    if (_state == DeviceTransportState.connected) return;

    _updateState(DeviceTransportState.connecting);

    try {
      _deviceReadyCompleter = Completer<void>();
      
      // Intent-based management: native owns the connection pipeline
      // (connect -> discovery -> MTU -> Ready)
      _hostApi.manageDevice(_peripheralUuid, requiresBond);

      await _deviceReadyCompleter!.future.timeout(const Duration(seconds: 60));
      _deviceReadyCompleter = null;

      _updateState(DeviceTransportState.connected);
    } catch (e) {
      Logger.debug('[NativeBleTransport] connect failed or timed out: $e');
      _deviceReadyCompleter = null;
      // We don't call unmanageDevice here because we want native to keep retrying
      // if it's a transient error. The UI will just show disconnected.
      _updateState(DeviceTransportState.disconnected);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    if (_state == DeviceTransportState.disconnected) return;

    _updateState(DeviceTransportState.disconnecting);

    try {
      // Unsubscribe all active streams
      for (final key in _streamControllers.keys.toList()) {
        final parts = key.split(':');
        if (parts.length == 2) {
          try {
            _hostApi.unsubscribeCharacteristic(_peripheralUuid, parts[0], parts[1]);
          } catch (_) {}
        }
      }

      _closeAllStreams();
      _hostApi.unmanageDevice(_peripheralUuid);
      _updateState(DeviceTransportState.disconnected);
    } catch (e) {
      _updateState(DeviceTransportState.disconnected);
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    BleBridge.instance.unregisterPeripheral(_peripheralUuid);
    await _connectionStateController.close();
  }

  // MARK: - Characteristics

  @override
  Future<Uint8List> readCharacteristic(String serviceUuid, String characteristicUuid) async {
    try {
      final value = await _hostApi.readCharacteristic(_peripheralUuid, serviceUuid, characteristicUuid);
      return value;
    } catch (e) {
      Logger.debug('[NativeBleTransport] readCharacteristic failed: $e');
      rethrow;
    }
  }

  @override
  Future<void> writeCharacteristic(String serviceUuid, String characteristicUuid, List<int> data) async {
    try {
      await _hostApi.writeCharacteristic(_peripheralUuid, serviceUuid, characteristicUuid, Uint8List.fromList(data));
    } catch (e) {
      Logger.debug('[NativeBleTransport] writeCharacteristic failed: $e');
      rethrow;
    }
  }

  @override
  Stream<List<int>> getCharacteristicStream(String serviceUuid, String characteristicUuid) {
    final key = '$serviceUuid:$characteristicUuid'.toLowerCase();
    if (!_streamControllers.containsKey(key)) {
      _streamControllers[key] = StreamController<List<int>>.broadcast(
        onListen: () => _subscribeCharacteristic(serviceUuid, characteristicUuid),
        onCancel: () => _unsubscribeCharacteristic(serviceUuid, characteristicUuid),
      );
    }
    return _streamControllers[key]!.stream;
  }

  void _subscribeCharacteristic(String serviceUuid, String characteristicUuid) {
    final key = '$serviceUuid:$characteristicUuid'.toLowerCase();
    _activeSubscriptionKeys.add(key);
    try {
      _hostApi.subscribeCharacteristic(_peripheralUuid, serviceUuid, characteristicUuid);
    } catch (e) {
      Logger.debug('[NativeBleTransport] subscribeCharacteristic failed: $e');
    }
  }

  void _unsubscribeCharacteristic(String serviceUuid, String characteristicUuid) {
    final key = '$serviceUuid:$characteristicUuid'.toLowerCase();
    _activeSubscriptionKeys.remove(key);
    try {
      _hostApi.unsubscribeCharacteristic(_peripheralUuid, serviceUuid, characteristicUuid);
    } catch (e) {
      Logger.debug('[NativeBleTransport] unsubscribeCharacteristic failed: $e');
    }
  }

  // MARK: - Callbacks

  void _handleConnectionState(bool connected, String? error) {
    if (!connected) {
      // Remember active subscriptions — but keep stream controllers open so
      // consumers holding stream references continue to receive data after
      // a native-initiated reconnect.
      _activeSubscriptionKeys.clear();
      _activeSubscriptionKeys.addAll(_streamControllers.keys);

      _services = []; // Clear so reconnect waits for fresh discovery
      _updateState(DeviceTransportState.disconnected);

      // Fail pending ready completer
      if (_deviceReadyCompleter != null && !_deviceReadyCompleter!.isCompleted) {
        _deviceReadyCompleter!.completeError(error ?? 'Disconnected');
      }
    }
  }

  Future<void> _handleDeviceReady(List<BleService> services) async {
    _services = services;

    // Re-subscribe to previously active characteristics using existing controllers.
    // Controllers were kept open during disconnect so consumers still hold valid
    // stream references — no need to recreate them.
    for (final key in _activeSubscriptionKeys) {
      final parts = key.split(':');
      if (parts.length == 2) {
        // Ensure controller exists (create if somehow missing)
        _streamControllers[key] ??= StreamController<List<int>>.broadcast();
        _subscribeCharacteristic(parts[0], parts[1]);
      }
    }

    _updateState(DeviceTransportState.connected);

    // Complete pending ready completer if waiting
    if (_deviceReadyCompleter != null && !_deviceReadyCompleter!.isCompleted) {
      _deviceReadyCompleter!.complete();
    }
  }

  void _handleCharacteristicValue(String serviceUuid, String characteristicUuid, Uint8List value) {
    _addToStream(serviceUuid, characteristicUuid, value);
  }

  // MARK: - Helpers

  void _updateState(DeviceTransportState newState) {
    if (_state == newState) return;
    _state = newState;
    _connectionStateController.add(newState);
  }

  void _addToStream(String serviceUuid, String characteristicUuid, Uint8List value) {
    final key = '$serviceUuid:$characteristicUuid'.toLowerCase();
    if (_streamControllers.containsKey(key)) {
      _streamControllers[key]!.add(value.toList());
    }
  }

  void _closeAllStreams() {
    for (final controller in _streamControllers.values) {
      controller.close();
    }
    _streamControllers.clear();
    _activeSubscriptionKeys.clear();
  }
}
