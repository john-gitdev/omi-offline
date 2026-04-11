import 'package:flutter_test/flutter_test.dart';
import 'package:omi/utils/other/string_utils.dart';

void main() {
  group('String Utils - convertToHHMMSS', () {
    test('converts 0 seconds correctly', () {
      expect(convertToHHMMSS(0), '00:00:00');
    });

    test('converts seconds less than a minute correctly', () {
      expect(convertToHHMMSS(59), '00:00:59');
    });

    test('converts exactly 60 seconds correctly', () {
      expect(convertToHHMMSS(60), '00:01:00');
    });

    test('converts seconds less than an hour correctly', () {
      expect(convertToHHMMSS(3599), '00:59:59');
    });

    test('converts exactly an hour correctly', () {
      expect(convertToHHMMSS(3600), '01:00:00');
    });

    test('converts mixed hours, minutes, and seconds correctly', () {
      expect(convertToHHMMSS(3661), '01:01:01');
    });

    test('converts large number of seconds correctly (just under a day)', () {
      expect(convertToHHMMSS(86399), '23:59:59');
    });

    test('converts exactly a day correctly', () {
      expect(convertToHHMMSS(86400), '24:00:00');
    });

    test('converts multi-day duration correctly', () {
      expect(convertToHHMMSS(359999), '99:59:59');
    });

    test('converts more than 100 hours correctly', () {
      expect(convertToHHMMSS(360000), '100:00:00');
    });
  });

  group('String Utils - tryDecodingText', () {
    test('decodes valid utf-8 string correctly', () {
      final text = 'Hello world';
      expect(tryDecodingText(text), text);
    });

    test('returns original string if utf-8 decoding fails', () {
      // Create a malformed UTF-8 string by using an invalid starting byte
      final text = String.fromCharCodes([0xFF]);
      expect(tryDecodingText(text), text);
    });
  });
}
