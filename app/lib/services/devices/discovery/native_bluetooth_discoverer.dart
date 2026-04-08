import 'dart:async';

import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/discovery/device_discoverer.dart';
import 'package:omi/utils/logger.dart';

class NativeBluetoothDiscoverer extends DeviceDiscoverer {
  final BleHostApi _hostApi = BleHostApi();

  @override
  String get name => 'NativeBluetooth';

  @override
  bool get isSupported => true;

  @override
  Future<DeviceDiscoveryResult> discover({int timeout = 5}) async {
    final results = <BlePeripheral>[];

    final previousCallback = BleBridge.instance.peripheralDiscoveredCallback;

    BleBridge.instance.peripheralDiscoveredCallback = (BlePeripheral peripheral) {
      // Logger.debug('NativeBluetoothDiscoverer: Discovered peripheral: ${peripheral.name} (${peripheral.uuid})');
      if (!results.any((r) => r.uuid == peripheral.uuid)) {
        results.add(peripheral);
      }
    };

    try {
      _hostApi.startScan(timeout, []);
      await Future.delayed(Duration(seconds: timeout));
      _hostApi.stopScan();

      final devices = results.where(_isSupportedPeripheral).map(_peripheralToDevice).toList();
      return DeviceDiscoveryResult(devices: devices);
    } catch (e) {
      Logger.debug('NativeBluetoothDiscoverer: scan error: $e');
      try {
        _hostApi.stopScan();
      } catch (_) {}
      return const DeviceDiscoveryResult(devices: []);
    } finally {
      BleBridge.instance.peripheralDiscoveredCallback = previousCallback;
    }
  }

  @override
  void stop() {
    try {
      _hostApi.stopScan();
    } catch (e) {
      Logger.debug('NativeBluetoothDiscoverer: stop scan error: $e');
    }
  }

  bool _isSupportedPeripheral(BlePeripheral p) {
    return _isBee(p) ||
        _isPlaud(p) ||
        _isFieldy(p) ||
        _isFriendPendant(p) ||
        _isLimitless(p) ||
        _isOmi(p) ||
        _isFrame(p);
  }

  bool _isBee(BlePeripheral p) {
    return p.name.toLowerCase().contains('bee');
  }

  bool _isPlaud(BlePeripheral p) {
    return p.name.toUpperCase().startsWith('PLAUD');
  }

  bool _isFieldy(BlePeripheral p) {
    final name = p.name.toLowerCase();
    return name == 'compass' || name == 'fieldy';
  }

  bool _isFriendPendant(BlePeripheral p) {
    return p.name.toLowerCase().startsWith('friend_') || _hasService(p, '19B10000-E8F2-537E-4F6C-D104768A1214');
  }

  bool _isLimitless(BlePeripheral p) {
    final name = p.name.toLowerCase();
    return name.contains('limitless') || name.contains('pendant');
  }

  bool _isOmi(BlePeripheral p) {
    final name = p.name.toLowerCase();
    return name.contains('omi') ||
        name.contains('friend') ||
        _hasService(p, '19B10000-E8F2-537E-4F6C-D104768A1214');
  }

  bool _isFrame(BlePeripheral p) {
    return _hasService(p, 'FE01');
  }

  bool _hasService(BlePeripheral p, String serviceUuid) {
    final target = serviceUuid.toLowerCase();
    return p.serviceUuids.any((uuid) => uuid.toLowerCase() == target);
  }

  static BtDevice _peripheralToDevice(BlePeripheral p) {
    DeviceType type = DeviceType.omi;
    if (p.name.toLowerCase().contains('bee')) {
      type = DeviceType.bee;
    } else if (p.name.toUpperCase().startsWith('PLAUD')) {
      type = DeviceType.plaud;
    } else if (p.name.toLowerCase().contains('fieldy') || p.name.toLowerCase() == 'compass') {
      type = DeviceType.fieldy;
    } else if (p.name.toLowerCase().startsWith('friend_')) {
      type = DeviceType.friendPendant;
    } else if (p.name.toLowerCase().contains('limitless') || p.name.toLowerCase().contains('pendant')) {
      type = DeviceType.limitless;
    }

    return BtDevice(
      name: p.name,
      id: p.uuid,
      type: type,
      rssi: p.rssi,
      locator: DeviceLocator.bluetooth(deviceId: p.uuid),
    );
  }
}
