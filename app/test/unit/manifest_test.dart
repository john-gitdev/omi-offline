import 'package:flutter_test/flutter_test.dart';
import 'package:omi/utils/manifest/manifest.dart';

void main() {
  group('Manifest.fromJson', () {
    test('successfully parses single file manifest without imageIndex', () {
      final json = {
        'format-version': 1,
        'time': 123456789,
        'files': [
          {'file': 'firmware.bin'}
        ]
      };

      final manifest = Manifest.fromJson(json);

      expect(manifest.formatVersion, 1);
      expect(manifest.files.length, 1);
      expect(manifest.files[0].file, 'firmware.bin');
      expect(manifest.files[0].imageIndex, null);
      expect(manifest.files[0].image, 0);
    });

    test('successfully parses multi-file manifest with imageIndex for all files', () {
      final json = {
        'format-version': 1,
        'time': 123456789,
        'files': [
          {'file': 'app.bin', 'image_index': '0'},
          {'file': 'net.bin', 'image_index': '1'}
        ]
      };

      final manifest = Manifest.fromJson(json);

      expect(manifest.files.length, 2);
      expect(manifest.files[0].file, 'app.bin');
      expect(manifest.files[0].imageIndex, '0');
      expect(manifest.files[1].file, 'net.bin');
      expect(manifest.files[1].imageIndex, '1');
    });

    test('throws Exception when imageIndex is missing in multi-file manifest', () {
      final json = {
        'format-version': 1,
        'time': 123456789,
        'files': [
          {'file': 'app.bin', 'image_index': '0'},
          {'file': 'net.bin'} // missing image_index
        ]
      };

      expect(
        () => Manifest.fromJson(json),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('imageIndex is required for multi-image firmware'),
        )),
      );
    });

    test('throws Exception when imageIndex is null in multi-file manifest', () {
      final json = {
        'format-version': 1,
        'time': 123456789,
        'files': [
          {'file': 'app.bin', 'image_index': '0'},
          {'file': 'net.bin', 'image_index': null}
        ]
      };

      expect(
        () => Manifest.fromJson(json),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('imageIndex is required for multi-image firmware'),
        )),
      );
    });
  });
}
