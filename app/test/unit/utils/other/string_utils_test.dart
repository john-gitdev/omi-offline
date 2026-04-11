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

    test('formats negative seconds by treating modulo output conceptually', () {
      // Note: This test captures the existing behavior of the `convertToHHMMSS`
      // function for negative values. Given the formula:
      // hours = seconds ~/ 3600
      // minutes = (seconds % 3600) ~/ 60
      // remainingSeconds = seconds % 60
      //
      // For seconds = -1:
      // hours = 0
      // minutes = (-1 % 3600) ~/ 60 = 3599 ~/ 60 = 59
      // remainingSeconds = -1 % 60 = 59
      // Result: '00:59:59'
      //
      // For seconds = -3661:
      // hours = -3661 ~/ 3600 = -1
      // minutes = (-3661 % 3600) ~/ 60 = 3539 ~/ 60 = 58
      // remainingSeconds = -3661 % 60 = 59
      // Result: '-1:58:59'
      expect(convertToHHMMSS(-1), '00:59:59');
      expect(convertToHHMMSS(-3661), '-1:58:59');
    });
  });
}
