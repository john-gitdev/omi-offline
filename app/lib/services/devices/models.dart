import 'dart:typed_data';
import 'package:omi/backend/schema/bt_device/bt_device.dart';

class OrientedImage {
  final Uint8List imageBytes;
  final ImageOrientation orientation;

  OrientedImage({required this.imageBytes, required this.orientation});
}
