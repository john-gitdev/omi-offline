import 'dart:async';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/utils/logger.dart';
import 'device_discoverer.dart';

/// BLE discoverer backed by native platform APIs via Pigeon.
/// iOS: CoreBluetooth. Android: BluetoothLeScanner + CompanionDeviceManager.
class NativeBluetoothDiscoverer extends DeviceDiscoverer {
  final BleHostApi _hostApi = BleHostApi();

  @override
  String get name => 'NativeBluetooth';

  @override
  bool get isSupported => true;

  @override
  Future<DeviceDiscoveryResult> discover({int timeout = 5}) async {
    final List<BlePeripheral> results = [];
    final completer = Completer<void>();

    final previousCallback = BleBridge.instance.peripheralDiscoveredCallback;

    BleBridge.instance.peripheralDiscoveredCallback = (BlePeripheral peripheral) {
      if (peripheral.name.isNotEmpty) {
        // Deduplicate by UUID
        results.removeWhere((p) => p.uuid == peripheral.uuid);
        results.add(peripheral);
      }
    };

    try {
      _hostApi.startScan(timeout, []);

      // Wait for scan to complete
      Timer(Duration(seconds: timeout), () {
        if (!completer.isCompleted) completer.complete();
      });
      await completer.future;

      _hostApi.stopScan();

      final devices = results.where(_isSupportedPeripheral).map(_peripheralToDevice).toList()
        ..sort((a, b) => b.rssi.compareTo(a.rssi));

      return DeviceDiscoveryResult(devices: devices);
    } finally {
      BleBridge.instance.peripheralDiscoveredCallback = previousCallback;
    }
  }

  @override
  Future<void> stop() async {
    try {
      _hostApi.stopScan();
    } catch (e) {
      Logger.debug('NativeBluetoothDiscoverer: stop scan error: $e');
    }
  }

  static bool _isSupportedPeripheral(BlePeripheral p) {
    return _isOmi(p);
  }

  static bool _isOmi(BlePeripheral p) {
    final name = p.name.toLowerCase();
    return name.contains('omi');
  }

  static BtDevice _peripheralToDevice(BlePeripheral p) {
    return BtDevice(
      name: p.name,
      id: p.uuid,
      type: DeviceType.omi,
      rssi: p.rssi,
    );
  }
}
