import 'package:omi/gen/assets.gen.dart';

class DeviceUtils {
  /// Returns the appropriate device image asset based on connection state.
  static String getDeviceImagePathWithState({required bool isConnected}) {
    return isConnected ? Assets.images.omiWithoutRope.path : Assets.images.omiWithoutRopeTurnedOff.path;
  }
}
