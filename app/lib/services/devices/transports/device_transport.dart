import 'dart:async';

/// Abstract transport layer for device communication
/// Provides a unified interface for different communication protocols (BLE, etc.)
abstract class DeviceTransport {
  String get deviceId;

  Future<void> connect({bool requiresBond = false});
  Future<void> disconnect();

  /// Drop the CURRENT link/GATT without unmanaging the device, so the platform
  /// rebuilds a fresh GATT on the next connect. Used to clear a wedged
  /// (connected-but-dead) GATT where [disconnect] would be too heavy (it
  /// unmanages, signalling user-intent-off and cancelling background recovery).
  /// Default falls back to a full [disconnect]; native transports override it.
  Future<void> softDisconnect() => disconnect();

  Future<bool> isConnected();
  Future<bool> ping();
  Future<bool> requestBond() async => true;

  Future<Stream<List<int>>> getCharacteristicStream(String serviceUuid, String characteristicUuid);

  Future<List<int>> readCharacteristic(String serviceUuid, String characteristicUuid);
  Future<void> writeCharacteristic(String serviceUuid, String characteristicUuid, List<int> data);

  Stream<DeviceTransportState> get connectionStateStream;

  Future<void> dispose();
}

enum DeviceTransportState {
  disconnected,
  connecting,
  connected,
  disconnecting,
}
