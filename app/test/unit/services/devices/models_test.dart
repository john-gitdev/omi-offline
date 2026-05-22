import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/models.dart';

void main() {
  group('OrientedImage Tests', () {
    test('should instantiate correctly with valid properties', () {
      final imageBytes = Uint8List.fromList([1, 2, 3, 4]);
      const orientation = ImageOrientation.orientation90;

      final orientedImage = OrientedImage(
        imageBytes: imageBytes,
        orientation: orientation,
      );

      expect(orientedImage.imageBytes, equals(imageBytes));
      expect(orientedImage.orientation, equals(ImageOrientation.orientation90));
    });

    test('should maintain separate instances independently', () {
      final bytes1 = Uint8List.fromList([1]);
      final bytes2 = Uint8List.fromList([2]);

      final img1 = OrientedImage(imageBytes: bytes1, orientation: ImageOrientation.orientation0);
      final img2 = OrientedImage(imageBytes: bytes2, orientation: ImageOrientation.orientation180);

      expect(img1.imageBytes, equals([1]));
      expect(img1.orientation, equals(ImageOrientation.orientation0));

      expect(img2.imageBytes, equals([2]));
      expect(img2.orientation, equals(ImageOrientation.orientation180));

      expect(img1.imageBytes, isNot(equals(img2.imageBytes)));
      expect(img1.orientation, isNot(equals(img2.orientation)));
    });
  });
}
