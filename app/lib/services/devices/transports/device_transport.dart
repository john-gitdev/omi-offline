import 'dart:async';

/// Abstract transport layer for device communication
/// Provides a unified interface for different communication protocols (BLE, etc.)
abstract class DeviceTransport {
  String get deviceId;

  Future<void> connect({bool requiresBond = false});
  Future<void> disconnect();
  Future<bool> isConnected();
  Future<bool> ping();
  Future<bool> requestBond() async => true;

  Future<Stream<List<int>>> getCharacteristicStream(String serviceUuid, String characteristicUuid);

  Future<List<int>> readCharacteristic(String serviceUuid, String characteristicUuid);
  Future<void> writeCharacteristic(String serviceUuid, String characteristicUuid, List<int> data);

  Stream<DeviceTransportState> get connectionStateStream;

  /// A Future that completes when the GATT physical link is established (before
  /// service discovery). Null when not actively connecting. Non-BLE transports
  /// return null (default).
  Future<void>? get gattConnectFuture => null;

  Future<void> dispose();
}

enum DeviceTransportState {
  disconnected,
  connecting,
  connected,
  disconnecting,
}
