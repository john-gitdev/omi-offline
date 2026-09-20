/// The rotation command may have executed; retrying it could close another bin.
class StorageRotationUnconfirmedException implements Exception {
  final Object cause;
  StorageRotationUnconfirmedException(this.cause);

  @override
  String toString() => 'Storage rotation outcome unknown: $cause';
}

class DeviceConnectionException implements Exception {
  final String cause;
  DeviceConnectionException(this.cause);

  @override
  String toString() => 'DeviceConnectionException: $cause';
}

class DeviceDiscoveryException implements Exception {
  final String message;
  DeviceDiscoveryException(this.message);

  @override
  String toString() => 'DeviceDiscoveryException: $message';
}
