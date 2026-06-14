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
    return _isOmi(p);
  }

  bool _isOmi(BlePeripheral p) {
    final name = p.name.toLowerCase();
    // Firmware advertises the device name plus the Settings service (0010) as
    // UUID128_ALL, so match on either the name or that advertised service.
    return name.contains('omi') ||
        _hasService(p, '19B10010-E8F2-537E-4F6C-D104768A1214');
  }

  bool _hasService(BlePeripheral p, String serviceUuid) {
    final target = serviceUuid.toLowerCase();
    return p.serviceUuids.any((uuid) => uuid.toLowerCase() == target);
  }

  static BtDevice _peripheralToDevice(BlePeripheral p) {
    return BtDevice(
      name: p.name,
      id: p.uuid,
      type: DeviceType.omi,
      rssi: p.rssi,
      locator: DeviceLocator.bluetooth(deviceId: p.uuid),
    );
  }
}
