import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/utils/logger.dart';

enum ImageOrientation {
  orientation0, // 0 degrees
  orientation90, // 90 degrees clockwise
  orientation180, // 180 degrees
  orientation270, // 270 degrees clockwise
}

enum DeviceType {
  omi,
  openglass,
  glass,
  frame,
  appleWatch,
  watch,
  plaud,
  bee,
  fieldy,
  friendPendant,
  limitless,
}

enum BleAudioCodec {
  pcm8,
  pcm16,
  mulaw8,
  mulaw16,
  opus,
  opusFS320,
  unknown;

  bool isOpusSupported() {
    return this == BleAudioCodec.opus || this == BleAudioCodec.opusFS320;
  }

  int getFrameSize() {
    return getFramesLengthInBytes();
  }

  int getFramesPerSecond() {
    switch (this) {
      case BleAudioCodec.pcm8:
      case BleAudioCodec.pcm16:
        return 100;
      case BleAudioCodec.opus:
      case BleAudioCodec.opusFS320:
        return 50;
      default:
        return 100;
    }
  }

  int getFramesLengthInBytes() {
    switch (this) {
      case BleAudioCodec.pcm8:
        return 80;
      case BleAudioCodec.pcm16:
        return 160;
      case BleAudioCodec.opus:
        return 80;
      case BleAudioCodec.opusFS320:
        return 40;
      default:
        return 80;
    }
  }
}

class OmiFeatures {
  static const int speaker = 1 << 0;
  static const int accelerometer = 1 << 1;
  static const int button = 1 << 2;
  static const int battery = 1 << 3;
  static const int usb = 1 << 4;
  static const int haptic = 1 << 5;
  static const int offlineStorage = 1 << 6;
  static const int ledDimming = 1 << 7;
  static const int micGain = 1 << 8;
  static const int wifi = 1 << 9;

  static bool hasFeature(int features, int feature) {
    return (features & feature) != 0;
  }
}

class BtDevice {
  static bool isSupportedDevice(BluetoothDevice device) {
    final name = device.platformName.toLowerCase();
    return name.contains('omi') || name.contains('friend') || name.contains('plaud') || name.contains('glass') || name.contains('watch');
  }

  static BtDevice fromScanResult(ScanResult result) {
    final device = result.device;
    DeviceType type = DeviceType.omi;
    if (isPlaudDeviceFromDevice(device)) type = DeviceType.plaud;
    if (isBeeDeviceFromDevice(device)) type = DeviceType.bee;
    if (isFriendPendantDeviceFromDevice(device)) type = DeviceType.friendPendant;
    if (isLimitlessDeviceFromDevice(device)) type = DeviceType.limitless;
    if (device.platformName.toLowerCase().contains('glass')) type = DeviceType.glass;
    if (device.platformName.toLowerCase().contains('watch')) type = DeviceType.watch;

    return BtDevice(
      id: device.remoteId.str,
      name: device.platformName,
      type: type,
      rssi: result.rssi,
    );
  }

  final String id;
  final String name;
  final int rssi;
  final DeviceType type;
  final String? modelNumber;
  final String? firmwareRevision;
  final String? hardwareRevision;
  final String? manufacturerName;
  final String? serialNumber;

  BtDevice({
    required this.id,
    required this.name,
    required this.type,
    required this.rssi,
    this.modelNumber,
    this.firmwareRevision,
    this.hardwareRevision,
    this.manufacturerName,
    this.serialNumber,
  });

  factory BtDevice.empty() => BtDevice(id: '', name: '', type: DeviceType.omi, rssi: 0);

  factory BtDevice.fromJson(Map<String, dynamic> json) {
    return BtDevice(
      id: json['id'],
      name: json['name'],
      rssi: json['rssi'] ?? 0,
      type: DeviceType.values.firstWhere((e) => e.toString() == json['type'], orElse: () => DeviceType.omi),
      modelNumber: json['modelNumber'],
      firmwareRevision: json['firmwareRevision'],
      hardwareRevision: json['hardwareRevision'],
      manufacturerName: json['manufacturerName'],
      serialNumber: json['serialNumber'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'rssi': rssi,
      'type': type.toString(),
      'modelNumber': modelNumber,
      'firmwareRevision': firmwareRevision,
      'hardwareRevision': hardwareRevision,
      'manufacturerName': manufacturerName,
      'serialNumber': serialNumber,
    };
  }

  BtDevice copyWith({
    String? id,
    String? name,
    int? rssi,
    DeviceType? type,
    String? modelNumber,
    String? firmwareRevision,
    String? hardwareRevision,
    String? manufacturerName,
    String? serialNumber,
  }) {
    return BtDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      rssi: rssi ?? this.rssi,
      type: type ?? this.type,
      modelNumber: modelNumber ?? this.modelNumber,
      firmwareRevision: firmwareRevision ?? this.firmwareRevision,
      hardwareRevision: hardwareRevision ?? this.hardwareRevision,
      manufacturerName: manufacturerName ?? this.manufacturerName,
      serialNumber: serialNumber ?? this.serialNumber,
    );
  }

  static bool isOmiDeviceFromDevice(BluetoothDevice device) => device.platformName.toLowerCase().contains('omi');
  static bool isPlaudDeviceFromDevice(BluetoothDevice device) => device.platformName.toLowerCase().contains('plaud');
  static bool isBeeDeviceFromDevice(BluetoothDevice device) => device.platformName.toLowerCase().contains('bee');
  static bool isFriendPendantDeviceFromDevice(BluetoothDevice device) => device.platformName.toLowerCase().contains('friend');
  static bool isLimitlessDeviceFromDevice(BluetoothDevice device) => device.platformName.toLowerCase().contains('limitless');

  Future<BtDevice> getDeviceInfo(DeviceConnection? conn) async {
    if (conn == null) return this;

    try {
      return await conn.performGetDeviceInfo(conn);
    } catch (e) {
      Logger.error('Error getting device info: $e');
      return this;
    }
  }

  String getFirmwareWarningTitle() {
    switch (type) {
      case DeviceType.plaud:
      case DeviceType.bee:
      case DeviceType.fieldy:
      case DeviceType.friendPendant:
      case DeviceType.limitless:
        return 'Compatibility Note';
      case DeviceType.omi:
      case DeviceType.openglass:
      case DeviceType.glass:
      case DeviceType.frame:
      case DeviceType.appleWatch:
      case DeviceType.watch:
        return '';
    }
  }

  String getFirmwareWarningMessage() {
    switch (type) {
      case DeviceType.plaud:
        return 'Your $name\'s current firmware works great with Omi.';
      case DeviceType.bee:
        return 'Your $name\'s current firmware works great with Omi.';
      case DeviceType.omi:
      case DeviceType.openglass:
      case DeviceType.glass:
      case DeviceType.frame:
      case DeviceType.appleWatch:
      case DeviceType.watch:
      case DeviceType.fieldy:
      case DeviceType.friendPendant:
      case DeviceType.limitless:
        return '';
    }
  }
}
