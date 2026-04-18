import 'dart:async';
import 'dart:typed_data';

import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/utils/logger.dart';
import 'device_transport.dart';

/// BLE transport backed by native platform APIs via Pigeon.
/// Uses the intent-based manageDevice/unmanageDevice API.
/// Native owns the connection lifecycle (retry, reconnect, bonding).
/// This transport is long-lived
class NativeBleTransport extends DeviceTransport {
  final String _peripheralUuid;
  final bool requiresBond;
  final BleHostApi _hostApi = BleHostApi();
  final StreamController<DeviceTransportState> _connectionStateController =
      StreamController<DeviceTransportState>.broadcast();

  /// Characteristic notification streams, keyed by "serviceUuid:charUuid" (lowercased).
  final Map<String, StreamController<List<int>>> _streamControllers = {};

  /// Discovered services from native.
  List<BleService> _services = [];

  Completer<List<BleService>>? _deviceReadyCompleter;

  DeviceTransportState _state = DeviceTransportState.disconnected;

  NativeBleTransport(this._peripheralUuid, {this.requiresBond = false}) {
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
    if (_state == DeviceTransportState.connecting && _deviceReadyCompleter != null) {
      await _deviceReadyCompleter!.future;
      return;
    }

    _updateState(DeviceTransportState.connecting);

    _deviceReadyCompleter = Completer<List<BleService>>();

    try {
      await _hostApi.manageDevice(_peripheralUuid, requiresBond);
    } catch (e) {
      Logger.debug('[NativeBleTransport] manageDevice failed: $e');
      final completer = _deviceReadyCompleter;
      _deviceReadyCompleter = null;
      completer?.completeError(e);
      _updateState(DeviceTransportState.disconnected);
      rethrow;
    }

    try {
      _services = await _deviceReadyCompleter!.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException('Device ready timeout after 60s'),
      );
      _deviceReadyCompleter = null;
      _updateState(DeviceTransportState.connected);
    } catch (e) {
      Logger.debug('[NativeBleTransport] connect failed: $e');
      _deviceReadyCompleter = null;
      _updateState(DeviceTransportState.disconnected);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    if (_state == DeviceTransportState.disconnected) return;

    _updateState(DeviceTransportState.disconnecting);

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
    _services = [];

    // Fail any pending connect completer
    if (_deviceReadyCompleter != null && !_deviceReadyCompleter!.isCompleted) {
      _deviceReadyCompleter!.completeError(Exception('Disconnected'));
      _deviceReadyCompleter = null;
    }

    try {
      await _hostApi.unmanageDevice(_peripheralUuid);
    } catch (e) {
      Logger.debug('[NativeBleTransport] unmanageDevice failed: $e');
    }

    _updateState(DeviceTransportState.disconnected);
  }

  @override
  Future<bool> isConnected() async {
    try {
      return _hostApi.isPeripheralConnected(_peripheralUuid);
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> ping() async {
    try {
      return _hostApi.isPeripheralConnected(_peripheralUuid);
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> requestBond() async {
    try {
      return await _hostApi.requestBond(_peripheralUuid);
    } catch (e) {
      Logger.debug('[NativeBleTransport] requestBond failed: $e');
      return false;
    }
  }

  // MARK: - Characteristic Streams

  @override
  Future<Stream<List<int>>> getCharacteristicStream(String serviceUuid, String characteristicUuid) async {
    final key = '${serviceUuid.toLowerCase()}:${characteristicUuid.toLowerCase()}';

    if (!_streamControllers.containsKey(key)) {
      _streamControllers[key] = StreamController<List<int>>.broadcast();
      if (_hasCharacteristic(serviceUuid, characteristicUuid)) {
        _subscribeCharacteristic(serviceUuid, characteristicUuid);
      }
    }

    return _streamControllers[key]!.stream;
  }

  void _subscribeCharacteristic(String serviceUuid, String characteristicUuid) {
    try {
      _hostApi.subscribeCharacteristic(_peripheralUuid, serviceUuid, characteristicUuid);
    } catch (e) {
      Logger.debug('[NativeBleTransport] Failed to subscribe $serviceUuid:$characteristicUuid: $e');
    }
  }

  bool _hasCharacteristic(String serviceUuid, String characteristicUuid) {
    final sUuid = serviceUuid.toLowerCase();
    final cUuid = characteristicUuid.toLowerCase();
    for (final service in _services) {
      if (service.uuid.toLowerCase() == sUuid) {
        return service.characteristicUuids.any((c) => c.toLowerCase() == cUuid);
      }
    }
    return false;
  }

  @override
  Future<List<int>> readCharacteristic(String serviceUuid, String characteristicUuid) async {
    if (!_hasCharacteristic(serviceUuid, characteristicUuid)) return [];
    try {
      final data = await _hostApi.readCharacteristic(_peripheralUuid, serviceUuid, characteristicUuid);
      return data.toList();
    } catch (e) {
      Logger.debug('[NativeBleTransport] Failed to read $serviceUuid:$characteristicUuid: $e');
      return [];
    }
  }

  @override
  Future<void> writeCharacteristic(String serviceUuid, String characteristicUuid, List<int> data) async {
    if (!_hasCharacteristic(serviceUuid, characteristicUuid)) {
      throw Exception('Characteristic not available: $characteristicUuid');
    }
    try {
      await _hostApi.writeCharacteristic(_peripheralUuid, serviceUuid, characteristicUuid, Uint8List.fromList(data));
    } catch (e) {
      Logger.debug('[NativeBleTransport] Failed to write characteristic: $e');
      rethrow;
    }
  }

  // MARK: - Dispose

  @override
  Future<void> dispose() async {
    // Unregister Dart callbacks first so we don't receive stale events.
    BleBridge.instance.unregisterPeripheral(_peripheralUuid);
    // Tell native to release this peripheral so a subsequent manageDevice call
    // starts a fresh connection cycle (without this, native may silently ignore
    // a repeated manageDevice for an already-managed peripheral).
    try {
      await _hostApi.unmanageDevice(_peripheralUuid);
    } catch (_) {}
    _closeAllStreams();
    await _connectionStateController.close();
  }

  // MARK: - Private Helpers

  void _updateState(DeviceTransportState newState) {
    if (_state != newState) {
      _state = newState;
      _connectionStateController.add(_state);
    }
  }

  void _closeAllStreams() {
    for (final controller in _streamControllers.values) {
      controller.close();
    }
    _streamControllers.clear();
  }

  void _addToStream(String serviceUuid, String characteristicUuid, List<int> data) {
    final key = '${serviceUuid.toLowerCase()}:${characteristicUuid.toLowerCase()}';
    final controller = _streamControllers[key];
    if (controller != null && !controller.isClosed) {
      controller.add(data);
    }
  }

  // MARK: - Native Callbacks

  /// Track which characteristics were subscribed so we can re-subscribe on reconnect.
  final Set<String> _activeSubscriptionKeys = {};

  void _handleConnectionState(bool connected, String? error) {
    if (connected) {
      _updateState(DeviceTransportState.connected);
      return;
    }

    if (_state == DeviceTransportState.connecting && error != null) {
      if (error == 'unmanaged' || error == 'gatt_status_133') {
        // 'unmanaged': belt-and-suspenders for the await race fix in dispose/disconnect.
        // 'gatt_status_133': Android GATT_ERROR — transient, native layer retries automatically.
        // Other gatt_status codes (8=auth, 19=remote termination, 22=not supported, …) are
        // real failures and must propagate so the connection attempt is properly aborted.
        Logger.debug('[NativeBleTransport] Ignoring transient error during connect: $error');
        return;
      }
    }

    // Remember active subscriptions before closing streams
    _activeSubscriptionKeys.clear();
    _activeSubscriptionKeys.addAll(_streamControllers.keys);

    _closeAllStreams();
    _services = [];
    _updateState(DeviceTransportState.disconnected);

    // Fail pending completer
    if (_deviceReadyCompleter != null && !_deviceReadyCompleter!.isCompleted) {
      _deviceReadyCompleter!.completeError(error ?? 'Disconnected before ready');
    }
  }

  void _handleDeviceReady(List<BleService> services) {
    _services = services;
    if (_deviceReadyCompleter != null && !_deviceReadyCompleter!.isCompleted) {
      // Initial connection
      _deviceReadyCompleter!.complete(services);
    } else {
      // Auto-reconnect from native — re-subscribe to characteristics
      _resubscribeAfterReconnect(services);
    }
    _updateState(DeviceTransportState.connected);
  }

  bool _isResubscribing = false;

  void _resubscribeAfterReconnect(List<BleService> services) {
    if (_isResubscribing) return;
    _isResubscribing = true;

    try {
      _services = services;

      // Re-create stream controllers and re-subscribe to previously active characteristics
      for (final key in _activeSubscriptionKeys) {
        final parts = key.split(':');
        if (parts.length == 2) {
          _streamControllers[key] = StreamController<List<int>>.broadcast();
          _subscribeCharacteristic(parts[0], parts[1]);
        }
      }

      _updateState(DeviceTransportState.connected);
    } catch (e) {
      Logger.debug('[NativeBleTransport] Failed to re-subscribe after reconnect: $e');
      _updateState(DeviceTransportState.disconnected);
    } finally {
      _isResubscribing = false;
    }
  }

  void _handleCharacteristicValue(String serviceUuid, String characteristicUuid, Uint8List value) {
    _addToStream(serviceUuid, characteristicUuid, value);
  }
}
