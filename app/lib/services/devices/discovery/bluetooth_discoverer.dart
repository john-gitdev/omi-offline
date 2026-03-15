import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/utils/bluetooth/bluetooth_adapter.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/platform/platform_service.dart';
import 'device_discoverer.dart';

class BluetoothDeviceDiscoverer extends DeviceDiscoverer {
  @override
  String get name => 'Bluetooth';

  @override
  bool get isSupported => true;

  @override
  Future<DeviceDiscoveryResult> discover({int timeout = 5}) async {
    if (!(await BluetoothAdapter.isSupported)) {
      Logger.debug('Bluetooth not supported, skipping discovery');
      return const DeviceDiscoveryResult(devices: []);
    }

    final List<ScanResult> bleResults = [];
    late final StreamSubscription sub;

    sub = BluetoothAdapter.scanResults.listen((results) {
      final list = results.cast<ScanResult>().where((r) => r.device.platformName.isNotEmpty).toList();
      bleResults
        ..clear()
        ..addAll(list);
    }, onError: (e) {
      Logger.debug('BLE discovery error: $e');
    });

    try {
      // Check current state first
      final currentState = await BluetoothAdapter.adapterState.first;
      if (currentState != BluetoothAdapterStateHelper.on) {
        await BluetoothAdapter.adapterState.where((v) => v == BluetoothAdapterStateHelper.on).first;
      }

      // Delay to allow Bluetooth permissions to settle on Android before scanning.
      if (PlatformService.isAndroid) {
        await Future.delayed(const Duration(seconds: 2));
      }

      await BluetoothAdapter.startScan(
        timeout: Duration(seconds: timeout),
      );

      // Cancel before reading results — flutter_blue_plus emits [] when scan stops,
      // which would clear bleResults if the listener is still active.
      await sub.cancel();

      final List<BtDevice> devices = bleResults
          .where((r) => BtDevice.isSupportedDevice(r.device))
          .sorted((a, b) => b.rssi.compareTo(a.rssi))
          .map<BtDevice>((r) => BtDevice.fromScanResult(r))
          .toList();

      Logger.debug('BLE discovery found ${devices.length} Omi device(s)');
      return DeviceDiscoveryResult(
        devices: devices,
        metadata: {
          'bleResults': bleResults,
        },
      );
    } on Exception catch (e) {
      await sub.cancel();
      Logger.debug('BLE discovery failed: $e');
      return const DeviceDiscoveryResult(devices: []);
    }
  }

  @override
  Future<void> stop() async {
    if (BluetoothAdapter.isScanningNow) {
      await BluetoothAdapter.stopScan();
    }
  }
}
