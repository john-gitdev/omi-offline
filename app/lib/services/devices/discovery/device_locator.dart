enum DeviceLocatorKind {
  bluetooth,
  watch,
}

class DeviceLocator {
  final DeviceLocatorKind kind;
  final String? deviceId;

  const DeviceLocator({
    required this.kind,
    this.deviceId,
  });

  factory DeviceLocator.bluetooth({required String deviceId}) {
    return DeviceLocator(kind: DeviceLocatorKind.bluetooth, deviceId: deviceId);
  }

  factory DeviceLocator.watch() {
    return const DeviceLocator(kind: DeviceLocatorKind.watch);
  }

  factory DeviceLocator.fromJson(Map<String, dynamic> json) {
    return DeviceLocator(
      kind: DeviceLocatorKind.values[json['kind']],
      deviceId: json['deviceId'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'kind': kind.index,
      'deviceId': deviceId,
    };
  }
}
