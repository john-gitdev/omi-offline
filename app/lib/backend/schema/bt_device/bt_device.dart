import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:omi/services/devices/device_connection.dart';
import 'package:omi/utils/logger.dart';

enum DeviceType {
  omi,
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

  // SD card stores [1-byte length prefix][VBR Opus payload]. Average payload at
  // 32 kbps is ~80 bytes; total per frame ≈ 81 bytes. This is separate from
  // getFramesLengthInBytes() which models BLE transport (MTU-constrained packets).
  static const int _opusStorageAvgBytesPerFrame = 81; // ~80 B VBR payload + 1-byte prefix
  static const int _opusFps = 50;

  /// Estimated SD card bytes per minute of audio (pre-sync heuristic only).
  /// Post-sync, exact frame count from .bin files is used instead.
  int getStorageBytesPerMinute() {
    switch (this) {
      case BleAudioCodec.opus:
      case BleAudioCodec.opusFS320:
        return _opusStorageAvgBytesPerFrame * _opusFps * 60; // 243,000
      default:
        return getFramesLengthInBytes() * getFramesPerSecond() * 60;
    }
  }
}

class OmiFeatures {
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
    return device.platformName.toLowerCase().contains('omi');
  }

  static BtDevice fromScanResult(ScanResult result) {
    return BtDevice(
      id: result.device.remoteId.str,
      name: result.device.platformName,
      type: DeviceType.omi,
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
      type: DeviceType.omi,
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

  Future<BtDevice> getDeviceInfo(DeviceConnection? conn) async {
    if (conn == null) return this;

    try {
      return await conn.performGetDeviceInfo(conn);
    } catch (e) {
      Logger.error('Error getting device info: $e');
      return this;
    }
  }
}
