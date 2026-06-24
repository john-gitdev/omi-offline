import 'dart:typed_data';

import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/utils/logger.dart';

/// Callback signature for characteristic value updates.
typedef CharacteristicValueCallback = void Function(String serviceUuid, String characteristicUuid, Uint8List value);

/// Callback signature for connection state changes (disconnect only; native
/// signals successful connection via [DeviceReadyCallback]).
typedef ConnectionStateCallback = void Function(bool connected, String? error);

/// Callback signature for when a device is connected, discovered, and MTU is negotiated.
typedef DeviceReadyCallback = void Function(List<BleService> services);

/// Singleton bridge that implements BleFlutterApi (Pigeon) and dispatches
/// native BLE events to registered listeners (NativeBleTransport instances).
class BleBridge implements BleFlutterApi {
  static final BleBridge instance = BleBridge._();

  BleBridge._();

  final Map<String, CharacteristicValueCallback> _characteristicCallbacks = {};
  final Map<String, ConnectionStateCallback> _connectionCallbacks = {};
  final Map<String, DeviceReadyCallback> _deviceReadyCallbacks = {};

  void Function(String state)? bluetoothStateChangedCallback;
  void Function(BlePeripheral peripheral)? peripheralDiscoveredCallback;
  void Function(List<String> peripheralUuids)? stateRestoredCallback;
  void Function()? backgroundSyncRequestedCallback;

  void registerPeripheral({
    required String peripheralUuid,
    CharacteristicValueCallback? onCharacteristicValue,
    ConnectionStateCallback? onConnectionState,
    DeviceReadyCallback? onDeviceReady,
  }) {
    final key = peripheralUuid.toUpperCase();
    if (onCharacteristicValue != null) _characteristicCallbacks[key] = onCharacteristicValue;
    if (onConnectionState != null) _connectionCallbacks[key] = onConnectionState;
    if (onDeviceReady != null) _deviceReadyCallbacks[key] = onDeviceReady;
  }

  void unregisterPeripheral(String peripheralUuid) {
    final key = peripheralUuid.toUpperCase();
    _characteristicCallbacks.remove(key);
    _connectionCallbacks.remove(key);
    _deviceReadyCallbacks.remove(key);
  }

  @override
  void onBluetoothStateChanged(String state) {
    bluetoothStateChangedCallback?.call(state);
  }

  @override
  void onPeripheralDiscovered(BlePeripheral peripheral) {
    peripheralDiscoveredCallback?.call(peripheral);
  }

  @override
  void onPeripheralDisconnected(String peripheralUuid, String? error) {
    final key = peripheralUuid.toUpperCase();
    _connectionCallbacks[key]?.call(false, error);
  }

  @override
  void onDeviceReady(String peripheralUuid, List<BleService> services) {
    final key = peripheralUuid.toUpperCase();
    _deviceReadyCallbacks[key]?.call(services);
  }

  @override
  void onCharacteristicValueUpdated(
      String peripheralUuid, String serviceUuid, String characteristicUuid, Uint8List value) {
    final key = peripheralUuid.toUpperCase();
    _characteristicCallbacks[key]?.call(serviceUuid, characteristicUuid, value);
  }

  @override
  void onStateRestored(List<String> peripheralUuids) {
    Logger.debug('BleBridge: State restored for ${peripheralUuids.length} peripherals');
    stateRestoredCallback?.call(peripheralUuids);
  }

  @override
  void onBackgroundSyncRequested() {
    Logger.debug('BleBridge: Background sync requested by OS scheduler');
    backgroundSyncRequestedCallback?.call();
  }
}
