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
