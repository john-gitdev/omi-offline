import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/discovery/device_discoverer.dart';
import 'package:omi/utils/logger.dart';

class AppleWatchDiscoverer extends DeviceDiscoverer {
  @override
  String get name => 'Apple Watch';

  @override
  bool get isSupported => true; // runtime check inside discover

  @override
  Future<DeviceDiscoveryResult> discover({int timeout = 5}) async {
    try {
      final host = WatchRecorderHostAPI();
      final supported = await host.isWatchSessionSupported();
      final paired = await host.isWatchPaired();
      final reachable = await host.isWatchReachable();

      if (supported && paired && reachable) {
        return DeviceDiscoveryResult(devices: [
          BtDevice(
            name: 'Apple Watch',
            id: 'apple-watch',
            type: DeviceType.appleWatch,
            rssi: -50,
            locator: DeviceLocator.watch(),
          )
        ]);
      }
      return const DeviceDiscoveryResult(devices: []);
    } catch (e) {
      Logger.debug('Apple Watch discovery error: $e');
      return const DeviceDiscoveryResult(devices: []);
    }
  }

  @override
  void stop() {
    // Apple Watch discovery is stateless, no cleanup needed
  }
}
